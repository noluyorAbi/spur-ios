import Foundation
import Observation
import UIKit

/// Road data in the app (SPEC 14): the tile source chain, the live counters and POI layer, and the
/// trip analysis at stop, on "Neu auswerten" and when missing tiles arrive later. Everything heavy
/// runs off the main actor; recording only hands fixes over (an array append).
@Observable
final class RoadService {
    struct PreloadState: Equatable {
        var done: Int
        var total: Int
        var finished: Bool
        var failed: Int
    }

    @ObservationIgnored let provider: RoadTileProvider
    @ObservationIgnored let live: LiveRoads
    @ObservationIgnored private let store: TripStore
    @ObservationIgnored private let settings: Settings

    /// HUD counters of the running trip, as the screen shows them: held still while the scene is
    /// in the background (17.4b); `currentCounts` keeps the truth (speed-limit accounting, Live Activity).
    private(set) var counts = LiveRoadCounts()
    @ObservationIgnored private(set) var currentCounts = LiveRoadCounts() { didSet { show() } }
    @ObservationIgnored private(set) var displayActive = true
    @ObservationIgnored private(set) var displayMutations = 0

    func setDisplayActive(_ active: Bool) {
        displayActive = active
        show()
    }

    #if DEBUG
    /// Tests: a feed result, without the tile machinery.
    func setCurrentCountsForTesting(_ c: LiveRoadCounts) { currentCounts = c }
    #endif

    private func show() {
        guard displayActive, counts != currentCounts else { return }
        counts = currentCounts
        displayMutations += 1
    }
    /// Over the shown speed limit (SPEC 16.2), with hysteresis, fix by fix.
    var overLimit: Bool { counts.overLimit }
    /// How far above the limit, in the sign's unit, while `overLimit`.
    var overLimitBy: Int? { counts.overLimitBy }
    /// Counts trips, so a feed that started before a trip began cannot overwrite its counters.
    @ObservationIgnored private var liveGeneration = 0
    /// Fixes are handed to the live matcher at most this often (each fix at 1 Hz), so a new
    /// speed limit, or none after a turn, shows within about a second (SPEC 16.2).
    static let flushInterval = 0.8
    /// The live map's POI layer.
    private(set) var layer = RoadMapLayer()
    /// Trips whose analysis is running or waiting in the queue.
    private(set) var analyzing: Set<UUID> = []
    private(set) var preload: PreloadState?
    /// The earlier trips' driven edges, merged and chained for the map (SPEC 15).
    private(set) var coverageLines: [RoadCoverage.Line] = []
    /// The same roads by how often they were driven (SPEC 18.7), changed with `coverageRevision`.
    private(set) var heatLines: [RoadCoverage.HeatLine] = []
    /// The merged driven edges, for the scenario finder (SPEC 18.4).
    @ObservationIgnored private(set) var coverageEdges: [RoadCoverage.Edge] = []
    /// Counts changes of `coverageLines`, so views compare a number, not the lines.
    private(set) var coverageRevision = 0
    /// Trips whose coverage is in `coverageLines` (their raw preview may be hidden).
    private(set) var coveredTripIds: Set<UUID> = []

    /// Called on the main actor after a trip's road analysis was saved.
    @ObservationIgnored var onTripUpdated: ((UUID) -> Void)?
    /// The finished trips, to find those waiting for tiles.
    @ObservationIgnored var trips: () -> [TripRecord] = { [] }
    /// The fixes of the trip being recorded (empty when none), to refill the counters of a trip
    /// that was resumed in the background once the app is active again.
    @ObservationIgnored var currentFixes: () -> [Fix] = { [] }

    @ObservationIgnored private var buffer: [Fix] = []
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var lastWantedTile: TileKey?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var layerTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReanalysis: Set<UUID> = []
    /// Analyses run one at a time (each builds a network of up to 12 tiles): a queue and one worker.
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var running: UUID?
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Per trip, the missing tiles that were already local right after its analysis and led to one
    /// more run; the same set never leads to another (a cached tile that cannot be read stays missing).
    @ObservationIgnored private var lateRetry: [UUID: Set<TileKey>] = [:]
    /// While Spur runs in the background (recording with the screen locked, or relaunched by iOS),
    /// no network is built and no trip is analyzed: those need a few hundred MB for a moment.
    @ObservationIgnored private(set) var inBackground = false
    /// A trip was resumed in the background: its counters are refilled once the app is active.
    @ObservationIgnored private var refillOnActive = false
    /// The most analyses that ran at the same time (tests check it stays 1).
    @ObservationIgnored private(set) var peakConcurrentAnalyses = 0
    @ObservationIgnored private var activeRuns = 0
    /// Analyses finished since launch (tests).
    @ObservationIgnored private(set) var completedRuns = 0
    /// Each finished trip's coverage with the analysis time it came from, so a reload reads only
    /// the files that changed.
    @ObservationIgnored private var coverageCache: [UUID: CachedCoverage] = [:]
    /// Trips with an older `coverage.json` already sent back to the analysis this session. A run
    /// that lost its tiles writes nothing (`isDegraded`), so without this set every index change
    /// would queue them again.
    @ObservationIgnored private var upgradeQueued: Set<UUID> = []
    @ObservationIgnored private var coverageWorker: Task<Void, Never>?
    @ObservationIgnored private var coverageTrips: [TripRecord] = []
    @ObservationIgnored private var coverageDirty = false
    struct CachedCoverage: Sendable {
        var analyzedAt: Date?
        var coverage: TripCoverage
    }
    /// Test hook, called off the main actor after an analysis read its tiles.
    @ObservationIgnored var afterTilesRead: (@Sendable () -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Wait before analyzing again after a tile arrived, so neighbouring tiles lead to one run.
    @ObservationIgnored var reanalysisDelay: Duration = .seconds(5)

    var pack: RoadPackHeader? { provider.pack?.header }
    /// Size of the bundled pack file in bytes.
    var packBytes: Int? { provider.pack?.fileSize }

    init(store: TripStore, settings: Settings, pack: RoadPack? = RoadPack.bundled(),
         cache: RoadTileCache = .appDefault(), client: OverpassClient? = OverpassClient(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store
        self.settings = settings
        provider = RoadTileProvider(cache: cache, pack: pack, client: client, liveEnabled: settings.roadDataOnline,
                                    now: now, sleep: sleep)
        live = LiveRoads(local: provider.local)
        inBackground = UIApplication.shared.applicationState == .background
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        Task { [weak self, provider] in
            let stream = await provider.updates()
            for await key in stream { self?.tileArrived(key) }
        }
    }

    /// The app's road service. In Debug, `-SpurRoadFixture` replaces the pack with a fixture.
    static func make(store: TripStore, settings: Settings) -> RoadService {
        #if DEBUG
        if let name = AppEnvironment.roadFixture, let pack = fixturePack(name) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("spur-fixture-cache-\(UUID().uuidString)")
            return RoadService(store: store, settings: settings, pack: pack, cache: RoadTileCache(directory: scratch), client: nil)
        }
        #endif
        return RoadService(store: store, settings: settings)
    }

    #if DEBUG
    /// A pack whose every tile holds the whole fixture: the tiles of all its nodes.
    static func fixturePack(_ name: String) -> RoadPack? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // An absolute path (the simulator reads the Mac's files), else a file in Library/Caches.
        let source = name.hasPrefix("/") ? URL(fileURLWithPath: name) : caches.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: source),
              let elements = try? OverpassParser.parse(data), let json = try? OverpassParser.encode(elements) else { return nil }
        let keys = Set(elements.nodes.map { TileKey.containing(lat: $0.lat, lon: $0.lon) })
        let out = caches.appendingPathComponent("fixture.spurpack")
        guard let writer = try? RoadPackWriter(scratch: caches.appendingPathComponent("fixture.blobs")) else { return nil }
        for key in keys.sorted() { try? writer.add(key, json: json) }
        // The box spans every tile, so no fixture tile counts as partial.
        let boxes = keys.map(\.bbox)
        let box = BBox(south: boxes.map(\.south).min() ?? 0, west: boxes.map(\.west).min() ?? 0,
                       north: boxes.map(\.north).max() ?? 0, east: boxes.map(\.east).max() ?? 0)
        let header = RoadPackHeader(area: "Fixture \(source.lastPathComponent)", source: source.lastPathComponent, sourceDate: "2026-11-09T00:00:00Z",
                                    createdAt: "2026-11-11T00:00:00Z", bbox: box, tileCount: 0)
        try? writer.finish(to: out, header: header)
        return try? RoadPack(url: out)
    }
    #endif

    func setOnline(_ on: Bool) {
        let provider = provider
        if on {
            let trips = trips()
            Task {
                await provider.setLiveEnabled(true)
                // Tiles finished trips still miss are asked for again right away.
                await provider.want(Self.missingTiles(of: trips))
            }
        } else {
            // Stops the request in flight and a running "Gebiet vorladen" too.
            cancelPreload()
            Task { await provider.setLiveEnabled(false) }
        }
    }

    // MARK: Live

    /// A trip starts, or resumes with the fixes it already has (the counters are rebuilt from them).
    func tripStarted(existing: [Fix] = []) {
        currentCounts = LiveRoadCounts()
        liveGeneration += 1
        let generation = liveGeneration
        buffer = []
        lastWantedTile = nil
        // A resume can happen in the background (iOS relaunches Spur on a location event): then
        // no network is built, like every other background feed, and the counters are refilled
        // from the whole trip once the app is active.
        refillOnActive = inBackground && !existing.isEmpty
        flushing = !existing.isEmpty && !inBackground
        let refill = flushing
        Task {
            await live.reset()
            if refill {
                let c = await live.refill(existing)
                if generation == liveGeneration { currentCounts = c }
                flushing = false
            }
        }
    }

    func tripEnded() {
        buffer = []
        refillOnActive = false
        liveGeneration += 1
        currentCounts.speedLimit = nil
        currentCounts.overLimit = false
        currentCounts.overLimitBy = nil
        Task { await live.endTrip() }
    }

    /// Rebuilds the counters from every fix of the running trip, region by region.
    private func refillFromTrip() {
        let fixes = currentFixes()
        guard !fixes.isEmpty else { return }
        // The engine's fixes already hold everything buffered, so the buffer is dropped.
        buffer = []
        flushing = true
        let generation = liveGeneration
        Task {
            await live.reset()
            let c = await live.refill(fixes)
            if generation == liveGeneration { currentCounts = c }
            flushing = false
        }
    }

    /// Recorded fixes from the engine. Cheap: buffered and handed to the live matcher at most
    /// every `flushInterval`, off the main actor.
    func accept(_ fixes: [Fix]) {
        buffer.append(contentsOf: fixes)
        guard !flushing, Date().timeIntervalSince(lastFlush) >= Self.flushInterval, let last = buffer.last else { return }
        let batch = buffer
        buffer = []
        flushing = true
        lastFlush = Date()
        let tile = TileKey.containing(lat: last.latitude, lon: last.longitude)
        if tile != lastWantedTile {
            lastWantedTile = tile
            Task { await provider.want(tile.withNeighbours) }
        }
        let mayRebuild = !inBackground
        let generation = liveGeneration
        Task {
            let c = await live.feed(batch, mayRebuild: mayRebuild)
            // A feed that started before the trip changed belongs to the old trip.
            if generation == liveGeneration { currentCounts = c }
            flushing = false
        }
    }

    /// Rebuilds the POI layer around an anchor, the car or the map center (the caller sets the cadence).
    func updateLayer(lat: Double, lon: Double) {
        // Nothing is drawn in the background, and building the layer could build a network.
        guard !inBackground else { return }
        layerTask?.cancel()
        layerTask = Task {
            let l = await live.layer(lat: lat, lon: lon)
            guard !Task.isCancelled else { return }
            if l != layer { layer = l }
        }
    }

    // MARK: Trip analysis

    /// Analyzes a finished trip off the main actor and saves the `roads` block and `roads.json`.
    /// Analyses run one after the other; a request for a trip already running queues one more run.
    /// `first`: a request the user is waiting for (a trip just stopped, opened, or "Auswerten")
    /// goes ahead of the old-trip backfill and the tile arrivals.
    func analyze(_ id: UUID, first: Bool = false) {
        if running == id {
            pendingReanalysis.insert(id)
            return
        }
        if first {
            queue.removeAll { $0 == id }
            queue.insert(id, at: 0)
        } else if !queue.contains(id) {
            queue.append(id)
        }
        analyzing.insert(id)
        startWorker()
    }

    /// One worker drains the queue; it pauses while Spur is in the background.
    private func startWorker() {
        guard worker == nil, !inBackground, !queue.isEmpty else { return }
        worker = Task {
            while !inBackground, !queue.isEmpty {
                let id = queue.removeFirst()
                running = id
                await run(id)
                running = nil
                if pendingReanalysis.remove(id) != nil, !queue.contains(id) { queue.append(id) }
                if !queue.contains(id) { analyzing.remove(id) }
            }
            worker = nil
            startWorker()
        }
    }

    private func run(_ id: UUID) async {
        activeRuns += 1
        peakConcurrentAnalyses = max(peakConcurrentAnalyses, activeRuns)
        defer {
            activeRuns -= 1
            completedRuns += 1
        }
        let store = store
        let local = provider.local
        let fallback = settings.statsConfig
        let provider = provider
        let hook = afterTilesRead
        let result = await Task.detached(priority: .utility) { () -> (RoadAnalyzer.Output, RoadStatistics?, MotionAnalyzer.Output?)? in
            guard let record = try? store.load(id), !record.isRecording else { return nil }
            let config = StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? fallback.usableAccuracy)
            let fixes = store.loadFixes(id).fixes
            let output = RoadAnalyzer.analyze(fixes: fixes, config: config) { keys in
                let lookup = local.lookup(keys)
                hook?()
                return lookup
            }
            // The motion analysis (SPEC 16.3.2) in the same run, with the street of each event
            // and stretch from the road matching.
            // An unchanged file at the current analysis version is not analyzed again (a road re-run
            // after late tiles would otherwise redo hours of motion for nothing).
            var motion: MotionAnalyzer.Output?
            let bytes = (try? FileManager.default.attributesOfItem(atPath: store.motionURL(id).path)[.size] as? Int) ?? nil
            let current = record.motion.map { $0.version == MotionSummary.currentVersion && $0.fileBytes == bytes } ?? false
            if !current, let bytes, let source = MappedMotionFile(url: store.motionURL(id), window: record.motionWindow) {
                let times = fixes.map(\.time)
                motion = MotionAnalyzer.analyze(source: source, fixes: fixes) { t in
                    guard !times.isEmpty else { return nil }
                    var lo = 0, hi = times.count - 1
                    while hi - lo > 1 {
                        let mid = (lo + hi) / 2
                        if times[mid] <= t { lo = mid } else { hi = mid }
                    }
                    let k = abs(times[hi] - t) < abs(times[lo] - t) ? hi : lo
                    return output.details.way(forFix: k)?.1.street
                }
                motion?.summary.fileBytes = bytes
                motion?.summary.rejectedRecords = source.rejected
            }
            return (output, record.roads, motion)
        }.value
        guard let (output, stored, motion) = result else { return }
        if let motion {
            try? store.saveMotionDetails(motion.details, for: id)
            _ = try? store.update(id) { $0.motion = motion.summary }
        }
        if Self.isDegraded(output.statistics, stored: stored) {
            // Never replace good stored road data with a run that lost its tiles (SPEC 14.0): an
            // old trip queued only for its coverage, whose tiles were evicted. Nothing is written,
            // so the trip comes back when its tiles do.
            if let missing = output.statistics.missingTiles { await provider.want(missing) }
            return
        }
        try? store.saveRoadDetails(output.details, for: id)
        try? store.saveCoverage(output.coverage, for: id)
        _ = try? store.update(id) { $0.roads = output.statistics }
        if let missing = output.statistics.missingTiles {
            // A tile that arrived after its chunk was read (no further arrival will announce it):
            // one more run, once per distinct set.
            let nowLocal = Set(missing.filter { local.isComplete($0) })
            if !nowLocal.isEmpty, lateRetry[id] != nowLocal {
                lateRetry[id] = nowLocal
                pendingReanalysis.insert(id)
            }
            await provider.want(missing)
        } else {
            lateRetry[id] = nil
        }
        onTripUpdated?(id)
    }

    /// Analyzes, one after the other, every finished trip that has no road data yet (trips
    /// recorded before version 1.1). Called once the trip index is loaded.
    func analyzeMissing(_ trips: [TripRecord]) {
        wantMissingTiles(trips)
        // Also trips analyzed before version 1.2, which have no `coverage.json` yet (SPEC 15.1).
        let store = store
        // And trips with motion samples but no motion analysis yet, or one of an older version
        // (SPEC 16.3.2).
        for id in trips.filter({ !$0.isRecording && ($0.roads == nil || !store.hasCoverage($0.id)
            || (store.hasMotion($0.id) && ($0.motion?.version ?? 0) < MotionSummary.currentVersion)) })
            .map(\.id) { analyze(id) }
    }

    /// True when a new analysis misses tiles and matched less than the stored one.
    static func isDegraded(_ new: RoadStatistics, stored: RoadStatistics?) -> Bool {
        guard let stored, let missing = new.missingTiles, !missing.isEmpty else { return false }
        return new.matchedDistance < stored.matchedDistance - 1
    }

    /// Reads the finished trips' coverage (only files whose analysis changed), merges it and
    /// chains it into lines, off the main actor (SPEC 15). Called whenever the trip index changes;
    /// one worker, bursts coalesced, the latest index wins. A file that exists but cannot be read
    /// (or has another version) sends its trip back to the analysis.
    func reloadCoverage(_ trips: [TripRecord]) {
        coverageTrips = trips
        coverageDirty = true
        guard coverageWorker == nil else { return }
        coverageWorker = Task {
            try? await Task.sleep(for: .milliseconds(300))
            while coverageDirty {
                coverageDirty = false
                await loadCoverage(coverageTrips)
            }
            coverageWorker = nil
        }
    }

    private func loadCoverage(_ trips: [TripRecord]) async {
        let wanted = trips.filter { !$0.isRecording && $0.roads != nil }.map { ($0.id, $0.roads?.analyzedAt) }
        let startedAt = Dictionary(trips.map { ($0.id, $0.startedAt) }, uniquingKeysWith: { a, _ in a })
        let cache = coverageCache
        let store = store
        let queued = upgradeQueued
        let (next, lines, heat, edges, unreadable) = await Task.detached(priority: .utility) { () -> ([UUID: CachedCoverage], [RoadCoverage.Line], [RoadCoverage.HeatLine], [RoadCoverage.Edge], [UUID]) in
            var next: [UUID: CachedCoverage] = [:]
            var unreadable: [UUID] = []
            for (id, stamp) in wanted {
                if let hit = cache[id], hit.analyzedAt == stamp {
                    next[id] = hit
                } else if let c = store.loadCoverage(id), c.version == TripCoverage.currentVersion {
                    next[id] = CachedCoverage(analyzedAt: stamp, coverage: c)
                } else if let c = store.loadCoverage(id), c.version < TripCoverage.currentVersion {
                    // An older version still draws (without what the new one adds, such as
                    // divided-road pairing) while its trip is analyzed again, once per session.
                    next[id] = CachedCoverage(analyzedAt: stamp, coverage: c)
                    if !queued.contains(id) { unreadable.append(id) }
                } else if store.hasCoverage(id) {
                    unreadable.append(id)
                }
            }
            let ids = next.keys.sorted { $0.uuidString < $1.uuidString }
            // Accepted gap fills count as driven, flagged inferred (SPEC 18.8); read fresh, they are small.
            let fills = ids.compactMap { id -> (TripCoverage, Date)? in
                let f = store.loadGapFills(id)
                return f.accepted.isEmpty ? nil : (f.coverage(), startedAt[id] ?? .distantPast)
            }
            let edges = RoadCoverage.merge(ids.map { next[$0]!.coverage } + fills.map(\.0),
                                           dates: ids.map { startedAt[$0] ?? .distantPast } + fills.map(\.1))
            return (next, RoadCoverage.lines(RoadCoverage.runs(RoadCoverage.paired(edges))), RoadCoverage.heatLines(edges), edges, unreadable)
        }.value
        coverageCache = next
        coverageEdges = edges
        if lines != coverageLines || heat != heatLines {
            coverageLines = lines
            heatLines = heat
            coverageRevision += 1
        }
        let covered = Set(next.filter { !$0.value.coverage.runs.isEmpty }.keys)
        if covered != coveredTripIds { coveredTripIds = covered }
        for id in unreadable {
            if let c = store.loadCoverage(id), c.version < TripCoverage.currentVersion { upgradeQueued.insert(id) }
            analyze(id)
        }
    }

    /// Road data for the scenario finder (SPEC 18.4): the tiles of the radius from the pack and the
    /// cache, missing ones from Overpass (at most 16 per query); nil segments when there is no
    /// road data at all.
    struct ScenarioData: Sendable {
        var segments: [RoadSegment]
        var features: [FeatureNode]
        var edges: [RoadCoverage.Edge]
        /// Tiles still without data after loading.
        var missingTiles: Int
        var tiles = 0
        /// Road data from the internet is on in the settings.
        var online = true

        /// Why there are no roads, in the owner's words (SPEC 18.5, 2026-11-17).
        var noDataReason: String {
            if !online { return "Keine Straßendaten hier: Straßendaten aus dem Internet sind in den Einstellungen aus" }
            return "Keine Straßendaten: die Straßendaten-Server sind gerade überlastet. Bitte in ein paar Minuten erneut versuchen, oder das Gebiet in den Einstellungen vorladen, dann geht es ohne Internet"
        }
        var partialNote: String? {
            missingTiles > 0 ? "\(missingTiles) von \(tiles) Kacheln ohne Straßendaten, die Route bleibt im geladenen Gebiet" : nil
        }
    }

    static let scenarioMaxLiveTiles = 16

    /// SPEC 18.9: where a stopped car stands (off the road, a minor or a major road), from the
    /// pack and the cache only: no network, so it works in the background and offline.
    func place(at p: LatLon) async -> BreakDetector.Place {
        var parts: [OSMElements] = []
        for key in TileKey.containing(lat: p.lat, lon: p.lon).withNeighbours {
            if let (e, _) = await provider.local(key) { parts.append(e) }
        }
        guard !parts.isEmpty else { return .unknown }
        return await Task.detached(priority: .utility) {
            BreakDetector.place(p, segments: RoadNetwork(.merged(parts)).segments)
        }.value
    }

    /// `progress` hears the live tiles loaded so far and how many are asked for (none when the
    /// pack and the cache hold the radius).
    func scenarioData(around c: LatLon, radiusM: Double,
                      progress: (@Sendable (_ done: Int, _ of: Int) -> Void)? = nil) async -> ScenarioData {
        let keys = TileKey.within(radius: radiusM, ofLat: c.lat, lon: c.lon)
        let provider = provider
        _ = await provider.loadMissing(keys, limit: Self.scenarioMaxLiveTiles, progress: progress)
        let edges = coverageEdges
        let online = settings.roadDataOnline
        return await Task.detached(priority: .userInitiated) {
            let lookup = await provider.lookup(keys)
            let net = RoadNetwork(lookup.elements)
            return ScenarioData(segments: net.segments, features: Array(net.features.values), edges: edges,
                                missingTiles: lookup.missing.count, tiles: keys.count, online: online)
        }.value
    }

    static func missingTiles(of trips: [TripRecord]) -> [TileKey] {
        Set(trips.filter { !$0.isRecording }.flatMap { $0.roads?.missingTiles ?? [] }).sorted()
    }

    /// Asks again for the tiles finished trips are still missing (Overpass may have failed before).
    func wantMissingTiles(_ trips: [TripRecord]) {
        let keys = Self.missingTiles(of: trips)
        guard !keys.isEmpty else { return }
        let provider = provider
        Task { await provider.want(keys) }
    }

    /// Spur went to the background: analyses pause after the one running, no network is built.
    func enteredBackground() {
        inBackground = true
    }

    /// Back in the foreground: the queued analyses run, and a trip resumed in the background gets
    /// its counters refilled.
    func becameActive() {
        inBackground = false
        wantMissingTiles(trips())
        if refillOnActive {
            refillOnActive = false
            refillFromTrip()
        }
        startWorker()
    }

    /// A tile arrived from Overpass: trips that missed it are analyzed again a few seconds later,
    /// so neighbouring tiles arriving together lead to one run. A trip whose analysis is running
    /// gets one more run queued. A tile that arrives while a trip's first analysis runs (no stored
    /// block lists it yet) is caught by the check after the save in `run`.
    func tileArrived(_ key: TileKey) {
        let waiting = trips().filter { !$0.isRecording && ($0.roads?.missingTiles ?? []).contains(key) }.map(\.id)
        guard !waiting.isEmpty else { return }
        let delay = reanalysisDelay
        Task {
            try? await Task.sleep(for: delay)
            for id in waiting { analyze(id) }
        }
    }

    // MARK: Settings

    /// "Gebiet vorladen": tiles within 15 km of a position.
    func startPreload(lat: Double, lon: Double) {
        preloadTask?.cancel()
        preload = PreloadState(done: 0, total: TileKey.within(radius: 15_000, ofLat: lat, lon: lon).count, finished: false, failed: 0)
        let provider = provider
        preloadTask = Task {
            let result = await provider.preload(lat: lat, lon: lon) { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.preload?.finished == false else { return }
                    self.preload = PreloadState(done: done, total: total, finished: false, failed: 0)
                }
            }
            preload = PreloadState(done: result.available + result.failed, total: result.total, finished: true, failed: result.failed)
        }
    }

    func cancelPreload() {
        preloadTask?.cancel()
        preloadTask = nil
        preload = nil
    }

    func clearCache() async {
        await provider.clearCache()
    }

    func cacheBytes() async -> Int {
        let cache = provider.cache
        return await Task.detached { cache.totalBytes }.value
    }
}
