import Foundation
import MapKit
import SwiftUI
import Testing
@testable import Spur

/// Regression tests for the findings of the version 1.1.1 review.
enum ReviewV11 {
    /// A finished trip on disk with the case 6 downtown fixes.
    static func storedTrip(_ store: TripStore, fixes: [Fix]) throws -> UUID {
        var record = TripRecord(startedAt: fixes[0].date, isRecording: false)
        record.endedAt = fixes.last!.date
        try store.create(record)
        let writer = try store.openWriter(record.id)
        for f in fixes { try writer.append(f) }
        writer.close()
        return record.id
    }

    /// A cache holding the case 6 elements in every tile the drive needs.
    static func downtownCache(_ c: OracleCase, _ fixes: [Fix]) throws -> RoadTileCache {
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        return cache
    }

    static func settings(online: Bool = true) -> Settings {
        let s = Settings(defaults: UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!)
        s.roadDataOnline = online
        return s
    }

    /// Polls on the main actor until `done` holds or about `seconds` pass.
    @MainActor
    static func wait(_ seconds: Double = 15, _ done: () async throws -> Bool) async rethrows -> Bool {
        let steps = Int(seconds / 0.05)
        for _ in 0..<steps {
            if try await done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await done()
    }
}

/// Findings "Resuming a trip in the background builds the road network" and "A resumed trip
/// rebuilds the road network in the background and refills counters only near the last fix".
@MainActor
struct ResumeRefillTests {
    @Test func aTripResumedInTheBackgroundBuildsNoNetworkAndIsRefilledWhenActive() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let service = RoadService(store: TripStore(root: Fixtures.tempDir()), settings: ReviewV11.settings(),
                                  pack: nil, cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        service.currentFixes = { fixes }
        service.enteredBackground()
        service.tripStarted(existing: fixes)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await !service.live.hasNetwork, "a network was built in the background")
        #expect(service.counts.signalSites == 0)

        service.becameActive()
        let expected = RoadAnalysisTests.expectedSignalSites(c, c.drives[0])
        let refilled = await ReviewV11.wait { service.counts.signalSites >= expected - 1 }
        print("RESUME REFILL signal sites \(service.counts.signalSites) (oracle \(expected)), network \(await service.live.hasNetwork)")
        #expect(refilled, "the counters were not refilled once the app was active")
        #expect(service.counts.signalSites <= expected)
        #expect(await service.live.hasNetwork)
    }

    @Test func aRefillCountsPassesFarFromTheLastFix() async throws {
        let c = try OracleCase.load(6)
        let downtown = RoadAnalysisTests.fixes(c.drives[0])
        let cache = try ReviewV11.downtownCache(c, downtown)
        // The car then drove on about 20 km north, out of the road data, before the resume.
        var fixes = downtown
        let last = downtown.last!
        for k in 1...60 {
            fixes.append(Fix(timestampMs: last.timestampMs + Int64(k) * 20_000, latitude: last.latitude + Double(k) * 0.003,
                             longitude: last.longitude, horizontalAccuracy: 5, speed: 15, course: 0))
        }
        let expected = RoadAnalysisTests.expectedSignalSites(c, c.drives[0])

        let nearLast = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await nearLast.reset()
        let before = await nearLast.feed(fixes)
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        let after = await live.refill(fixes)
        print("REFILL far from the last fix: whole trip \(after.signalSites) signal sites (oracle \(expected)), near the last fix only \(before.signalSites)")
        #expect(before.signalSites == 0)
        #expect(after.signalSites >= expected - 1 && after.signalSites <= expected)
    }
}

/// Finding "Deferred analyses all start concurrently when the app becomes active".
@MainActor
struct AnalysisQueueTests {
    @Test func analysesQueuedInTheBackgroundRunOneAtATimeWhenActive() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let ids = try (0..<3).map { _ in try ReviewV11.storedTrip(store, fixes: fixes) }
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                  cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        service.enteredBackground()
        service.analyzeMissing(ids.compactMap { try? store.load($0) })
        service.analyze(ids[0])
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.peakConcurrentAnalyses == 0, "an analysis ran in the background")
        #expect(ids.allSatisfy { (try? store.load($0).roads) == nil })

        service.becameActive()
        let done = await ReviewV11.wait(30) { ids.allSatisfy { (try? store.load($0).roads) != nil } }
        #expect(done, "the queued analyses did not run")
        #expect(service.peakConcurrentAnalyses == 1)
        #expect(service.completedRuns == 3)
        #expect(await ReviewV11.wait(2) { service.analyzing.isEmpty })
    }
}

/// Findings "A tile that arrives during an analysis is never picked up" and "A tile arriving
/// while the trip is being analyzed never triggers re-analysis".
@MainActor
struct LateTileTests {
    @Test func aTileCachedAfterItsChunkWasReadLeadsToOneMoreRun() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        // No pack and no Overpass: the tiles land in the cache only after the first read.
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil, cache: cache, client: nil)
        let elements = c.elements
        let tiles = RoadAnalyzer.tiles(for: fixes)
        let once = OSAllocatedFlag()
        service.afterTilesRead = {
            guard once.setOnce() else { return }
            for key in tiles { try? cache.write(key, elements: elements) }
        }
        service.analyze(id)
        let healed = await ReviewV11.wait(30) {
            guard let r = try? store.load(id).roads else { return false }
            return r.missingTiles == nil && r.counts.signalSites > 0
        }
        print("LATE TILE runs \(service.completedRuns), signal sites \((try? store.load(id).roads?.counts.signalSites) ?? -1)")
        #expect(healed, "the trip kept its missing tiles although they were in the cache")
        #expect(service.completedRuns == 2)
    }

    @Test func aTileArrivingDuringTheRunOfATripThatMissesItQueuesOneMoreRun() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        let missing = RoadAnalyzer.tiles(for: fixes)
        _ = try store.update(id) { $0.roads = RoadStatistics(analyzedAt: Date(), missingTiles: missing) }
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                  cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        service.reanalysisDelay = .milliseconds(10)
        service.trips = { [(try? store.load(id))].compactMap { $0 } }
        // The run holds for a moment after reading its tiles, so the arrival lands during it.
        service.afterTilesRead = { Thread.sleep(forTimeInterval: 0.4) }
        service.analyze(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.analyzing.contains(id))
        service.tileArrived(missing[0])
        let twice = await ReviewV11.wait(30) { service.completedRuns >= 2 && service.analyzing.isEmpty }
        #expect(twice, "the arrival during the run was dropped")
        #expect(service.completedRuns == 2)
    }
}

/// Finding "Overpass fetch, parse and cache run in the background while recording, and every
/// fetched tile stays pinned in an in-memory cache nothing reads".
struct ProviderMemoryTests {
    @Test func theProviderKeepsNoParsedTileInMemory() async throws {
        let clock = TestClock()
        let cache = RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now })
        let transport = FakeTransport([.body(OSMSamples.overpass)])
        let client = OverpassClient(transport: transport, now: { clock.now }, sleep: { clock.sleep($0) })
        let provider = RoadTileProvider(cache: cache, pack: nil, client: client, now: { clock.now }, sleep: { clock.sleep($0) })
        let updates = await provider.updates()
        let key = TileKey(x: 1900, y: 3300)
        await provider.want([key])
        var it = updates.makeAsyncIterator()
        #expect(await it.next() == key)
        #expect(await provider.lookup([key]).missing.isEmpty)
        // The fetched tile lives only in the on-device cache: once that is gone, so is the tile.
        cache.clear()
        #expect(await !provider.isAvailable(key))
        #expect(await provider.lookup([key]).missing == [key])
        #expect(await provider.local(key) == nil)
    }
}

/// Finding "Turning off 'Straßendaten aus dem Internet laden' does not stop the request already
/// in flight".
struct LiveOptOutTests {
    /// The first request hangs until cancelled; later ones answer with the sample.
    nonisolated final class HangingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var cancelledCalls = 0

        var count: Int { lock.withLock { calls } }
        var cancelled: Int { lock.withLock { cancelledCalls } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let n = lock.withLock { calls += 1; return calls }
            if n == 1 {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    lock.withLock { cancelledCalls += 1 }
                    throw error
                }
            }
            return (OSMSamples.overpass, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func turningTheSettingOffCancelsTheRequestInFlightWithoutPenalty() async throws {
        let clock = TestClock()
        let transport = HangingTransport()
        let client = OverpassClient(transport: transport, now: { clock.now }, sleep: { clock.sleep($0) })
        let provider = RoadTileProvider(cache: RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now }), pack: nil,
                                        client: client, now: { clock.now }, sleep: { clock.sleep($0) })
        let updates = await provider.updates()
        let key = TileKey(x: 1900, y: 3300)
        await provider.want([key])
        for _ in 0..<100 where transport.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transport.count == 1)

        await provider.setLiveEnabled(false)
        for _ in 0..<100 where transport.cancelled == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transport.cancelled == 1, "the request in flight kept running after the opt-out")
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.count == 1, "another request left the phone after the opt-out")

        // On again: the cancelled tile is asked for at once (no back-off, no client cool-down).
        await provider.setLiveEnabled(true)
        var it = updates.makeAsyncIterator()
        #expect(await it.next() == key)
        #expect(transport.count == 2)
    }

    @MainActor
    @Test func turningTheSettingOffStopsGebietVorladen() async throws {
        let service = RoadService(store: TripStore(root: Fixtures.tempDir()), settings: ReviewV11.settings(), pack: nil,
                                  cache: RoadTileCache(directory: Fixtures.tempDir()), client: nil)
        service.startPreload(lat: 32.7767, lon: -96.797)
        #expect(service.preload != nil)
        service.setOnline(false)
        #expect(service.preload == nil)
    }
}

/// Finding "Missing tiles are requested once and never retried after a failed fetch" (the part
/// left after a098ef0: turning the setting on asks again, and the note says when nothing loads).
@MainActor
struct MissingTileRetryTests {
    @Test func turningTheSettingOnAsksAgainForTheTilesFinishedTripsMiss() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        let clock = TestClock()
        let fixture = try TestResources.data("downtown-grid")
        let transport = FakeTransport(Array(repeating: .body(fixture), count: 20))
        let client = OverpassClient(transport: transport, now: { clock.now }, sleep: { clock.sleep($0) })
        let service = RoadService(store: store, settings: ReviewV11.settings(online: false), pack: nil,
                                  cache: RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now }), client: client,
                                  now: { clock.now }, sleep: { clock.sleep($0) })
        service.reanalysisDelay = .milliseconds(20)
        service.trips = { [(try? store.load(id))].compactMap { $0 } }
        service.analyze(id)
        let first = await ReviewV11.wait { (try? store.load(id).roads) != nil }
        #expect(first)
        #expect(try store.load(id).roads?.missingTiles?.isEmpty == false)
        #expect(transport.count == 0)

        service.setOnline(true)
        let healed = await ReviewV11.wait(30) {
            guard let r = try? store.load(id).roads else { return false }
            return r.missingTiles == nil && r.counts.signalSites > 0
        }
        print("SETTING ON: Overpass requests \(transport.count), missing after \(String(describing: try? store.load(id).roads?.missingTiles))")
        #expect(healed, "the missing tiles were not asked for when the setting was turned on")
    }

    @Test func theMissingNotePromisesTheReloadOnlyWithTheSettingOn() {
        #expect(RoadsSection.missingNote(2, online: true).contains("werden nachgeladen, sobald Internet da ist"))
        #expect(RoadsSection.missingNote(1, online: true).contains("sie wird nachgeladen"))
        let off = RoadsSection.missingNote(2, online: false)
        #expect(off.hasPrefix("Für 2 Kacheln fehlen Straßendaten."))
        #expect(off.contains("nur mit „Straßendaten aus dem Internet laden“"))
        #expect(!off.contains("sobald Internet da ist"))
    }
}

/// Finding "Pack tiles at the Dallas extract boundary are incomplete, yet are never fetched live
/// or reported missing".
struct PackCoverageTests {
    /// The Dallas extract's box, from the pbf header (scripts/build-osm-pack.sh prints it).
    static let dallas = BBox(south: 32.6259999, west: -97.046, north: 32.944, east: -96.525)

    @Test func onlyTilesEntirelyInsideTheExtractAreComplete() {
        let downtown = TileKey.containing(lat: 32.7767, lon: -96.797)
        #expect(RoadPackCoverage.isComplete(downtown, extract: Self.dallas))
        // The four tiles the review measured as partial.
        for (x, y) in [(1893, 3310), (1899, 3304), (1887, 3305), (1886, 3301)] {
            #expect(!RoadPackCoverage.isComplete(TileKey(x: x, y: y), extract: Self.dallas), "\(x)-\(y)")
        }
    }

    @Test func theBundledPackMarksItsEdgeTilesAsPartial() async throws {
        guard let pack = RoadPack.bundled() else { return }
        let partial = pack.tiles.filter { !pack.isComplete($0) }
        print("BUNDLED PACK \(pack.tiles.count) tiles, box \(pack.header.bbox.array), partial edge tiles \(partial.count)")
        #expect(pack.header.bbox == Self.dallas)
        for (x, y) in [(1893, 3310), (1899, 3304), (1887, 3305), (1886, 3301)] {
            #expect(!pack.isComplete(TileKey(x: x, y: y)), "\(x)-\(y)")
        }
        let downtown = TileKey.containing(lat: 32.7767, lon: -96.797)
        #expect(pack.isComplete(downtown))
        let provider = RoadTileProvider(cache: RoadTileCache(directory: Fixtures.tempDir()), pack: pack, client: nil)
        #expect(await provider.needsLive(TileKey(x: 1899, y: 3304)))
        #expect(await !provider.needsLive(downtown))
    }

    /// A partial pack tile is used (its roads inside the box are right) but listed as missing, so
    /// it is fetched live and the trip analyzed again; once cached, the complete copy wins.
    @Test func aPartialPackTileIsServedListedMissingAndReplacedByTheLiveCopy() throws {
        let dir = Fixtures.tempDir()
        let e = try OverpassParser.parse(OSMSamples.overpass)
        let inside = TileKey(x: 1893, y: 3305)
        let edge = TileKey(x: 1894, y: 3305)
        let writer = try RoadPackWriter(scratch: dir.appendingPathComponent("blobs"))
        var part = e
        part.ways.removeLast()
        try writer.add(inside, json: OverpassParser.encode(e))
        try writer.add(edge, json: OverpassParser.encode(part))
        // The extract ends halfway through `edge`.
        let b = edge.bbox
        let box = BBox(south: inside.bbox.south, west: inside.bbox.west, north: inside.bbox.north, east: (b.west + b.east) / 2)
        try writer.finish(to: dir.appendingPathComponent("p.spurpack"),
                          header: RoadPackHeader(area: "T", source: "t", sourceDate: "x", createdAt: "x", bbox: box, tileCount: 0))
        let pack = try RoadPack(url: dir.appendingPathComponent("p.spurpack"))
        let cache = RoadTileCache(directory: dir.appendingPathComponent("cache"))
        let local = LocalTiles(cache: cache, pack: pack)
        #expect(pack.isComplete(inside) && !pack.isComplete(edge))

        let first = local.lookup([inside, edge])
        #expect(first.sources == [inside: .pack, edge: .pack])
        #expect(first.missing == [edge])
        #expect(!local.isComplete(edge))

        try cache.write(edge, elements: e)
        let second = local.lookup([inside, edge])
        #expect(second.sources == [inside: .pack, edge: .cache])
        #expect(second.missing.isEmpty)
        #expect(local.isComplete(edge))
    }
}

/// Finding "stop=minor on a junction node counts as a stop sign for traffic on the major road".
struct StopMinorTests {
    /// A primary road 1-2-3 and a residential road 4-2 meeting at node 2, which carries the stop.
    static func junction(_ stopTags: [String: String], minorHighway: String = "residential") throws -> RoadNetwork {
        let tags = stopTags.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let json = """
        {"version":0.6,"elements":[
          {"type":"node","id":1,"lat":32.7800,"lon":-96.8010},
          {"type":"node","id":2,"lat":32.7800,"lon":-96.8000,"tags":{\(tags)}},
          {"type":"node","id":3,"lat":32.7800,"lon":-96.7990},
          {"type":"node","id":4,"lat":32.7790,"lon":-96.8000},
          {"type":"way","id":10,"nodes":[1,2,3],"tags":{"highway":"primary","name":"Main Street"}},
          {"type":"way","id":11,"nodes":[4,2],"tags":{"highway":"\(minorHighway)","name":"Elm Street"}}
        ]}
        """
        return RoadNetwork(try OverpassParser.parse(Data(json.utf8)))
    }

    /// The segment of `way` that ends or starts at node 2, and the direction arriving there.
    static func arriving(_ net: RoadNetwork, way: Int64) -> (Int, TravelDirection) {
        let end = net.ends[2]!.first { net.segments[$0.segment].wayId == way && (way == 11 || !$0.atStart) }!
        return (end.segment, end.atStart ? .backward : .forward)
    }

    @Test func aMinorStopAppliesOnlyToTheMinorRoad() throws {
        let net = try Self.junction(["highway": "stop", "stop": "minor"])
        let (major, majorDir) = Self.arriving(net, way: 10)
        let (minor, minorDir) = Self.arriving(net, way: 11)
        #expect(!RoadFeatures.applies(net: net, node: 2, type: .stop, segment: major, travel: majorDir))
        #expect(RoadFeatures.applies(net: net, node: 2, type: .stop, segment: minor, travel: minorDir))
    }

    @Test func otherStopsKeepTheirRules() throws {
        // Untagged stop: applies on every road (SPEC 14.3).
        let plain = try Self.junction(["highway": "stop"])
        let (major, majorDir) = Self.arriving(plain, way: 10)
        #expect(RoadFeatures.applies(net: plain, node: 2, type: .stop, segment: major, travel: majorDir))
        // stop=minor where both roads rank the same: cannot tell, so it applies.
        let even = try Self.junction(["highway": "stop", "stop": "minor"], minorHighway: "primary")
        let (m, d) = Self.arriving(even, way: 10)
        #expect(RoadFeatures.applies(net: even, node: 2, type: .stop, segment: m, travel: d))
        // A direction tag decides on its own, also with stop=minor.
        let directed = try Self.junction(["highway": "stop", "stop": "minor", "direction": "forward"])
        let (dm, dd) = Self.arriving(directed, way: 10)
        #expect(RoadFeatures.applies(net: directed, node: 2, type: .stop, segment: dm, travel: dd) == (dd == .forward))
        #expect(RoadFeatures.highwayRank("primary_link") == RoadFeatures.highwayRank("primary"))
    }
}

/// A flag that is set once, from any thread.
nonisolated final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True the first time only.
    func setOnce() -> Bool { lock.withLock { if set { return false }; set = true; return true } }
}

/// Owner report 2026-11-11 ("buttons laggy"): the follow camera animates only steps that show.
struct FollowCameraTests {
    static func camera(_ lat: Double, _ lon: Double, heading: Double = 0, distance: Double = 5000) -> MapCamera {
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), distance: distance, heading: heading, pitch: 0)
    }

    @Test func onlyVisibleFollowStepsAnimate() {
        let mpp = 7.5 // about 3 km over a 400 pt gap
        let r = 200.0 // half the visible gap
        let a = Self.camera(32.7767, -96.797)
        func visible(_ b: MapCamera, from: MapCamera? = nil) -> Bool {
            LiveMapView.isVisibleStep(from: from ?? a, to: b, metersPerPoint: mpp, radiusPoints: r)
        }
        // 15 m north (one second at 54 km/h): 2 pt, set at once.
        #expect(!visible(Self.camera(32.7767 + 15 / 111_195, -96.797)))
        // 45 m: 6 pt, animated.
        #expect(visible(Self.camera(32.7767 + 45 / 111_195, -96.797)))
        // Turns: 2 degrees (7 pt at the gap's edge) animate, also across north; 0.5 degrees do not.
        #expect(visible(Self.camera(32.7767, -96.797, heading: 1), from: Self.camera(32.7767, -96.797, heading: 359)))
        #expect(!visible(Self.camera(32.7767, -96.797, heading: 0.25), from: Self.camera(32.7767, -96.797, heading: 359.75)))
        // Zoom: 3 % (the tail of braking or accelerating, 6 pt at the edge) animates, 1 % does not.
        #expect(visible(Self.camera(32.7767, -96.797, distance: 5150)))
        #expect(!visible(Self.camera(32.7767, -96.797, distance: 5050)))
    }

}

/// The recording dot's Core Animation pulse is added again when the view returns to a window or
/// the app to the foreground (Core Animation drops it in both cases).
@MainActor
struct PulsingDotTests {
    @Test func thePulseComesBackAfterTheWindowAndTheBackground() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let dot = PulsingDot.PulseView()
        dot.pulsing = true
        #expect(!dot.isPulsing, "pulsing without a window")
        window.addSubview(dot)
        #expect(dot.isPulsing)
        dot.removeFromSuperview()
        #expect(!dot.isPulsing)
        window.addSubview(dot)
        #expect(dot.isPulsing)
        // The background removed it: the foreground adds it again.
        dot.layer.removeAllAnimations()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(dot.isPulsing)
        dot.pulsing = false
        #expect(!dot.isPulsing)
    }
}

/// A trip the user waits for goes ahead of the backfill.
@MainActor
struct AnalysisPriorityTests {
    @Test func aRequestedAnalysisRunsBeforeTheBackfill() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let old = try (0..<2).map { _ in try ReviewV11.storedTrip(store, fixes: fixes) }
        let opened = try ReviewV11.storedTrip(store, fixes: fixes)
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                  cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        var order: [UUID] = []
        service.onTripUpdated = { order.append($0) }
        service.enteredBackground()
        service.analyzeMissing(old.compactMap { try? store.load($0) })
        service.analyze(opened, first: true)
        #expect(service.analyzing == Set(old + [opened]))
        service.becameActive()
        let done = await ReviewV11.wait(30) { order.count == 3 }
        #expect(done)
        #expect(order.first == opened, "the requested trip waited behind the backfill")
        #expect(Array(order.dropFirst()) == old)
    }
}
