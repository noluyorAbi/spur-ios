import Foundation
import Testing
@testable import Spur

/// SPEC 14.5: the trip analysis.
struct RoadAnalysisTests {
    static func fixes(_ d: OracleCase.Drive) -> [Fix] {
        d.fixes.map { f in
            Fix(timestampMs: Int64((f.time * 1000).rounded()), latitude: f.lat, longitude: f.lon, horizontalAccuracy: f.accuracy,
                speed: f.speed, course: f.course)
        }
    }

    /// The oracle's truth, counted the way the analysis counts: signal sites from the true passes.
    static func expectedSignalSites(_ c: OracleCase, _ d: OracleCase.Drive) -> Int {
        let sites = RoadFeatures.signalSites(c.network)
        var count = 0
        var last: Int64?
        var lastTime = -Double.infinity
        for (id, t) in zip(d.passes, d.passTimes) {
            guard c.network.features[id]?.type == .trafficSignals else { continue }
            let site = sites[id]
            let time = t ?? 0
            if site != last || time - lastTime > RoadConstants.sameSiteSeconds { count += 1 }
            last = site
            lastTime = time
        }
        return count
    }

    @Test func case6AnalysisMatchesTheOracle() throws {
        let c = try OracleCase.load(6)
        let d = c.drives[0]
        let out = RoadAnalyzer.analyze(fixes: Self.fixes(d), config: .default) { _ in
            RoadTileProvider.Lookup(elements: c.elements, sources: [TileKey(x: 0, y: 0): .pack], missing: [])
        }
        let s = out.statistics
        let expected = Self.expectedSignalSites(c, d)
        print("CASE6 ANALYSIS signal sites \(s.counts.signalSites) (oracle \(expected)), stop signs \(s.counts.stopSigns), skewed \(s.counts.skewedJunctions), stops signal \(s.stops.signal) stop sign \(s.stops.stopSign) other \(s.stops.other), coverage \(s.coverage ?? -1)")
        #expect(expected > 0)
        #expect(s.counts.signalSites == expected)
        #expect(s.stops == RoadStatistics.StopsByClass(signal: 1, stopSign: 0, other: 0))
        #expect((s.coverage ?? 0) > 0.95)
        #expect(s.tilesFromPack == 1)
        #expect(s.missingTiles == nil)
        // Every passed feature is a feature of the truth (precision 100 % on this drive).
        #expect(Set(out.details.passed.map(\.nodeId)).isSubset(of: Set(d.passes)))
        #expect(out.details.fixWays.count == d.fixes.count)
        #expect(out.details.fixWays.compactMap { $0 }.count > d.fixes.count / 2)
        #expect(!s.categories.isEmpty)
    }

    @Test func chunkingGivesTheSameResultAsOneChunk() throws {
        for n in [6, 8] {
            let c = try OracleCase.load(n)
            let fixes = Self.fixes(c.drives[0])
            let load: ([TileKey]) -> RoadTileProvider.Lookup = { keys in
                RoadTileProvider.Lookup(elements: c.elements, sources: Dictionary(uniqueKeysWithValues: keys.map { ($0, .pack) }), missing: [])
            }
            let whole = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1000, load: load)
            let chunks = RoadAnalyzer.chunks(fixes, maxTiles: 1)
            let split = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1, load: load)
            print("CHUNKS case \(n): \(chunks.count) chunks with one tile each; signal sites \(split.statistics.counts.signalSites) vs \(whole.statistics.counts.signalSites), passes \(split.details.passed.count) vs \(whole.details.passed.count)")
            #expect(n == 6 || chunks.count >= 2) // case 6 stays inside one tile
            #expect(split.statistics.counts == whole.statistics.counts)
            #expect(split.statistics.stops == whole.statistics.stops)
            #expect(split.details.passed.map(\.nodeId) == whole.details.passed.map(\.nodeId))
            #expect(abs(split.statistics.matchedDistance - whole.statistics.matchedDistance) < 1)
        }
    }

    /// A straight 1.2 km street with four signals and a 600 m street with one stop sign, driven
    /// end to end: the first has many signals, the second not many stop signs; a 200 m street
    /// with two stop signs is too short to judge.
    @Test func streetsWithMany() {
        var nodes: [(Int64, Double, Double, [String: String]?)] = []
        var main: [Int64] = []
        for k in 0...12 {
            let id = Int64(100 + k)
            nodes.append((id, Double(k) * 100, 0, [2, 5, 8, 11].contains(k) ? ["highway": "traffic_signals"] : nil))
            main.append(id)
        }
        var quiet: [Int64] = [112]
        for k in 1...6 {
            let id = Int64(200 + k)
            nodes.append((id, 1200 + Double(k) * 100, 0, k == 3 ? ["highway": "stop"] : nil))
            quiet.append(id)
        }
        var short: [Int64] = [206]
        for k in 1...2 {
            let id = Int64(300 + k)
            nodes.append((id, 1800 + Double(k) * 100, 0, ["highway": "stop"]))
            short.append(id)
        }
        let e = RoadFeatureTests.elements(nodes, [
            (1, main, ["highway": "secondary", "name": "Signal Avenue", "maxspeed": "30 mph"]),
            (2, quiet, ["highway": "residential", "name": "Quiet Lane"]),
            (3, short, ["highway": "residential", "name": "Short Way"]),
        ])
        // One fix per second at 10 m/s along the x axis, 4 m accuracy, course 90.
        let mLon = 111_195.0 * cos(32.78 * .pi / 180)
        var fixes: [Fix] = []
        for k in 0...200 {
            fixes.append(Fix(timestampMs: 1_794_420_000_000 + Int64(k) * 1000, latitude: 32.78, longitude: -96.80 + Double(k) * 10 / mLon,
                             horizontalAccuracy: 4, speed: 10, course: 90))
        }
        let out = RoadAnalyzer.analyze(fixes: fixes, config: .default) { _ in RoadTileProvider.Lookup(elements: e, sources: [:], missing: []) }
        let s = out.statistics
        #expect(s.counts.signalSites == 4)
        #expect(s.counts.stopSigns == 3)
        #expect(s.manySignals.map(\.name) == ["Signal Avenue"])
        let avenue = s.manySignals[0]
        #expect(avenue.count == 4)
        #expect(abs(avenue.drivenMeters - 1200) < 15)
        #expect(abs(avenue.perKm - 4 / 1.2) < 0.05)
        #expect(s.manyStopSigns.isEmpty)   // Quiet Lane 1 per 0.6 km; Short Way under 300 m
        // Speed limit: 10 m/s on a 30 mph road (13.4 m/s) is not speeding.
        #expect((s.speedLimitKnownShare ?? 0) > 0.55 && (s.speedLimitKnownShare ?? 1) < 0.65)
        #expect(s.speedingShare == 0)
        #expect(s.categories.map(\.category).contains(.arterial))
        #expect(s.categories.map(\.category).contains(.local))
    }

    @Test func aStopSignForTheOtherDirectionIsNotCounted() {
        let e = RoadFeatureTests.elements([
            (1, 0, 0, nil), (2, 300, 0, ["highway": "stop", "direction": "backward"]), (3, 600, 0, ["highway": "stop", "direction": "forward", "stop": "all"]),
            (4, 900, 0, nil),
        ], [(10, [1, 2, 3, 4], ["highway": "residential", "name": "Two Way"])])
        let mLon = 111_195.0 * cos(32.78 * .pi / 180)
        let fixes = (0...90).map { k in
            Fix(timestampMs: 1_794_420_000_000 + Int64(k) * 1000, latitude: 32.78, longitude: -96.80 + Double(k) * 10 / mLon,
                horizontalAccuracy: 4, speed: 10, course: 90)
        }
        let out = RoadAnalyzer.analyze(fixes: fixes, config: .default) { _ in RoadTileProvider.Lookup(elements: e, sources: [:], missing: []) }
        #expect(out.statistics.counts.stopSigns == 1)
        #expect(out.statistics.counts.allWayStops == 1)
        #expect(out.details.passed.filter { $0.type == .stop }.map(\.applies) == [false, true])
    }

    @Test func withoutRoadDataTheTripKeepsItsMissingTiles() {
        let fixes = Fixtures.northbound(speeds: Array(repeating: 15, count: 30))
        let out = RoadAnalyzer.analyze(fixes: fixes, config: .default) { keys in
            RoadTileProvider.Lookup(elements: OSMElements(), sources: [:], missing: keys)
        }
        #expect(out.statistics.missingTiles?.isEmpty == false)
        #expect(out.statistics.hasMissingTiles)
        #expect(out.statistics.coverage == 0)
        #expect(out.statistics.counts == RoadStatistics.Counts())
    }

    @Test func theRoadsBlockAndRoadsFilePersist() throws {
        let c = try OracleCase.load(6)
        let d = c.drives[0]
        let out = RoadAnalyzer.analyze(fixes: Self.fixes(d), config: .default, now: Date(timeIntervalSince1970: 1_794_420_000)) { _ in
            RoadTileProvider.Lookup(elements: c.elements, sources: [:], missing: [])
        }
        let store = TripStore(root: Fixtures.tempDir())
        var record = TripRecord(startedAt: Date(timeIntervalSince1970: 1_767_711_600), isRecording: false)
        record.roads = out.statistics
        try store.create(record)
        try store.saveRoadDetails(out.details, for: record.id)
        let loaded = try store.load(record.id)
        #expect(loaded.roads == out.statistics)
        #expect(store.loadRoadDetails(record.id) == out.details)
        // The index still reads only trip.json; roads.json stays out of it.
        #expect(store.index().first?.roads?.counts == out.statistics.counts)
    }
}

struct RoadTotalsTests {
    @Test func historyTotalsSumTheAnalyzedTrips() {
        var a = TripRecord(startedAt: Date(), isRecording: false)
        a.roads = RoadStatistics(analyzedAt: Date(), counts: .init(signalSites: 7, stopSigns: 2))
        var b = TripRecord(startedAt: Date(), isRecording: false)
        b.roads = RoadStatistics(analyzedAt: Date(), counts: .init(signalSites: 3, stopSigns: 0))
        let c = TripRecord(startedAt: Date(), isRecording: false) // a 1.0 trip, not analyzed yet
        #expect(RoadTotals.of([a, b, c]) == RoadTotals(signalSites: 10, stopSigns: 2, analyzedTrips: 2))
    }
}

/// The live counters (light matcher on the tiles around the car) on the downtown oracle drive.
struct LiveRoadsTests {
    @Test func liveCountersOnTheDowntownDrive() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        var counts = LiveRoadCounts()
        for start in stride(from: 0, to: fixes.count, by: 2) {
            counts = await live.feed(Array(fixes[start..<min(fixes.count, start + 2)]))
        }
        let expected = RoadAnalysisTests.expectedSignalSites(c, c.drives[0])
        print("LIVE case 6: signal sites \(counts.signalSites) (oracle \(expected)), stop signs \(counts.stopSigns), skewed \(counts.skewedJunctions), category \(counts.category?.rawValue ?? "-")")
        #expect(counts.hasRoadData)
        #expect(counts.signalSites >= expected - 1 && counts.signalSites <= expected)
        // SPEC 17.9: every moving second is credited to one sign state.
        var moving = 0.0
        for (a, b) in zip(fixes, fixes.dropFirst()) where b.time - a.time <= 5 && (b.speed ?? 0) >= SpeedLimitSelector.minSpeed {
            moving += b.time - a.time
        }
        let credited = counts.limitSeconds.values.reduce(0, +)
        print("LIVE case 6 limit states: \(counts.limitSeconds.mapValues { Int($0) }), moving \(Int(moving)) s")
        #expect(abs(credited - moving) < 1)
        let car = fixes[fixes.count / 2]
        let layer = await live.layer(lat: car.latitude, lon: car.longitude)
        #expect(!layer.pois.isEmpty && layer.pois.count <= LiveRoads.maxPOIs)
        #expect(layer.pois.contains { $0.kind == .signal })
        let here = LatLon(lat: car.latitude, lon: car.longitude)
        #expect(layer.pois.allSatisfy { OSMGeo.haversine(here, LatLon(lat: $0.lat, lon: $0.lon)) <= LiveRoads.poiRadius })
        // Only junctions the skew rule flags carry the skew symbol.
        let net = c.network
        #expect(layer.pois.filter { $0.kind == .skewed }.allSatisfy { net.features[$0.id]?.skewed == true })
        print("LIVE layer at mid-route: \(layer.pois.count) symbols, \(layer.pois.filter(\.ahead).count) ahead on the car's road, \(layer.manySignalStreets.count) lines")
    }
}
