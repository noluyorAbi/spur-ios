import Foundation
import Testing
@testable import Spur

/// Regression tests for the findings of the speed limit review.
struct SpeedLimitReviewTests {
    static let thirty = SpeedLimit(value: 30, unit: .mph)
    static func p(_ meters: Double, east: Double = 0) -> LatLon {
        LatLon(lat: 32.78 + meters / 111_195, lon: -96.80 + east / 93_600)
    }

    @discardableResult
    static func feed(_ s: inout SpeedLimitSelector, _ n: Int, from: Double = 0, step: Double = 15, speed: Double = 10, way: Int64 = 1,
                     direction: TravelDirection = .forward, distance: Double = 2, qualified: Bool = false) -> SpeedLimit? {
        var shown: SpeedLimit?
        for k in 0..<n {
            shown = s.update(point: p(from + Double(k) * step), accuracy: 5, speed: speed, matchedWay: way, direction: direction,
                             limit: thirty, qualified: qualified, distance: distance, rivals: [])
        }
        return shown
    }

    // 5

    @Test func jitterWhileStandingIsNoDriving() {
        var s = SpeedLimitSelector()
        // 15 s at a red light with 5 m of GPS jitter: no 30 m driven, so never stable.
        var shown: SpeedLimit?
        for k in 0..<15 {
            shown = s.update(point: Self.p(k % 2 == 0 ? 0 : 5), accuracy: 5, speed: 0, matchedWay: 1, limit: Self.thirty,
                             distance: 2, rivals: [])
        }
        #expect(shown == nil)
    }

    @Test func aWayChangeClearsStabilityAlsoForTheWayBefore() {
        var s = SpeedLimitSelector()
        #expect(Self.feed(&s, 4) == Self.thirty)
        #expect(Self.feed(&s, 1, from: 60, way: 2) == nil, "way B: not stable")
        // Back on A and standing: A is no longer the stable way.
        #expect(Self.feed(&s, 1, from: 75, speed: 0, way: 1) == nil)
    }

    // 8

    @Test func aUTurnStartsOverAndAQualifiedLimitIsNeverShown() {
        var s = SpeedLimitSelector()
        #expect(Self.feed(&s, 4) == Self.thirty)
        #expect(Self.feed(&s, 1, from: 45, direction: .backward) == nil, "same way, other direction")
        #expect(Self.feed(&s, 4, from: 45, step: -15, direction: .backward) == Self.thirty)
        var q = SpeedLimitSelector()
        #expect(Self.feed(&q, 6, qualified: true) == nil, "maxspeed:forward and the like")
    }

    @Test func qualifiedKeysSurviveParsingAndFlagTheSegment() throws {
        let json = """
        {"version":0.6,"elements":[
          {"type":"node","id":1,"lat":32.78,"lon":-96.80},
          {"type":"node","id":2,"lat":32.781,"lon":-96.80},
          {"type":"way","id":10,"nodes":[1,2],"tags":{"highway":"primary","maxspeed":"35 mph","maxspeed:conditional":"20 mph @ (07:00-08:00)"}},
          {"type":"node","id":3,"lat":32.78,"lon":-96.799},
          {"type":"way","id":11,"nodes":[1,3],"tags":{"highway":"primary","maxspeed":"35 mph"}}
        ]}
        """
        let e = try OverpassParser.parse(Data(json.utf8))
        #expect(e.ways.first { $0.id == 10 }?.tags?["maxspeed:conditional"] != nil)
        let net = RoadNetwork(e)
        #expect(net.segments.first { $0.wayId == 10 }?.qualifiedMaxspeed == true)
        #expect(net.segments.first { $0.wayId == 11 }?.qualifiedMaxspeed == false)
    }

    // 6

    @Test func aFixFarFromTheMatchedWayHidesTheSign() {
        var s = SpeedLimitSelector()
        #expect(Self.feed(&s, 4) == Self.thirty)
        #expect(Self.feed(&s, 1, from: 60, distance: 40) == nil, "a parking lot 40 m off the road")
        #expect(Self.feed(&s, 1, from: 75, distance: 12) == Self.thirty)
    }

    // 4

    @Test func aBareNumberIsUnknownInTheUS() {
        #expect(SpeedLimit.unitless(atLat: 32.78, lon: -96.80) == nil)
        #expect(SpeedLimit.unitless(atLat: 61.2, lon: -149.9) == nil) // Anchorage
        #expect(SpeedLimit.unitless(atLat: 21.3, lon: -157.8) == nil) // Honolulu
        #expect(SpeedLimit.unitless(atLat: 48.14, lon: 11.58) == .kmh) // Munich
        #expect(SpeedLimit.unitless(atLat: 45.5, lon: -73.6) == nil, "Montreal lies in the US box: unknown there too, never km/h by guess")
        #expect(SpeedLimit.parse("45", unitless: nil) == nil)
        #expect(SpeedLimit.parse("45 mph", unitless: nil) == SpeedLimit(value: 45, unit: .mph))
        #expect(SpeedLimit.parse("50", unitless: .kmh) == SpeedLimit(value: 50, unit: .kmh))
    }

    // 9

    @Test func overLimitRestartsAfterAGapAndTimesOut() {
        let limit = Self.thirty
        var d = OverLimitDetector()
        d.update(time: 0, speed: 16, speedAccuracy: 0.5, limit: limit)
        let r1 = d.update(time: 5, speed: 16, speedAccuracy: 0.5, limit: limit)
        #expect(!r1, "two fixes 5 s apart are no 2 s above the limit")
        d.update(time: 6, speed: 16, speedAccuracy: 0.5, limit: limit)
        let r2 = d.update(time: 7, speed: 16, speedAccuracy: 0.5, limit: limit)
        #expect(r2)
        // No valid sample for more than 5 s: the red state clears.
        let r3 = d.update(time: 13, speed: nil, speedAccuracy: nil, limit: limit)
        #expect(!r3)
        // Red in the hysteresis band, not above the limit: no "0 mph darüber".
        var band = OverLimitDetector()
        for t in 0...2 { band.update(time: Double(t), speed: 16, speedAccuracy: 0.5, limit: limit) }
        band.update(time: 3, speed: 13.4, speedAccuracy: 0.5, limit: limit)
        #expect(band.over && band.excess == nil)
    }

    // 1

    @Test func aSignWithoutFreshFixesIsTakenDown() {
        let now = Date()
        #expect(LiveView.displayedLimit(Self.thirty, recording: true, enabled: true, lastFix: now.addingTimeInterval(-4), now: now) == Self.thirty)
        #expect(LiveView.displayedLimit(Self.thirty, recording: true, enabled: true, lastFix: now.addingTimeInterval(-6), now: now) == nil)
        #expect(LiveView.displayedLimit(Self.thirty, recording: true, enabled: true, lastFix: nil, now: now) == nil)
        #expect(LiveView.displayedLimit(Self.thirty, recording: false, enabled: true, lastFix: now, now: now) == nil)
        #expect(LiveView.displayedLimit(Self.thirty, recording: true, enabled: false, lastFix: now, now: now) == nil)
    }

    // 3: through LiveRoads, two one-way roads 25 m apart, freeway 60 mph and frontage 40 mph.

    static func parallelRoads() -> OSMElements {
        var nodes: [OSMNode] = []
        var freeway: [Int64] = [], frontage: [Int64] = []
        for k in 0...12 {
            let east = Double(k) * 50
            nodes.append(OSMNode(id: Int64(100 + k), lat: Self.p(0, east: east).lat, lon: Self.p(0, east: east).lon, tags: nil))
            nodes.append(OSMNode(id: Int64(200 + k), lat: Self.p(25, east: east).lat, lon: Self.p(25, east: east).lon, tags: nil))
            freeway.append(Int64(100 + k))
            frontage.append(Int64(200 + k))
        }
        return OSMElements(nodes: nodes, ways: [
            OSMWay(id: 1, nodes: freeway, tags: ["highway": "motorway", "oneway": "yes", "maxspeed": "60 mph", "name": "Main lanes"]),
            OSMWay(id: 2, nodes: frontage, tags: ["highway": "secondary", "oneway": "yes", "maxspeed": "40 mph", "name": "Frontage"]),
        ])
    }

    static func drive(offset: Double, _ e: OSMElements) async throws -> [SpeedLimit?] {
        let fixes = (0..<36).map { k in
            let q = Self.p(offset, east: 20 + Double(k) * 15)
            return Fix(timestampMs: Int64(1_794_420_000_000 + k * 1000), latitude: q.lat, longitude: q.lon, horizontalAccuracy: 5,
                       speed: 15, speedAccuracy: 0.5, course: 90)
        }
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: e) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        var out: [SpeedLimit?] = []
        for f in fixes { out.append(await live.feed([f]).speedLimit) }
        return out
    }

    @Test func aParallelRoadBeyondTheMatchersRadiusStillHidesTheSign() async throws {
        let e = Self.parallelRoads()
        // 11 m from the freeway, 14 m from the frontage: the matcher picks the freeway, whose
        // candidates radius (12 m at 5 m accuracy) never saw the frontage.
        let between = try await Self.drive(offset: 11, e)
        print("PARALLEL 11 m: \(Set(between.compactMap { $0.map { "\($0.value)" } }))")
        #expect(between.allSatisfy { $0 == nil }, "a sign between two roads with different limits")
        // On the freeway itself the frontage is 25 m away, beyond 0 + 15 m: 60 shows.
        let onFreeway = try await Self.drive(offset: 0, e)
        #expect(onFreeway.contains(SpeedLimit(value: 60, unit: .mph)))
        #expect(!onFreeway.contains(SpeedLimit(value: 40, unit: .mph)))
    }

    // 7

    @Test func aRefillLeavesNoSign() async throws {
        let c = try OracleCase.load(6)
        let fixes = SpeedLimitTests.drive(way: 9_978_059, in: c.elements, speed: 12)
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        // The first 30 fixes stay on North Ervay (the last ones run off its end).
        let onErvay = Array(fixes.prefix(30))
        let fed = await live.feed(onErvay)
        #expect(fed.speedLimit == Self.thirty)
        await live.reset()
        let refilled = await live.refill(onErvay)
        #expect(refilled.speedLimit == nil && !refilled.overLimit, "a replayed history must not show a sign")
    }
}

/// The red state through `LiveRoads` on a real street: North Ervay (30 mph), 10 s at 12 m/s, then
/// 20 m/s (more than 5 mph over), one fix per feed as in the app.
struct SpeedLimitOverLiveTests {
    @Test func fastOnNorthErvayTurnsRed() async throws {
        let c = try OracleCase.load(6)
        let slow = SpeedLimitTests.drive(way: 9_978_059, in: c.elements, speed: 12)
        let fast = SpeedLimitTests.drive(way: 9_978_059, in: c.elements, speed: 20)
        // The first 10 slow fixes, then the fast ones from the same spot on, 10 s later.
        let start = slow[9]
        let tail = fast.filter { OSMGeo.haversine(LatLon(lat: $0.latitude, lon: $0.longitude), LatLon(lat: fast[0].latitude, lon: fast[0].longitude))
            > OSMGeo.haversine(LatLon(lat: start.latitude, lon: start.longitude), LatLon(lat: fast[0].latitude, lon: fast[0].longitude)) }
        var fixes = Array(slow.prefix(10))
        for (k, f) in tail.enumerated() {
            var g = f
            g.timestampMs = start.timestampMs + Int64(k + 1) * 1000
            fixes.append(g)
        }
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        var states: [String] = []
        for f in fixes {
            let c = await live.feed([f])
            states.append(c.speedLimit == nil ? "-" : (c.overLimit ? "R\(c.overLimitBy ?? -1)" : "S"))
        }
        print("OVER North Ervay: \(states.joined(separator: " "))")
        #expect(states.contains { $0.hasPrefix("R") }, "never red at 20 m/s on a 30 mph street")
    }
}
