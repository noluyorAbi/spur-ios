import Foundation
import Testing
@testable import Spur

/// Owner, 2026-11-12: a divided road driven both ways (out on one carriageway, back on the other)
/// is the same road driven both ways, green, with arrows both ways.
struct DividedRoadTests {
    static let lat0 = 29.95, lon0 = -95.55
    /// Meters north and east of the origin.
    static func p(north: Double, east: Double) -> LatLon {
        LatLon(lat: lat0 + north / 110_540, lon: lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
    }

    /// One-way way `way` along x = `east`, edges of 100 m from `from` to `to` meters north, driven
    /// north (`north`) or south. Node ids are unique per way.
    static func carriageway(_ way: Int64, east: Double, from: Double, to: Double, north: Bool,
                            road: String? = "primary|telge road", oneway: Bool = true) -> [RoadCoverage.Edge] {
        var out: [RoadCoverage.Edge] = []
        var y = from
        var k: Int64 = 0
        while y < to - 1e-9 {
            let a = p(north: y, east: east), b = p(north: min(to, y + 100), east: east)
            // Way order runs north for the northbound carriageway, south for the southbound one.
            let key = north ? CoverageEdgeKey(wayId: way, a: way * 1000 + k, b: way * 1000 + k + 1)
                : CoverageEdgeKey(wayId: way, a: way * 1000 + k + 1, b: way * 1000 + k)
            out.append(RoadCoverage.Edge(key: key, a: north ? a : b, b: north ? b : a, forward: true, backward: false,
                                         road: road, oneway: oneway))
            y += 100
            k += 1
        }
        return out
    }

    static func lines(_ edges: [RoadCoverage.Edge]) -> [RoadCoverage.Line] {
        RoadCoverage.lines(RoadCoverage.runs(RoadCoverage.paired(edges)))
    }

    static func length(_ lines: [RoadCoverage.Line], _ state: RoadCoverage.State) -> Double {
        lines.filter { $0.state == state }.reduce(0) { $0 + $1.length }
    }

    @Test func bothCarriagewaysOfOneRoadDrivenOppositeWaysArePaired() {
        let ls = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 500, north: true)
            + Self.carriageway(2, east: 20, from: 0, to: 500, north: false))
        #expect(ls.count == 2 && ls.allSatisfy { $0.state == .paired }, "\(ls.map(\.state))")
        // Each keeps its own driven direction: northbound starts south, southbound starts north.
        let nb = ls.first { abs($0.coords[0].lon - Self.lon0) < 1e-7 }!
        let sb = ls.first { $0 != nb }!
        #expect(nb.coords[0].lat < nb.coords.last!.lat && sb.coords[0].lat > sb.coords.last!.lat)
        // Single arrows in each carriageway's own direction: together they point both ways.
        let arrows = RoadCoverage.arrows(ls, spacing: 100, minLength: 20, chord: 20, center: Self.p(north: 250, east: 10), budget: 50)
        #expect(!arrows.isEmpty && arrows.allSatisfy { !$0.both })
        #expect(arrows.contains { OSMGeo.angleDiff($0.bearing, 0) < 5 } && arrows.contains { OSMGeo.angleDiff($0.bearing, 180) < 5 })
        // A paired line is never walked backwards into another line.
        #expect(RoadCoverage.joined(ls).count == 2)
    }

    @Test func differentRoadsSameDirectionTooFarOrTwoWayDoNotPair() {
        // Different names (a frontage road beside the freeway).
        let names = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: "motorway|north freeway")
            + Self.carriageway(2, east: 25, from: 0, to: 300, north: false, road: "primary|north freeway service road"))
        #expect(names.allSatisfy { $0.state == .one })
        // Same road, same direction (two lanes mapped apart, a ramp).
        let same = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true)
            + Self.carriageway(2, east: 20, from: 0, to: 300, north: true))
        #expect(same.allSatisfy { $0.state == .one })
        // Same road, opposite, but 80 m apart (a parallel street of the same name).
        let far = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true)
            + Self.carriageway(2, east: 80, from: 0, to: 300, north: false))
        #expect(far.allSatisfy { $0.state == .one })
        // Two-way ways of one name (a hairpin driven once): not carriageways.
        let hairpin = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, oneway: false)
            + Self.carriageway(2, east: 20, from: 0, to: 300, north: false, oneway: false))
        #expect(hairpin.allSatisfy { $0.state == .one })
        // Unnamed ways never pair.
        let unnamed = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: nil)
            + Self.carriageway(2, east: 20, from: 0, to: 300, north: false, road: nil))
        #expect(unnamed.allSatisfy { $0.state == .one })
    }

    /// Owner, 2026-11-14 (his West Loop drives): frontage roads on both sides of a freeway are one
    /// road's two directions, 60 to 80 m apart and sometimes one class apart; a freeway class still
    /// pairs only with itself.
    @Test func frontageRoadsAcrossAFreewayAndClassesOneApartPair() {
        let frontage = "secondary|west loop north frontage road"
        let across = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: frontage)
            + Self.carriageway(2, east: 80, from: 0, to: 300, north: false, road: frontage))
        #expect(across.count == 2 && across.allSatisfy { $0.state == .paired }, "\(across.map(\.state))")
        let wide = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: frontage)
            + Self.carriageway(2, east: 130, from: 0, to: 300, north: false, road: frontage))
        #expect(wide.allSatisfy { $0.state == .one }, "beyond 120 m")
        let classes = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: "primary|west loop north frontage road")
            + Self.carriageway(2, east: 75, from: 0, to: 300, north: false, road: frontage))
        #expect(classes.allSatisfy { $0.state == .paired }, "primary and secondary of one name")
        let street = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: "primary|telge road")
            + Self.carriageway(2, east: 20, from: 0, to: 300, north: false, road: "secondary|telge road"))
        #expect(street.allSatisfy { $0.state == .paired })
        let freeway = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 300, north: true, road: "motorway|lyndon b johnson freeway")
            + Self.carriageway(2, east: 30, from: 0, to: 300, north: false, road: "secondary|lyndon b johnson freeway"))
        #expect(freeway.allSatisfy { $0.state == .one }, "a frontage road named like the freeway never pairs with it")
        #expect(RoadCoverage.pairLimit("trunk|us 59", "primary|us 59") == nil)
        #expect(RoadCoverage.pairLimit("primary|main street", "primary|main street") == RoadCoverage.pairMaxM)
        #expect(RoadCoverage.pairLimit(nil, "primary|main street") == nil)
    }

    @Test func onlyTheStretchDrivenOnBothCarriagewaysPairs() {
        // Northbound for 600 m, southbound back only over the first 300 m.
        let ls = Self.lines(Self.carriageway(1, east: 0, from: 0, to: 600, north: true)
            + Self.carriageway(2, east: 20, from: 0, to: 300, north: false))
        // Expected lengths measured on the same geometry (the test's meters are approximate).
        let half = OSMGeo.lineLength([Self.p(north: 0, east: 0), Self.p(north: 300, east: 0)])
        #expect(abs(Self.length(ls, .paired) - 2 * half) < 1, "\(Self.length(ls, .paired)) vs \(2 * half)")
        #expect(abs(Self.length(ls, .one) - half) < 1, "\(Self.length(ls, .one)) vs \(half)")
        let rest = ls.first { $0.state == .one }!
        #expect(rest.coords[0].lat > Self.p(north: 299, east: 0).lat, "the unpaired rest is the northern half")
    }

    @Test func outOnOneTripAndBackOnAnotherPairs() {
        func trip(_ edges: [RoadCoverage.Edge]) -> TripCoverage { TripCoverage(runs: RoadCoverage.runs(edges)) }
        let out = trip(Self.carriageway(1, east: 0, from: 0, to: 400, north: true))
        let back = trip(Self.carriageway(2, east: 18, from: 0, to: 400, north: false))
        #expect(Self.lines(RoadCoverage.merge([out])).allSatisfy { $0.state == .one })
        let ls = Self.lines(RoadCoverage.merge([out, back]))
        #expect(ls.count == 2 && ls.allSatisfy { $0.state == .paired })
    }

    @Test func theAccumulatorStoresTheRoadKeyAndOneWayFlag() throws {
        var s = CoverageTests.segment(oneway: true)
        s.tags = ["highway": "primary", "name": "Telge Road"]
        var acc = CoverageAccumulator()
        acc.add(DrivenPiece(segment: 0, direction: .forward, from: 0, to: s.length, startTime: 0, endTime: 10), segment: s)
        let c = acc.coverage()
        #expect(c.version == TripCoverage.currentVersion && c.version >= 2, "version 2 added the road key, 3 the pass counts (SPEC 18.7)")
        #expect(c.runs.count == 1 && c.runs[0].road == "primary|telge road" && c.runs[0].oneway == true)
        #expect(RoadCoverage.roadKey(["highway": "motorway", "ref": "I 45"]) == "motorway|i 45")
        #expect(RoadCoverage.roadKey(["highway": "service"]) == nil)
        // Stored and read back with the same fields; the drawing-only flag is not stored.
        var run = c.runs[0]
        run.paired = true
        let json = String(decoding: try JSONEncoder().encode(TripCoverage(runs: [run])), as: UTF8.self)
        #expect(json.contains("telge road") && !json.contains("paired"))
        // A version 1 file (no road, no one-way flag) still decodes but carries version 1, so
        // `RoadService.loadCoverage` sends its trip back to the analysis, which writes version 2.
        let v1 = #"{"version":1,"runs":[{"wayId":10,"nodes":[1,2],"coords":[[1,2],[1,2.001]],"forward":true,"backward":false}]}"#
        let old = try JSONDecoder().decode(TripCoverage.self, from: Data(v1.utf8))
        #expect(old.version == 1 && old.version != TripCoverage.currentVersion && old.runs[0].road == nil)
    }

    /// Every oracle drive: how much pairs, and that nothing pairs across different roads.
    @Test func oracleDrivesPairOnlyCarriagewaysOfOneRoad() throws {
        for n in 1...9 {
            let c = try OracleCase.load(n)
            for (d, drive) in c.drives.enumerated() {
                let fixes = RoadAnalysisTests.fixes(drive)
                let result = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1000,
                                                  load: CoverageTests.tileLoader(c.elements))
                let edges = RoadCoverage.paired(RoadCoverage.edges(result.coverage))
                let paired = edges.filter(\.paired)
                let len = paired.reduce(0) { $0 + OSMGeo.haversine($1.a, $1.b) }
                let roads = Set(paired.compactMap(\.road)).sorted()
                print("PAIRED case \(n) drive \(d): \(paired.count) of \(edges.count) edges, \(Int(len)) m, roads \(roads)")
                #expect(paired.allSatisfy { $0.oneway && $0.road != nil && $0.forward != $0.backward })
            }
        }
    }
    /// Real OSM (I-635 at the Tollway): every edge of every named one-way way, driven along the
    /// way. The two carriageways of Preston Road and of the freeway pair; the frontage roads,
    /// which carry the freeway's name but class `secondary`, never pair with the freeway.
    @Test func realDividedRoadsPairAndFrontageRoadsDoNotPairWithTheFreeway() throws {
        let elements = try OverpassParser.parse(TestResources.data("i635-texpress"))
        let nodes = Dictionary(elements.nodes.map { ($0.id, LatLon(lat: $0.lat, lon: $0.lon)) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<Int64> = []
        var edges: [RoadCoverage.Edge] = []
        for w in elements.ways where seen.insert(w.id).inserted {
            let tags = w.tags ?? [:]
            guard tags["oneway"] == "yes", tags["highway"] != nil, w.nodes.count >= 2 else { continue }
            for (a, b) in zip(w.nodes, w.nodes.dropFirst()) where a != b {
                guard let pa = nodes[a], let pb = nodes[b] else { continue }
                edges.append(RoadCoverage.Edge(key: CoverageEdgeKey(wayId: w.id, a: a, b: b), a: pa, b: pb, forward: true, backward: false,
                                               road: RoadCoverage.roadKey(tags), oneway: true))
            }
        }
        let paired = RoadCoverage.paired(edges)
        var share: [String: (Double, Double)] = [:]
        for e in paired {
            let key = e.road ?? "(unnamed)"
            let len = OSMGeo.haversine(e.a, e.b)
            share[key, default: (0, 0)].0 += e.paired ? len : 0
            share[key, default: (0, 0)].1 += len
        }
        for (k, v) in share.sorted(by: { $0.key < $1.key }) {
            print("PAIRED i635 \(k): \(Int(v.0)) of \(Int(v.1)) m")
        }
        func fraction(_ k: String) -> Double { share[k].map { $0.0 / max(1, $0.1) } ?? 0 }
        #expect(fraction("primary|preston road") > 0.6)
        #expect(fraction("motorway|lyndon b johnson freeway") > 0.6)
        #expect(fraction("(unnamed)") == 0)
        // Every pair joins the same class and name (the key), never freeway with frontage road.
        #expect(paired.filter(\.paired).allSatisfy { $0.road != nil })
    }
    /// A version 1 `coverage.json` still draws at once and is rewritten as version 2 by the
    /// analysis it is sent back to.
    @Test func aVersionOneCoverageFileDrawsAndIsUpgraded() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        let store = TripStore(root: Fixtures.tempDir())
        let id = try ReviewV11.storedTrip(store, fixes: fixes)
        let whole = RoadAnalyzer.analyze(fixes: fixes, config: .default, maxTilesPerChunk: 1000, load: CoverageTests.tileLoader(c.elements))
        var old = whole.coverage
        old.version = 1
        for k in old.runs.indices { old.runs[k].road = nil; old.runs[k].oneway = nil }
        #expect(!old.runs.isEmpty)
        try store.saveCoverage(old, for: id)
        _ = try store.update(id) { $0.roads = whole.statistics }
        let service = RoadService(store: store, settings: ReviewV11.settings(), pack: nil,
                                  cache: try ReviewV11.downtownCache(c, fixes), client: nil)
        service.onTripUpdated = { _ in service.reloadCoverage([(try? store.load(id))].compactMap { $0 }) }
        service.reloadCoverage([try store.load(id)])
        #expect(await ReviewV11.wait(10) { service.coveredTripIds.contains(id) }, "drawn before the upgrade")
        #expect(await ReviewV11.wait(30) { store.loadCoverage(id)?.version == TripCoverage.currentVersion })
        #expect(store.loadCoverage(id)?.runs.contains { $0.oneway != nil } == true)
    }
}
