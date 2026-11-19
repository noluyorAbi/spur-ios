import Foundation
import Testing
@testable import Spur

/// SPEC 15: driven directions per OSM edge.
struct CoverageTests {
    /// A straight way 1-2-3 going east, 100 m per edge, as one segment.
    static func segment(oneway: Bool = false) -> RoadSegment {
        let coords = [LatLon(lat: 32.78, lon: -96.80), LatLon(lat: 32.78, lon: -96.80 + 0.0010658), LatLon(lat: 32.78, lon: -96.80 + 0.0021316)]
        let cum = [0, OSMGeo.haversine(coords[0], coords[1]), OSMGeo.haversine(coords[0], coords[1]) + OSMGeo.haversine(coords[1], coords[2])]
        return RoadSegment(id: "10:1:3", wayId: 10, fromNode: 1, toNode: 3, nodeIds: [1, 2, 3], coords: coords, cum: cum,
                           length: cum[2], tags: ["highway": "residential"], categories: [.local],
                           directions: oneway ? [.forward] : [.forward, .backward])
    }

    static func piece(_ d: TravelDirection, _ from: Double, _ to: Double) -> DrivenPiece {
        DrivenPiece(segment: 0, direction: d, from: from, to: to, startTime: 0, endTime: 10)
    }

    static func edgeStates(_ c: TripCoverage) -> [String: String] {
        var out: [String: String] = [:]
        for e in RoadCoverage.edges(c) { out["\(e.key.a)-\(e.key.b)"] = "\(e.forward ? "f" : "")\(e.backward ? "b" : "")" }
        return out
    }

    @Test func anEdgeDirectionNeedsSeventyPercentOfItsLength() {
        let s = Self.segment()
        let edge = s.cum[1]
        var acc = CoverageAccumulator()
        // Edge 1-2 covered 0..80 % forward; edge 2-3 only 50 %.
        acc.add(Self.piece(.forward, 0.2 * edge, edge), segment: s)
        acc.add(Self.piece(.forward, edge, edge + 0.5 * (s.length - edge)), segment: s)
        #expect(Self.edgeStates(acc.coverage()) == ["1-2": "f"])
    }

    @Test func piecesOfOneTripAreUnitedPerDirection() {
        let s = Self.segment()
        let edge = s.cum[1]
        var acc = CoverageAccumulator()
        // Two overlapping 45 % pieces: 75 % united, driven. Overlap counts once.
        acc.add(Self.piece(.forward, 0, 0.45 * edge), segment: s)
        acc.add(Self.piece(.forward, 0.30 * edge, 0.75 * edge), segment: s)
        #expect(Self.edgeStates(acc.coverage())["1-2"] == "f")
        var twice = CoverageAccumulator()
        twice.add(Self.piece(.forward, 0, 0.4 * edge), segment: s)
        twice.add(Self.piece(.forward, 0, 0.4 * edge), segment: s)
        #expect(twice.coverage().runs.isEmpty, "the same 40 % twice is still 40 %")
        #expect(abs(CoverageAccumulator.unitedLength([0...4, 2...6, 8...9]) - 7) < 1e-9)
    }

    @Test func backwardPiecesMapToTheWaysOrder() {
        let s = Self.segment()
        var acc = CoverageAccumulator()
        // Backward from the segment's east end: its first 90 m are the end of edge 2-3.
        acc.add(Self.piece(.backward, 0, 0.9 * (s.length - s.cum[1])), segment: s)
        #expect(Self.edgeStates(acc.coverage()) == ["2-3": "b"])
        acc.add(Self.piece(.forward, 0, s.length), segment: s)
        #expect(Self.edgeStates(acc.coverage()) == ["1-2": "f", "2-3": "fb"])
    }

    @Test func statesFollowTheDrivenDirections() {
        #expect(RoadCoverage.state(forward: true, backward: true) == .both)
        #expect(RoadCoverage.state(forward: true, backward: false) == .one)
        #expect(RoadCoverage.state(forward: false, backward: true) == .one)
        #expect(RoadCoverage.state(forward: false, backward: false) == nil)
        // A one-way way driven in its only direction stays one direction (SPEC 15.1).
        let s = Self.segment(oneway: true)
        var acc = CoverageAccumulator()
        acc.add(Self.piece(.forward, 0, s.length), segment: s)
        let lines = RoadCoverage.lines(acc.coverage().runs)
        #expect(lines.count == 1 && lines[0].state == .one)
    }

    @Test func tripsAreUnitedAndChainedIntoLines() {
        let s = Self.segment()
        var there = CoverageAccumulator()
        there.add(Self.piece(.forward, 0, s.length), segment: s)
        var back = CoverageAccumulator()
        back.add(Self.piece(.backward, 0, s.length - s.cum[1]), segment: s) // only edge 2-3 back
        let merged = RoadCoverage.merge([there.coverage(), back.coverage()])
        #expect(merged.map { "\($0.key.a)-\($0.key.b):\($0.forward)\($0.backward)" } == ["1-2:truefalse", "2-3:truetrue"])
        let runs = RoadCoverage.runs(merged)
        #expect(runs.count == 2, "different directions split the chain")
        let lines = RoadCoverage.lines(runs)
        #expect(Set(lines.map(\.state)) == [.one, .both])
        // Same directions on consecutive edges chain into one run.
        #expect(RoadCoverage.runs(RoadCoverage.edges(there.coverage())).count == 1)
        #expect(there.coverage().runs[0].nodes == [1, 2, 3])
        // A backward-only line is drawn in the driven direction.
        var west = CoverageAccumulator()
        west.add(Self.piece(.backward, 0, s.length), segment: s)
        let w = RoadCoverage.lines(west.coverage().runs)[0]
        #expect(w.coords.first == s.coords.last && w.coords.last == s.coords.first)
    }

    @Test func marksSitEverySpacingAndShortLinesGetOneAtTheMiddle() {
        let east = (0...10).map { LatLon(lat: 32.78, lon: -96.80 + Double($0) * 0.0010658) } // about 1000 m
        let length = OSMGeo.lineLength(east)
        let marks = TrailGeometry.marks(along: east, spacing: 200)
        #expect(marks.count == 5)
        #expect(marks.allSatisfy { abs($0.1 - 90) < 1 }, "all point east")
        let firstOffset = Geo.distance(lat1: east[0].lat, lon1: east[0].lon, lat2: marks[0].0.lat, lon2: marks[0].0.lon)
        #expect(abs(firstOffset - 100) < 1)
        #expect(TrailGeometry.marks(along: Array(east.prefix(2)), spacing: 200).count == 1) // 100 m, at least 40 %
        #expect(TrailGeometry.marks(along: Array(east.prefix(2)), spacing: 400).isEmpty) // 100 m, under 40 % of 400
        // A growing trail keeps its earlier marks where they were.
        let grown = east + [LatLon(lat: 32.78, lon: -96.80 + 11 * 0.0010658)]
        #expect(Array(TrailGeometry.marks(along: grown, spacing: 200).prefix(5)).map(\.0) == marks.map(\.0))
        #expect(length > 990 && length < 1010)
    }

    @Test func arrowsKeepTheBudgetNearestFirstAndBothWaysArePairs() {
        let east = (0...10).map { LatLon(lat: 32.78, lon: -96.80 + Double($0) * 0.0010658) }
        let line = RoadCoverage.Line(id: "a", coords: east, state: .both, length: OSMGeo.lineLength(east), center: east[5])
        // 997 m at 200 m spacing would be 5 marks: with a budget of 2 the spacing doubles to
        // 400 m (marks at 200 and 600 m), thinned along the whole line instead of cut at one end.
        let arrows = RoadCoverage.arrows([line], spacing: 200, minLength: 20, chord: 20, center: east[10], budget: 2)
        #expect(arrows.count == 2 && arrows.allSatisfy(\.both))
        let fromStart = arrows.map { OSMGeo.haversine(east[0], $0.point) }.sorted()
        #expect(abs(fromStart[0] - 200) < 2 && abs(fromStart[1] - 600) < 2, "\(fromStart)")
        let five = RoadCoverage.arrows([line], spacing: 200, minLength: 20, chord: 20, center: east[10], budget: 10)
        #expect(five.count == 5)
        let pair = RoadCoverage.chevrons(arrows[0], size: 20)
        #expect(pair.count == 2 && pair.allSatisfy { $0.count == 3 })
        // Two chevrons pointing away from each other, staggered on the line with a clear gap
        // (side by side they read as "VA", nearly touching as a diamond).
        #expect(pair[0][1].lon > pair[0][0].lon && pair[1][1].lon < pair[1][0].lon)
        let gap = OSMGeo.haversine(pair[0][0], pair[1][0]) // left wing of each, at their bases
        #expect(gap > 15, "bases \(gap) m apart")
        let single = RoadCoverage.chevrons(RoadCoverage.Arrow(point: east[5], bearing: 90, both: false), size: 20)
        #expect(single.count == 1 && single[0][1].lon > east[5].lon)
        #expect(RoadCoverage.arrows([line], spacing: 200, minLength: 20, chord: 20, center: east[0], budget: 10) { _ in false }.isEmpty)
    }

    @Test func storedCoverageRoundTrips() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let record = TripRecord(startedAt: Date(), isRecording: false)
        try store.create(record)
        #expect(!store.hasCoverage(record.id))
        let s = Self.segment()
        var acc = CoverageAccumulator()
        acc.add(Self.piece(.forward, 0, s.length), segment: s)
        try store.saveCoverage(acc.coverage(), for: record.id)
        #expect(store.hasCoverage(record.id))
        #expect(store.loadCoverage(record.id) == acc.coverage())
        try store.saveCoverage(TripCoverage(), for: record.id)
        #expect(store.loadCoverage(record.id)?.runs.isEmpty == true, "an empty result is stored too")
    }

    /// The tiles a chunk asks for get only the ways that touch them, as a real pack does, so the
    /// segment ends (and ids) differ between chunks; the driven edges must not.
    static func tileLoader(_ elements: OSMElements) -> ([TileKey]) -> RoadTileProvider.Lookup {
        let nodeTile = Dictionary(uniqueKeysWithValues: elements.nodes.map { ($0.id, TileKey.containing(lat: $0.lat, lon: $0.lon)) })
        let nodesById = Dictionary(uniqueKeysWithValues: elements.nodes.map { ($0.id, $0) })
        return { keys in
            let wanted = Set(keys)
            let ways = elements.ways.filter { w in w.nodes.contains { nodeTile[$0].map(wanted.contains) ?? false } }
            let ids = Set(ways.flatMap(\.nodes))
            let nodes = ids.compactMap { nodesById[$0] }
            var e = elements
            e.ways = ways
            e.nodes = nodes
            return RoadTileProvider.Lookup(elements: e, sources: Dictionary(uniqueKeysWithValues: keys.map { ($0, .pack) }), missing: [])
        }
    }

    /// Case 8 drives out north, around the block and back south: both directions on the way back.
    @Test func case8DrivesStreetsBothWaysAndChunksDoNotChangeTheEdges() throws {
        let c = try OracleCase.load(8)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let load = Self.tileLoader(c.elements)
        let whole = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1000, load: load)
        let split = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1, load: load)
        let edges = RoadCoverage.edges(whole.coverage)
        let both = edges.filter { $0.forward && $0.backward }
        let length = edges.reduce(0) { $0 + OSMGeo.haversine($1.a, $1.b) }
        let bothLength = both.reduce(0) { $0 + OSMGeo.haversine($1.a, $1.b) }
        let splitEdges = RoadCoverage.edges(split.coverage)
        let a = Set(edges.map { "\($0.key.wayId):\($0.key.a):\($0.key.b):\($0.forward):\($0.backward)" })
        let b = Set(splitEdges.map { "\($0.key.wayId):\($0.key.a):\($0.key.b):\($0.forward):\($0.backward)" })
        #expect(RoadAnalyzer.chunks(fixes, maxTiles: 1).count > 1, "the split run really has several chunks")
        print("COVERAGE case 8: \(edges.count) driven edges, \(Int(length)) m, both directions \(both.count) edges \(Int(bothLength)) m, runs \(whole.coverage.runs.count); chunks of one tile: \(RoadAnalyzer.chunks(fixes, maxTiles: 1).count), edges \(splitEdges.count), differing \(a.symmetricDifference(b).count)")
        #expect(!edges.isEmpty)
        #expect(bothLength > 500, "the way back drives the way out the other way")
        #expect(length > bothLength)
        #expect(a == b)
    }

    @Test func linesJoinAcrossWaysAndThroughJunctions() {
        func p(_ x: Double) -> LatLon { LatLon(lat: 32.78, lon: -96.80 + x * 0.001) }
        func line(_ id: String, _ xs: [Double], _ state: RoadCoverage.State) -> RoadCoverage.Line {
            let c = xs.map(p)
            return RoadCoverage.Line(id: id, coords: c, state: state, length: OSMGeo.lineLength(c), center: c[0])
        }
        // Three one-direction ways east in a row: one line.
        let east = RoadCoverage.joined([line("a", [0, 1], .one), line("b", [1, 2], .one), line("c", [2, 3], .one)])
        #expect(east.count == 1 && east[0].coords == [p(0), p(1), p(2), p(3)])
        // Head to head (east, then west into the same point): two lines.
        #expect(RoadCoverage.joined([line("a", [0, 1], .one), line("b", [2, 1], .one)]).count == 2)
        // A both line entered at its end is walked backwards.
        let both = RoadCoverage.joined([line("a", [0, 1], .both), line("b", [2, 1], .both)])
        #expect(both.count == 1 && both[0].coords == [p(0), p(1), p(2)])
        // Different states: no join.
        #expect(RoadCoverage.joined([line("a", [0, 1], .one), line("b", [1, 2], .both)]).count == 2)
        // A junction joins the straightest continuation (an overlap at a junction is invisible):
        // east, then east again, not the street turning north.
        let north = RoadCoverage.Line(id: "c", coords: [p(1), LatLon(lat: 32.781, lon: p(1).lon)], state: .one, length: 111, center: p(1))
        let junction = RoadCoverage.joined([line("a", [0, 1], .one), north, line("b", [1, 2], .one)])
        #expect(junction.count == 2)
        #expect(junction.contains { $0.coords == [p(0), p(1), p(2)] })
        // Length is the sum.
        #expect(abs(east[0].length - OSMGeo.lineLength([p(0), p(1), p(2), p(3)])) < 0.01)
    }

    /// A trip matched almost entirely is drawn by its directions: the raw preview layer rebuilds
    /// when a trip crosses the threshold (SPEC 15.2).
    @Test func theDrivenLayerKeyFollowsTheMatchedShare() {
        var r = TripRecord(startedAt: Date(), isRecording: false)
        r.preview = [[LatLon(lat: 1, lon: 2), LatLon(lat: 1.001, lon: 2)]]
        r.roads = RoadStatistics(analyzedAt: Date(), coverage: 0.5)
        let low = LiveMapView.drivenKey([r])
        r.roads?.coverage = 0.97
        #expect(LiveMapView.drivenKey([r]) != low)
        #expect(LiveMapView.matchedEnough == 0.95)
    }
}
