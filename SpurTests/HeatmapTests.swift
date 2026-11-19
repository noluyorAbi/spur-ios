import Foundation
import Testing
@testable import Spur

/// SPEC 18.7: how often a road was driven.
struct HeatmapTests {
    typealias R = CoverageReviewTests

    static func passes(_ c: TripCoverage) -> [String: (Int, Int)] {
        var out: [String: (Int, Int)] = [:]
        for e in RoadCoverage.edges(c) { out["\(e.key.a)-\(e.key.b)"] = (e.forwardPasses, e.backwardPasses) }
        return out
    }

    @Test func aLoopOverTheSameEdgeCountsTwice() {
        let a = R.segment([1, 2], way: 10)
        let b = R.segment([5, 6], way: 11)
        var acc = CoverageAccumulator()
        acc.add(R.piece(.forward, 0, a.length), segment: a)
        acc.add(R.piece(.forward, 0, b.length), segment: b)
        acc.add(R.piece(.forward, 0, a.length), segment: a)
        let p = Self.passes(acc.coverage())
        #expect(p["1-2"]?.0 == 2 && p["1-2"]?.1 == 0)
        #expect(p["5-6"]?.0 == 1)
    }

    @Test func bothDirectionsCountSeparately() {
        let s = R.segment([1, 2])
        var acc = CoverageAccumulator()
        acc.add(R.piece(.forward, 0, s.length), segment: s)
        acc.add(R.piece(.backward, 0, s.length), segment: s)
        let p = Self.passes(acc.coverage())
        #expect(p["1-2"]?.0 == 1 && p["1-2"]?.1 == 1)
    }

    /// One traversal reported in consecutive pieces is one pass, not two.
    @Test func consecutivePiecesAreOneTraversal() {
        let s = R.segment([1, 2])
        var acc = CoverageAccumulator()
        acc.add(R.piece(.forward, 0, 0.5 * s.length), segment: s)
        acc.add(R.piece(.forward, 0.5 * s.length, s.length), segment: s)
        #expect(Self.passes(acc.coverage())["1-2"]?.0 == 1)
    }

    /// A short second touch (under 70 % of the edge) is not a pass.
    @Test func aGrazeIsNotAPass() {
        let a = R.segment([1, 2], way: 10)
        let b = R.segment([5, 6], way: 11)
        var acc = CoverageAccumulator()
        acc.add(R.piece(.forward, 0, a.length), segment: a)
        acc.add(R.piece(.forward, 0, b.length), segment: b)
        acc.add(R.piece(.forward, 0, 0.3 * a.length), segment: a)
        #expect(Self.passes(acc.coverage())["1-2"]?.0 == 1)
    }

    /// Files before 1.4 have no counts: 1 per driven direction.
    @Test func oldFilesCountOncePerDrivenDirection() throws {
        let json = #"{"version":2,"runs":[{"wayId":10,"nodes":[1,2],"coords":[[32.78,-96.8],[32.78,-96.799]],"forward":true,"backward":false}]}"#
        let c = try JSONDecoder().decode(TripCoverage.self, from: Data(json.utf8))
        #expect(c.runs[0].passesForward == 1 && c.runs[0].passesBackward == 0)
        #expect(Self.passes(c)["1-2"]?.0 == 1)
    }

    @Test func mergeSumsPassesAndKeepsTheNewestDate() {
        let s = R.segment([1, 2])
        var one = CoverageAccumulator()
        one.add(R.piece(.forward, 0, s.length), segment: s)
        var two = CoverageAccumulator()
        two.add(R.piece(.forward, 0, s.length), segment: s)
        two.add(R.piece(.backward, 0, s.length), segment: s)
        let early = Date(timeIntervalSince1970: 1_700_000_000), late = Date(timeIntervalSince1970: 1_800_000_000)
        let merged = RoadCoverage.merge([one.coverage(), two.coverage()], dates: [late, early])
        #expect(merged.count == 1)
        #expect(merged[0].forwardPasses == 2 && merged[0].backwardPasses == 1 && merged[0].passes == 3)
        #expect(merged[0].lastDriven == late)
        let heat = RoadCoverage.heatLines(merged)
        #expect(heat.count == 1 && heat[0].passes == 3 && heat[0].bin == 2)
    }

    @Test func binEdges() {
        #expect([1, 2, 3, 4, 5, 9, 10, 40].map(RoadCoverage.heatBin) == [0, 1, 2, 2, 3, 3, 4, 4])
    }

    /// The stored runs carry the counts, and a round trip through JSON keeps them.
    @Test func countsSurviveTheFile() throws {
        let a = R.segment([1, 2], way: 10)
        let b = R.segment([5, 6], way: 11)
        var acc = CoverageAccumulator()
        for _ in 0..<3 {
            acc.add(R.piece(.forward, 0, a.length), segment: a)
            acc.add(R.piece(.forward, 0, b.length), segment: b)
        }
        let back = try JSONDecoder().decode(TripCoverage.self, from: JSONEncoder().encode(acc.coverage()))
        #expect(back.version == 3)
        #expect(Self.passes(back)["1-2"]?.0 == 3 && Self.passes(back)["5-6"]?.0 == 3)
    }

    @Test func theTapSaysHowOftenWhichWayAndWhen() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let line = RoadCoverage.HeatLine(id: "x", coords: [LatLon(lat: 0, lon: 0), LatLon(lat: 0.001, lon: 0)], forwardPasses: 8,
                                         backwardPasses: 4, lastDriven: date, length: 111, center: LatLon(lat: 0.0005, lon: 0),
                                         box: RoadCoverage.Line.box([]), bearing: 0)
        #expect(RoadCoverage.heatInfo(line, calendar: cal) == "12-mal gefahren, 8 Richtung Nord, 4 Richtung Süd, zuletzt am 12.11.")
        var one = line
        one.backwardPasses = 0
        one.forwardPasses = 3
        one.bearing = 90
        one.lastDriven = nil
        #expect(RoadCoverage.heatInfo(one) == "3-mal gefahren, Richtung Ost")
        #expect(RoadCoverage.heatLine(near: LatLon(lat: 0.0005, lon: 0.0001), in: [line], maxMeters: 20)?.id == "x")
        #expect(RoadCoverage.heatLine(near: LatLon(lat: 0.0005, lon: 0.001), in: [line], maxMeters: 20) == nil)
    }
}
