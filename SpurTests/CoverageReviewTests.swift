import Foundation
import Testing
@testable import Spur

/// Regression tests for the findings of the SPEC 15 review.
struct CoverageReviewTests {
    static func segment(_ ids: [Int64], spacingDeg: Double = 0.0010658, directions: [TravelDirection] = [.forward, .backward],
                        way: Int64 = 10) -> RoadSegment {
        let coords = ids.indices.map { LatLon(lat: 32.78, lon: -96.80 + Double($0) * spacingDeg) }
        var cum: [Double] = [0]
        for k in 1..<coords.count { cum.append(cum[k - 1] + OSMGeo.haversine(coords[k - 1], coords[k])) }
        return RoadSegment(id: "\(way):\(ids.first!):\(ids.last!)", wayId: way, fromNode: ids.first!, toNode: ids.last!, nodeIds: ids,
                           coords: coords, cum: cum, length: cum.last!, tags: ["highway": "residential"], categories: [.local],
                           directions: directions)
    }

    static func piece(_ d: TravelDirection, _ from: Double, _ to: Double, bridged: Bool = false) -> DrivenPiece {
        DrivenPiece(segment: 0, direction: d, from: from, to: to, startTime: 0, endTime: 10, bridged: bridged)
    }

    static func states(_ c: TripCoverage) -> [String: String] { CoverageTests.edgeStates(c) }

    // 10, 12, 13

    @Test func bridgedIllegalAndSliverPiecesNeverCount() {
        let s = Self.segment([1, 2, 3])
        var bridged = CoverageAccumulator()
        bridged.add(Self.piece(.forward, 0, s.length, bridged: true), segment: s)
        #expect(bridged.coverage().runs.isEmpty, "a route guessed across a GPS gap is not driven")
        // oneway=-1: only backward is legal.
        let reverse = Self.segment([1, 2, 3], directions: [.backward])
        var illegal = CoverageAccumulator()
        illegal.add(Self.piece(.forward, 0, reverse.length), segment: reverse)
        #expect(illegal.coverage().runs.isEmpty)
        illegal.add(Self.piece(.backward, 0, reverse.length), segment: reverse)
        #expect(Self.states(illegal.coverage()) == ["1-2": "b", "2-3": "b"])
        // A backward piece that ends exactly at node 2 must not touch edge 1-2 with a sliver.
        let short = Self.segment([1, 2, 3], spacingDeg: 0.000004) // edges of about 0.37 m
        var sliver = CoverageAccumulator()
        sliver.add(Self.piece(.backward, 0, short.length - short.cum[1]), segment: short)
        #expect(Self.states(sliver.coverage()) == ["2-3": "b"])
    }

    // 17: a U-turn on one edge, a closed way

    @Test func aUTurnOnOneEdgeIsBothAndAClosedWayChains() {
        let s = Self.segment([1, 2])
        var u = CoverageAccumulator()
        u.add(Self.piece(.forward, 0, 0.9 * s.length), segment: s)
        u.add(Self.piece(.backward, 0, 0.9 * s.length), segment: s)
        #expect(Self.states(u.coverage()) == ["1-2": "fb"])
        // A closed way 1-2-3-1 driven forward all round: one run of four nodes.
        let coords = [LatLon(lat: 32.78, lon: -96.80), LatLon(lat: 32.781, lon: -96.80), LatLon(lat: 32.781, lon: -96.799), LatLon(lat: 32.78, lon: -96.80)]
        var cum: [Double] = [0]
        for k in 1..<4 { cum.append(cum[k - 1] + OSMGeo.haversine(coords[k - 1], coords[k])) }
        let loop = RoadSegment(id: "20:1:1", wayId: 20, fromNode: 1, toNode: 1, nodeIds: [1, 2, 3, 1], coords: coords, cum: cum,
                               length: cum[3], tags: [:], categories: [.local], directions: [.forward])
        var l = CoverageAccumulator()
        l.add(DrivenPiece(segment: 0, direction: .forward, from: 0, to: loop.length, startTime: 0, endTime: 1), segment: loop)
        let runs = l.coverage().runs
        #expect(runs.count == 1 && runs[0].nodes.count == 4)
    }

    // 18

    @Test func shortGapsAlongAWayAreFilledLongOnesNot() {
        // Four edges of about 100 m each; edges 1-2 and 4-5 driven, 2-3 and 3-4 only 40 %.
        let s = Self.segment([1, 2, 3, 4, 5])
        var acc = CoverageAccumulator()
        acc.add(Self.piece(.forward, 0, s.cum[1]), segment: s)
        acc.add(Self.piece(.forward, s.cum[3], s.length), segment: s)
        acc.add(Self.piece(.forward, s.cum[1], s.cum[1] + 40), segment: s)
        #expect(Self.states(acc.coverage()) == ["1-2": "f", "4-5": "f"], "a 200 m gap stays open")
        // Edges of about 20 m: a 40 m gap between driven edges is filled.
        let near = Self.segment([1, 2, 3, 4, 5], spacingDeg: 0.000213)
        var b = CoverageAccumulator()
        b.add(Self.piece(.forward, 0, near.cum[1]), segment: near)
        b.add(Self.piece(.forward, near.cum[3], near.length), segment: near)
        #expect(Self.states(b.coverage()) == ["1-2": "f", "2-3": "f", "3-4": "f", "4-5": "f"])
    }

    @Test func isolatedScrapsAreDroppedButShortLinesAtOthersStay() {
        func line(_ id: String, _ a: LatLon, _ b: LatLon) -> RoadCoverage.Line {
            RoadCoverage.Line(id: id, coords: [a, b], state: .one, length: OSMGeo.haversine(a, b), center: a)
        }
        let p0 = LatLon(lat: 32.78, lon: -96.80), p1 = LatLon(lat: 32.78, lon: -96.7999), p2 = LatLon(lat: 32.78, lon: -96.79)
        let far = LatLon(lat: 32.79, lon: -96.80), far2 = LatLon(lat: 32.79, lon: -96.7999)
        let out = RoadCoverage.dropIsolated([line("scrap", far, far2), line("short", p0, p1), line("long", p1, p2)])
        #expect(Set(out.map(\.id)) == ["short", "long"])
    }

    // 2

    @Test func manyLinesAreThinnedAndEveryLineGetsAMark() {
        // 30 parallel lines of 500 m: 3 marks each at 160 m spacing would be 90 > 40.
        let lines = (0..<30).map { k -> RoadCoverage.Line in
            let c = [LatLon(lat: 32.78 + Double(k) * 0.001, lon: -96.80), LatLon(lat: 32.78 + Double(k) * 0.001, lon: -96.80 + 0.00533)]
            return RoadCoverage.Line(id: "l\(k)", coords: c, state: .one, length: OSMGeo.lineLength(c), center: c[0])
        }
        let arrows = RoadCoverage.arrows(lines, spacing: 160, minLength: 30, chord: 20, center: lines[0].coords[0], budget: 40)
        #expect(arrows.count == 30, "one per line once the spacing has doubled")
        #expect(Set(arrows.map { $0.id.split(separator: "#").first! }).count == 30)
        #expect(RoadCoverage.markCount(length: 500, spacing: 160, minLength: 30) == 3)
        #expect(RoadCoverage.markCount(length: 100, spacing: 160, minLength: 30) == 1)
        #expect(RoadCoverage.markCount(length: 20, spacing: 160, minLength: 30) == 0)
    }

    // 16

    @Test func aMarkOnACornerPointsAlongTheChord() {
        // East 100 m, then north 100 m; a mark at 100 m sits on the corner.
        let corner = LatLon(lat: 32.78, lon: -96.80 + 0.0010658)
        let pts = [LatLon(lat: 32.78, lon: -96.80), corner, LatLon(lat: 32.78 + 0.0008993, lon: corner.lon)]
        let plain = TrailGeometry.marks(along: pts, spacing: 200)
        let chord = TrailGeometry.marks(along: pts, spacing: 200, chord: 40)
        #expect(plain.count == 1 && chord.count == 1)
        #expect(abs(chord[0].1 - 45) < 3, "chord bearing \(chord[0].1)")
    }

    // 3

    @Test func incrementalMarksAndRunsMatchTheWholeComputation() {
        let pts = (0..<200).map { k in LatLon(lat: 32.78 + Double(k) * 0.0001 * sin(Double(k) / 20), lon: -96.80 + Double(k) * 0.0001) }
        var m = TrailGeometry.Marker(spacing: 120, chord: 12)
        for chunk in stride(from: 0, to: pts.count, by: 7) { m.extend(pts[chunk..<min(pts.count, chunk + 7)]) }
        let whole = TrailGeometry.marks(along: pts, spacing: 120, chord: 12)
        #expect(m.marks.count >= whole.count - 1 && m.marks.count <= whole.count)
        for (a, b) in zip(m.marks, whole) {
            #expect(OSMGeo.haversine(a.point, b.0) < 0.01)
            #expect(abs(a.bearing - b.1) < 0.01)
        }
        let fixes = Fixtures.northbound(speeds: Array(repeating: 15, count: 120))
        var builder = TrailGeometry.RunBuilder()
        builder.extend(Array(fixes.prefix(50)), config: .default)
        builder.extend(fixes, config: .default)
        #expect(builder.all == TrailGeometry.displayRuns(fixes, config: .default))
    }

    // 6

    @Test func zoomStepsKeepMarksBetweenTenAndFifteenPoints() {
        var step = 0.0
        var sizes: [Double] = []
        for mpp in stride(from: 1.0, through: 40, by: 0.37) {
            step = LiveMapView.zoomStep(mpp, current: step)
            sizes.append(LiveMapView.markSizePoints * step / mpp)
        }
        #expect(sizes.min()! >= 10 - 1e-9 && sizes.max()! <= 14.4 + 1e-9, "\(sizes.min()!) ... \(sizes.max()!)")
        #expect(LiveMapView.zoomStep(7.5, current: 7.0) == 7.0, "within 1.2: kept")
    }

    // 9

    @Test func aDegradedRunNeverReplacesStoredRoadData() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        var good = RoadStatistics(analyzedAt: Date(timeIntervalSince1970: 1_000))
        good.matchedDistance = 900
        good.counts.signalSites = 7
        _ = try store.update(id) { $0.roads = good }
        // No tiles anywhere now (evicted), and no coverage.json: the backfill re-analyzes it.
        let service = await RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                        cache: RoadTileCache(directory: Fixtures.tempDir()), client: nil)
        await service.analyzeMissing([try store.load(id)])
        let ran = await ReviewV11.wait(30) { await service.completedRuns >= 1 }
        #expect(ran)
        let after = try store.load(id).roads
        #expect(after?.matchedDistance == 900 && after?.counts.signalSites == 7, "stored roads were replaced")
        #expect(!store.hasCoverage(id), "no coverage from a run without its tiles")
        var worse = RoadStatistics(analyzedAt: Date())
        worse.missingTiles = [TileKey(x: 1, y: 1)]
        #expect(RoadService.isDegraded(worse, stored: good))
        #expect(!RoadService.isDegraded(worse, stored: nil))
        worse.missingTiles = nil
        #expect(!RoadService.isDegraded(worse, stored: good), "all tiles there: the new run wins")
    }

    // 11

    @MainActor
    @Test func anUnreadableCoverageFileSendsTheTripBackToTheAnalysis() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        _ = try store.update(id) { $0.roads = RoadStatistics(analyzedAt: Date()) }
        try Data("{broken".utf8).write(to: store.coverageURL(id))
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                  cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        // As in the app: a saved analysis reloads the index, which reloads the coverage.
        service.onTripUpdated = { _ in service.reloadCoverage([(try? store.load(id))].compactMap { $0 }) }
        service.reloadCoverage([try store.load(id)])
        let healed = await ReviewV11.wait(30) { store.loadCoverage(id) != nil }
        #expect(healed)
        #expect(await ReviewV11.wait(10) { service.coveredTripIds.contains(id) })
        #expect(service.coverageRevision >= 1)
    }

    // 10: through the HMM, a gap in the fixes yields bridged pieces that coverage ignores.

    @Test func aGPSGapBridgesWithoutCountingAsDriven() throws {
        let c = try OracleCase.load(6)
        let all = RoadAnalysisTests.fixes(c.drives[0])
        // An 8 s hole in a moving stretch where the car changes edges: the route in between is bridged.
        // (Across a gap on one edge, as at the red light, nothing is guessed and nothing is flagged.)
        var found: (Int, MatchResult)?
        for start in stride(from: 5, to: all.count - 20, by: 3) {
            var fixes = all
            fixes.removeSubrange(start..<(start + 8))
            let match = HMMMatcher.match(fixes.map(MatchFix.init), network: c.network)
            if match.pieces.contains(where: \.bridged) {
                found = (start, match)
                break
            }
        }
        let (start, match) = try #require(found, "no 8 s gap in case 6 led to a bridged route")
        let bridged = match.pieces.filter(\.bridged)
        var acc = CoverageAccumulator()
        for p in match.pieces { acc.add(p, segment: c.network.segments[p.segment]) }
        var observed = CoverageAccumulator()
        for p in match.pieces where !p.bridged { observed.add(p, segment: c.network.segments[p.segment]) }
        #expect(acc.coverage() == observed.coverage())
        print("GAP case 6 without fixes \(start)..<\(start + 8): \(bridged.count) bridged pieces, \(Int(bridged.reduce(0) { $0 + $1.length })) m, not in coverage")
    }
}
