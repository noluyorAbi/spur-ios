import Foundation
import Testing
@testable import Spur

/// SPEC 18.8: the likely route across a GPS gap.
struct GapFillerTests {
    typealias P = DiscoveryPlanner
    typealias G = GapFiller

    @Test func shortOrRoadlessGapsGetNoSuggestionWithTheReason() {
        let segs = DiscoveryPlannerTests.grid(4)
        let g = P.graph(segments: segs, features: [], chips: [], onlyMissing: false) { _, _ in false }
        let a = G.End(position: LatLon(lat: 32.78, lon: -96.80), course: 90)
        #expect(G.suggest(from: a, to: G.End(position: LatLon(lat: 32.78, lon: -96.7997)), elapsed: 3, graph: g) == .failure(.tooShort))
        let far = G.End(position: LatLon(lat: 33.5, lon: -97.5))
        #expect(G.suggest(from: far, to: G.End(position: LatLon(lat: 33.51, lon: -97.5)), elapsed: 60, graph: g) == .failure(.noRoadData))
        // Three blocks in 5 s is not a car on these streets.
        let b = G.End(position: LatLon(lat: 32.78, lon: -96.80 + 3 * 0.00107), course: 90)
        #expect(G.suggest(from: a, to: b, elapsed: 5, graph: g) == .failure(.implausible))
    }

    @Test func aPlausibleGapFollowsTheRoadsLegally() throws {
        let segs = DiscoveryPlannerTests.grid(4, oneway: true)
        let g = P.graph(segments: segs, features: [], chips: [], onlyMissing: false) { _, _ in false }
        let a = G.End(position: LatLon(lat: 32.78 + 0.0009, lon: -96.80 + 0.2 * 0.00107), course: 90)
        let b = G.End(position: LatLon(lat: 32.78 + 0.0009, lon: -96.80 + 2.6 * 0.00107), course: 90)
        let s = try G.suggest(from: a, to: b, elapsed: 30, graph: g).get()
        #expect(abs(s.lengthM - 2.4 * 100) < 15, "along the street: \(s.lengthM)")
        for (x, y) in zip(s.arcs, s.arcs.dropFirst()) { #expect(g.arcs[x].to == g.arcs[y].from && g.allows(x, y)) }
        #expect(s.arcs.allSatisfy { g.segments[g.arcs[$0].segment].allows(g.arcs[$0].direction) })
        // The same inputs, the same suggestion.
        #expect(try G.suggest(from: a, to: b, elapsed: 30, graph: g).get() == s)
    }

    /// Ground truth on the Dallas pack: fastest drives between fixed nodes, cut into gaps of
    /// 30 s, 2 min and 5 min; the suggestion must cover at least 90 % of the truly driven length
    /// in at least 90 % of the cuts.
    @Test(.enabled(if: RoadPack.bundled() != nil, "needs the offline road pack (scripts/build-osm-pack.sh)"))
    func groundTruthOnTheDallasPack() async throws {
        let center = LatLon(lat: 32.7900, lon: -96.8000)
        let keys = TileKey.within(radius: 6000, ofLat: center.lat, lon: center.lon)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spur-gap-\(UUID().uuidString)")
        let provider = RoadTileProvider(cache: RoadTileCache(directory: dir), pack: RoadPack.bundled(), client: nil, liveEnabled: false)
        let net = RoadNetwork(await provider.lookup(keys).elements)
        try #require(net.segments.count > 1000)
        let g = P.graph(segments: net.segments, features: [], chips: [], onlyMissing: false) { _, _ in false }
        // Time per metre as the routing weight: drivers take the fastest way.
        var timeWeight: [Int: Double] = [:]
        for i in g.arcs.indices { timeWeight[i] = P.seconds(g, [i]) / max(g.arcs[i].length, 1) * 15 }
        // Fixed, spread pairs of arcs as trip starts and ends.
        let n = g.arcs.count
        var drives: [[Int]] = []
        var k = 0
        while drives.count < 8 && k < 200 {
            let a = (k * 7919) % n, b = (k * 104_729 + n / 2) % n
            k += 1
            let s = G.Snap(arc: a, offset: 0, distance: 0), e = G.Snap(arc: b, offset: g.arcs[b].length, distance: 0)
            guard let p = G.path(g, from: s, to: e, penalty: timeWeight), p.length > 4000 else { continue }
            drives.append(p.arcs)
        }
        try #require(drives.count >= 7)
        var cuts = 0, good = 0
        var misses: [String] = []
        for (d, arcs) in drives.enumerated() {
            // 1 Hz positions at 85 % of the free-flow speed, with the arc each lies on.
            var fixes: [(LatLon, Double, Int, Double)] = []   // position, course, arc, time
            var t = 0.0
            for arc in arcs {
                let seg = g.segments[g.arcs[arc].segment]
                let pts = g.arcs[arc].direction == .forward ? seg.coords : seg.coords.reversed()
                let v = g.arcs[arc].length / P.seconds(g, [arc]) * 0.85
                var x = 0.0
                while x < g.arcs[arc].length {
                    let p = OSMGeo.point(along: pts, offset: x)
                    let q = OSMGeo.point(along: pts, offset: min(g.arcs[arc].length, x + 5))
                    fixes.append((p, OSMGeo.bearing(p, q), arc, t))
                    x += v
                    t += 1
                }
            }
            for window in [30.0, 120.0, 300.0] {
                for startFrac in [0.15, 0.45] {
                    let i = Int(Double(fixes.count) * startFrac), j = i + Int(window)
                    guard j < fixes.count else { continue }
                    let a = fixes[i], b = fixes[j]
                    // The truly driven arcs between the two ends.
                    var truth: [Int] = []
                    for f in fixes[i...j] where truth.last != f.2 { truth.append(f.2) }
                    let trueLength = truth.dropFirst().dropLast().reduce(0) { $0 + g.arcs[$1].length }
                    guard trueLength > 0 else { continue }
                    cuts += 1
                    let result = G.suggest(from: G.End(position: a.0, course: a.1), to: G.End(position: b.0, course: b.1), elapsed: window, graph: g)
                    guard case .success(let s) = result else {
                        misses.append("drive \(d) \(Int(window)) s at \(startFrac): \(result)")
                        continue
                    }
                    for (x, y) in zip(s.arcs, s.arcs.dropFirst()) { #expect(g.allows(x, y) && g.arcs[x].to == g.arcs[y].from, "legal") }
                    let set = Set(s.arcs)
                    let matched = truth.dropFirst().dropLast().filter { set.contains($0) }.reduce(0) { $0 + g.arcs[$1].length }
                    let share = matched / trueLength
                    if share >= 0.9 { good += 1 } else { misses.append("drive \(d) \(Int(window)) s at \(startFrac): \(Int(share * 100)) % of \(Int(trueLength)) m, suggested \(Int(s.lengthM)) m") }
                }
            }
        }
        print("GAP ground truth: \(good) of \(cuts) cuts at 90 % or more of the driven length")
        for m in misses { print("GAP miss: \(m)") }
        #expect(cuts >= 20)
        #expect(Double(good) >= 0.9 * Double(cuts))
    }
}
