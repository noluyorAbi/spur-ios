import Foundation
import Testing
@testable import Spur

/// SPEC 16.2: the speed limit sign.
struct SpeedLimitTests {
    @Test func onlySinglePlainValuesAreRead() {
        #expect(SpeedLimit.parse("35 mph") == SpeedLimit(value: 35, unit: .mph))
        #expect(SpeedLimit.parse("50") == SpeedLimit(value: 50, unit: .kmh))
        #expect(SpeedLimit.parse("50 km/h") == SpeedLimit(value: 50, unit: .kmh))
        for tag in ["35 mph;45 mph", "none", "signals", "30 knots", "", "mph", "0", "35mph"] {
            #expect(SpeedLimit.parse(tag) == nil, "\(tag)")
        }
        #expect(SpeedLimit.parse(nil) == nil)
        #expect(abs(SpeedLimit(value: 30, unit: .mph).metersPerSecond - 13.4112) < 1e-6)
        #expect(SpeedLimitSign.label(SpeedLimit(value: 45, unit: .mph), overBy: nil) == "Tempolimit 45 mph laut OpenStreetMap")
        #expect(SpeedLimitSign.label(SpeedLimit(value: 45, unit: .mph), overBy: 8) == "Tempolimit 45 mph laut OpenStreetMap, 8 mph darüber")
        #expect(SpeedLimitSign.label(SpeedLimit(value: 50, unit: .kmh), overBy: nil) == "Tempolimit 50 km/h laut OpenStreetMap")
    }

    static let thirty = SpeedLimit(value: 30, unit: .mph)
    static let sixty = SpeedLimit(value: 60, unit: .mph)

    /// A point `meters` north of a base.
    static func p(_ meters: Double) -> LatLon { LatLon(lat: 32.78 + meters / 111_195, lon: -96.80) }

    @Test func aLimitNeedsThreeFixesAndThirtyMetersOnOneWay() {
        var s = SpeedLimitSelector()
        let r1 = s.update(point: Self.p(0), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r1 == nil)
        let r2 = s.update(point: Self.p(10), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r2 == nil)
        let r3 = s.update(point: Self.p(20), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r3 == nil, "20 m")
        let r4 = s.update(point: Self.p(32), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r4 == Self.thirty)
        // A way change starts over.
        let r5 = s.update(point: Self.p(44), accuracy: 5, speed: 10, matchedWay: 2, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r5 == nil)
        // An unmatched fix hides it.
        var t = SpeedLimitSelector()
        for k in 0..<4 { t.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: []) }
        #expect(t.shown == Self.thirty)
        let r6 = t.update(point: Self.p(60), accuracy: 5, speed: 10, matchedWay: nil, limit: nil, distance: 0, rivals: [])
        #expect(r6 == nil)
    }

    @Test func accuracySpeedAndStandingRules() {
        var s = SpeedLimitSelector()
        for k in 0..<4 { s.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: []) }
        #expect(s.shown == Self.thirty)
        let r7 = s.update(point: Self.p(60), accuracy: 20, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r7 == nil, "accuracy above 15 m")
        let r8 = s.update(point: Self.p(75), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r8 == Self.thirty)
        // Standing on the way it was stably matched to keeps the sign.
        let r9 = s.update(point: Self.p(75), accuracy: 5, speed: 0, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(r9 == Self.thirty)
        // Slow on a way it never was stable on: hidden.
        var slow = SpeedLimitSelector()
        for _ in 0..<5 { slow.update(point: Self.p(0), accuracy: 5, speed: 1, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: []) }
        #expect(slow.shown == nil)
    }

    @Test func aCloseParallelWayWithAnotherLimitHidesTheSign() {
        var s = SpeedLimitSelector()
        let freeway = [SpeedLimitSelector.Rival(way: 9, limit: Self.sixty, distance: 12)]
        for k in 0..<5 {
            s.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 15, matchedWay: 1, limit: SpeedLimit(value: 40, unit: .mph),
                     distance: 3, rivals: freeway)
        }
        #expect(s.shown == nil)
        // The same limit next door, or a rival far beyond the margin, does not hide it.
        var same = SpeedLimitSelector()
        var far = SpeedLimitSelector()
        for k in 0..<5 {
            same.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 15, matchedWay: 1, limit: Self.sixty, distance: 3,
                        rivals: [SpeedLimitSelector.Rival(way: 9, limit: Self.sixty, distance: 12)])
            far.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 15, matchedWay: 1, limit: Self.thirty, distance: 3,
                       rivals: [SpeedLimitSelector.Rival(way: 9, limit: Self.sixty, distance: 25)])
        }
        #expect(same.shown == Self.sixty)
        #expect(far.shown == Self.thirty)
        // An untagged rival counts as a different limit.
        var untagged = SpeedLimitSelector()
        for k in 0..<5 {
            untagged.update(point: Self.p(Double(k) * 15), accuracy: 5, speed: 15, matchedWay: 1, limit: Self.thirty, distance: 3,
                            rivals: [SpeedLimitSelector.Rival(way: 9, limit: nil, distance: 5)])
        }
        #expect(untagged.shown == nil)
    }

    @Test func overTheLimitNeedsTwoSecondsBothWaysAndAnAccurateSpeed() {
        let limit = Self.thirty // 13.41 m/s; on above 15.65, off at or below 14.75
        var d = OverLimitDetector()
        let r10 = d.update(time: 0, speed: 16, speedAccuracy: 0.5, limit: limit)
        #expect(!r10)
        let r11 = d.update(time: 1, speed: 16, speedAccuracy: 0.5, limit: limit)
        #expect(!r11)
        let r12 = d.update(time: 2, speed: 16, speedAccuracy: 0.5, limit: limit)
        #expect(r12, "2 s above")
        #expect(d.excess == 6) // 16 m/s is 35.8 mph: 36 - 30
        // Between the thresholds it stays on.
        let r13 = d.update(time: 3, speed: 15.2, speedAccuracy: 0.5, limit: limit)
        #expect(r13)
        let r14 = d.update(time: 4, speed: 14.5, speedAccuracy: 0.5, limit: limit)
        #expect(r14)
        let r15 = d.update(time: 5, speed: 14.5, speedAccuracy: 0.5, limit: limit)
        #expect(r15)
        let r16 = d.update(time: 6, speed: 14.5, speedAccuracy: 0.5, limit: limit)
        #expect(!r16, "2 s at or below +3 mph")
        #expect(d.excess == nil)
        // An inaccurate speed is ignored and breaks the 2 s.
        var g = OverLimitDetector()
        g.update(time: 0, speed: 20, speedAccuracy: 0.5, limit: limit)
        g.update(time: 1, speed: 20, speedAccuracy: 3, limit: limit)
        let r17 = g.update(time: 2, speed: 20, speedAccuracy: 0.5, limit: limit)
        #expect(!r17)
        let r18 = g.update(time: 3, speed: 20, speedAccuracy: nil, limit: limit)
        #expect(!r18)
        // A short spike does not count.
        var spike = OverLimitDetector()
        spike.update(time: 0, speed: 20, speedAccuracy: 0.5, limit: limit)
        spike.update(time: 1, speed: 13, speedAccuracy: 0.5, limit: limit)
        let r19 = spike.update(time: 2, speed: 20, speedAccuracy: 0.5, limit: limit)
        #expect(!r19)
        // km/h margins: on above +8 km/h.
        var k = OverLimitDetector()
        let fifty = SpeedLimit(value: 50, unit: .kmh)
        for t in 0...2 { k.update(time: Double(t), speed: 58.5 / 3.6, speedAccuracy: 0.5, limit: fifty) }
        #expect(k.over)
        var under = OverLimitDetector()
        for t in 0...4 { under.update(time: Double(t), speed: 57.5 / 3.6, speedAccuracy: 0.5, limit: fifty) }
        #expect(!under.over)
    }

    /// Feeds a drive through the live roads in 2-fix batches (as the app does) and returns the limit
    /// shown after every batch.
    static func liveLimits(_ c: OracleCase, drive: Int) async throws -> [SpeedLimit?] {
        let fixes = RoadAnalysisTests.fixes(c.drives[drive])
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        var out: [SpeedLimit?] = []
        for start in stride(from: 0, to: fixes.count, by: 2) {
            out.append(await live.feed(Array(fixes[start..<min(fixes.count, start + 2)])).speedLimit)
        }
        return out
    }

    /// I-35E Stemmons: main lanes 60 mph, frontage 40 mph side by side. The frontage must never show
    /// 60 (and the main lanes never 40); where both are candidates the sign is hidden.
    @Test func theFrontageNeverShowsTheFreewayLimit() async throws {
        let c = try OracleCase.load(1)
        for (k, d) in c.drives.enumerated() {
            let shown = try await Self.liveLimits(c, drive: k)
            let values = shown.compactMap { $0 }
            let share = Double(values.count) / Double(max(1, shown.count))
            print("LIMIT case 1 \(d.label): shown in \(Int(share * 100)) % of batches, values \(Set(values.map { "\($0.value) \($0.unitLabel)" }).sorted())")
            if d.label.contains("frontage") {
                #expect(!values.contains(Self.sixty), "\(d.label) showed 60 mph")
                #expect(values.contains(SpeedLimit(value: 40, unit: .mph)), "\(d.label) never showed its own 40 mph")
            } else {
                #expect(values.contains(Self.sixty), "\(d.label) never showed its own 60 mph")
                #expect(!values.contains(SpeedLimit(value: 40, unit: .mph)), "\(d.label) showed 40 mph")
            }
        }
    }

    /// Fixes along a way of a fixture: one per second at `speed` m/s, in the way's order.
    static func drive(way id: Int64, in e: OSMElements, speed: Double, start: Double = 1_794_420_000) -> [Fix] {
        let nodes = Dictionary(e.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let way = e.ways.first { $0.id == id }!
        let pts = way.nodes.compactMap { nodes[$0] }.map { LatLon(lat: $0.lat, lon: $0.lon) }
        let length = OSMGeo.lineLength(pts)
        var out: [Fix] = []
        var d = 0.0, t = start
        while d <= length {
            let p = TrailGeometry.point(along: pts, at: d)!
            out.append(Fix(timestampMs: Int64(t * 1000), latitude: p.point.lat, longitude: p.point.lon, horizontalAccuracy: 5,
                           speed: speed, speedAccuracy: 0.5, course: p.bearing))
            d += speed
            t += 1
        }
        return out
    }

    /// The downtown fixture's North Ervay Street (way 9978059, one-way, 30 mph): the sign shows
    /// 30 mph, and not before three fixes and 30 m on the way. The case 6 oracle drive itself runs
    /// on Elm, Griffin and Commerce, which carry no limit, so it shows none (also asserted).
    @Test func downtownShowsThirtyAfterTheStabilityRule() async throws {
        let c = try OracleCase.load(6)
        let fixes = Self.drive(way: 9_978_059, in: c.elements, speed: 12)
        let cache = RoadTileCache(directory: Fixtures.tempDir())
        for key in RoadAnalyzer.tiles(for: fixes) { try cache.write(key, elements: c.elements) }
        let live = LiveRoads(local: LocalTiles(cache: cache, pack: nil))
        await live.reset()
        var shown: [SpeedLimit?] = []
        for f in fixes { shown.append(await live.feed([f]).speedLimit) }
        let first = shown.firstIndex { $0 != nil }
        print("LIMIT North Ervay: \(fixes.count) fixes, first shown at fix \(first ?? -1), shown in \(shown.compactMap { $0 }.count), values \(Set(shown.compactMap { $0.map { "\($0.value) \($0.unitLabel)" } }).sorted())")
        #expect(Set(shown.compactMap { $0 }) == [Self.thirty])
        #expect((first ?? 0) >= 2, "not before three fixes on one way")
        let caseSix = try await Self.liveLimits(c, drive: 0)
        #expect(caseSix.allSatisfy { $0 == nil }, "Elm, Griffin and Commerce carry no maxspeed")
    }

    /// SPEC 17.9: the selector says why it shows no sign.
    @Test func everyHiddenSignHasItsReason() {
        func run(limit: SpeedLimit?, accuracy: Double = 5, rivals: [SpeedLimitSelector.Rival] = [], qualified: Bool = false) -> SpeedLimitSelector {
            var s = SpeedLimitSelector()
            for k in 0..<4 {
                s.update(point: Self.p(Double(k) * 15), accuracy: accuracy, speed: 10, matchedWay: 1, limit: limit, qualified: qualified,
                         distance: 2, rivals: rivals)
            }
            return s
        }
        #expect(run(limit: Self.thirty).hidden == nil)
        #expect(run(limit: nil).hidden == .noTag)
        #expect(run(limit: Self.thirty, accuracy: 20).hidden == .inaccurate)
        #expect(run(limit: Self.thirty, rivals: [.init(way: 2, limit: nil, distance: 5)]).hidden == .contested)
        #expect(run(limit: Self.thirty, qualified: true).hidden == .qualified)
        var s = SpeedLimitSelector()
        s.update(point: Self.p(0), accuracy: 5, speed: 10, matchedWay: 1, limit: Self.thirty, distance: 2, rivals: [])
        #expect(s.hidden == .unstable, "one fix is not stable yet")
        s.update(point: Self.p(10), accuracy: 5, speed: 10, matchedWay: nil, limit: nil, distance: 0, rivals: [])
        #expect(s.hidden == .unstable, "unmatched")
        #expect(SpeedLimitText.now(Self.thirty, hidden: nil).hasSuffix("laut OSM"))
        #expect(SpeedLimitText.now(nil, hidden: .noTag) == "Kein Tempolimit in OSM eingetragen")
        #expect(SpeedLimitText.label("noRoadData") == "Keine Straßendaten hier (Kacheln fehlen)")
    }
}
