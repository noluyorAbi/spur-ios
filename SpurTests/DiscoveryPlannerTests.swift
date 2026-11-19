import Foundation
import Testing
@testable import Spur

/// SPEC 18.5: the discovery route planner.
struct DiscoveryPlannerTests {
    typealias P = DiscoveryPlanner

    /// A grid of `n` x `n` nodes about 100 m apart; node id i * 100 + j. `oneway` makes the
    /// horizontal street of row 1 eastbound only; `privateRow` makes row 2's street private.
    static func grid(_ n: Int, oneway: Bool = false, privateRow: Bool = false, deadEnd: Bool = false) -> [RoadSegment] {
        func node(_ i: Int, _ j: Int) -> Int64 { Int64(i * 100 + j) }
        func pos(_ i: Int, _ j: Int) -> LatLon { LatLon(lat: 32.78 + Double(i) * 0.0009, lon: -96.80 + Double(j) * 0.00107) }
        var out: [RoadSegment] = []
        func seg(_ a: (Int, Int), _ b: (Int, Int), way: Int64, tags: [String: String], dirs: [TravelDirection]) {
            let ca = pos(a.0, a.1), cb = pos(b.0, b.1), len = OSMGeo.haversine(ca, cb)
            let na = node(a.0, a.1), nb = node(b.0, b.1)
            out.append(RoadSegment(id: "\(way):\(na):\(nb)", wayId: way, fromNode: na, toNode: nb, nodeIds: [na, nb], coords: [ca, cb],
                                   cum: [0, len], length: len, tags: tags, categories: [.local], directions: dirs))
        }
        for i in 0..<n {
            for j in 0..<(n - 1) {
                var tags = ["highway": "residential"]
                if privateRow && i == 2 { tags["access"] = "private" }
                seg((i, j), (i, j + 1), way: Int64(1000 + i), tags: tags, dirs: oneway && i == 1 ? [.forward] : [.forward, .backward])
            }
        }
        for j in 0..<n {
            for i in 0..<(n - 1) {
                seg((i, j), (i + 1, j), way: Int64(2000 + j), tags: ["highway": "residential"], dirs: [.forward, .backward])
            }
        }
        if deadEnd { seg((0, n - 1), (0, n), way: 3000, tags: ["highway": "residential"], dirs: [.forward, .backward]) }
        return out
    }

    static func signals(_ nodes: [Int64], _ n: Int) -> [FeatureNode] {
        nodes.map { id in
            let i = Int(id / 100), j = Int(id % 100)
            return FeatureNode(nodeId: id, lat: 32.78 + Double(i) * 0.0009, lon: -96.80 + Double(j) * 0.00107, type: .stop)
        }
    }

    static func legal(_ g: P.Graph, _ r: P.Route) -> Bool {
        for (a, b) in zip(r.arcs, r.arcs.dropFirst()) {
            guard g.arcs[a].to == g.arcs[b].from, g.allows(a, b) else { return false }
        }
        return r.arcs.allSatisfy { !P.excluded(g.segments[g.arcs[$0].segment]) && g.segments[g.arcs[$0].segment].allows(g.arcs[$0].direction) }
    }

    @Test func aLoopIsLegalWithinBudgetAndDeterministic() {
        let segs = Self.grid(5, oneway: true, privateRow: true, deadEnd: true)
        let g = P.graph(segments: segs, features: Self.signals([101, 203, 304], 5), chips: [.stopSigns], onlyMissing: false) { _, _ in false }
        #expect(!g.arcs.contains { P.excluded(g.segments[$0.segment]) }, "private ways are not in the graph")
        let q = P.Query(start: LatLon(lat: 32.78, lon: -96.80), budgetM: 2500, features: [.stopSigns])
        let routes = P.plan(q, graph: g)
        #expect(!routes.isEmpty)
        for r in routes {
            #expect(Self.legal(g, r), "every turn legal, no U-turn except at the dead end")
            #expect(r.lengthM >= 0.95 * 2500 && r.lengthM <= 1.05 * 2500, "length \(r.lengthM)")
            #expect(g.arcs[r.arcs.first!].from == g.arcs[r.arcs.last!].to, "back at the start")
        }
        #expect(P.plan(q, graph: g).map(\.arcs) == routes.map(\.arcs), "same inputs, same routes")
    }

    @Test func driveToAGoalWithinTheDetour() {
        let segs = Self.grid(5)
        let g = P.graph(segments: segs, features: [], chips: [], onlyMissing: false) { _, _ in false }
        let goal = LatLon(lat: 32.78 + 4 * 0.0009, lon: -96.80 + 4 * 0.00107)
        let q = P.Query(start: LatLon(lat: 32.78, lon: -96.80), mode: .toGoal(goal), budgetM: 600)
        let r = P.plan(q, graph: g).first
        #expect(r != nil)
        if let r {
            #expect(Self.legal(g, r))
            #expect(g.arcs[r.arcs.last!].to == 404)
            let shortest = 8 * OSMGeo.haversine(LatLon(lat: 32.78, lon: -96.80), LatLon(lat: 32.78 + 0.0009, lon: -96.80)) // about 8 blocks
            #expect(r.lengthM <= shortest * 1.2 + 600, "within the detour budget: \(r.lengthM)")
            #expect(r.newM > 0)
        }
    }

    /// Brute force: every legal closed walk from the start within the window, the best score.
    static func optimum(_ g: P.Graph, _ q: P.Query, start: Int64) -> Double {
        let back = P.backward(g, to: start)
        let minM = 0.95 * q.budgetM, maxM = 1.05 * q.budgetM
        var best = 0.0
        var path: [Int] = []
        func dfs(_ length: Double) {
            if let last = path.last, g.arcs[last].to == start, length >= minM, length <= maxM {
                best = max(best, P.value(g, q, arcs: path).score)
            }
            let options = path.last.map { last in (g.outgoing[g.arcs[last].to] ?? []).filter { g.allows(last, $0) } } ?? (g.outgoing[start] ?? [])
            for b in options {
                let nl = length + g.arcs[b].length
                guard nl + back.dist[b] <= maxM + 1e-9 else { continue }
                path.append(b)
                dfs(nl)
                path.removeLast()
            }
        }
        dfs(0)
        return best
    }

    @Test(arguments: [(1200.0, false), (1400.0, true), (1600.0, true), (1600.0, false), (1800.0, false)])
    func atLeastNinetyPercentOfTheOptimum(_ c: (Double, Bool)) {
        let segs = Self.grid(3, oneway: c.1)
        // Part of the grid already driven, two stop signs.
        let driven: (RoadSegment, TravelDirection) -> Bool = { s, _ in s.wayId == 2000 }
        let g = P.graph(segments: segs, features: Self.signals([1, 101], 3), chips: [.stopSigns], onlyMissing: false, driven: driven)
        let q = P.Query(start: LatLon(lat: 32.78, lon: -96.80), budgetM: c.0, features: [.stopSigns])
        let best = Self.optimum(g, q, start: 0)
        let got = P.plan(q, graph: g).first?.score ?? 0
        print("PLAN brute force budget \(Int(c.0)) m oneway \(c.1): heuristic \(Int(got)), optimum \(Int(best)), \(best > 0 ? Int(100 * got / best) : 100) %")
        #expect(best > 0, "a closed walk fits the window")
        #expect(got >= 0.9 * best, "heuristic \(got) of optimum \(best)")
        if let r = P.plan(q, graph: g).first {
            #expect(r.lengthM >= 0.95 * c.0 && r.lengthM <= 1.05 * c.0, "within the window when one exists: \(r.lengthM)")
        }
    }
}

/// SPEC 18.5 on the Dallas pack: legality, the budget, against the parent's baseline, and timing.
struct DiscoveryPlannerDallasTests {
    typealias P = DiscoveryPlanner

    @Test(.enabled(if: RoadPack.bundled() != nil, "needs the offline road pack (scripts/build-osm-pack.sh)"))
    func aFiftyKilometreLoopOnTheDallasPack() async throws {
        let center = LatLon(lat: 32.7767, lon: -96.7970)
        let keys = TileKey.within(radius: 15_000, ofLat: center.lat, lon: center.lon)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spur-plan-\(UUID().uuidString)")
        let provider = RoadTileProvider(cache: RoadTileCache(directory: dir), pack: RoadPack.bundled(), client: nil, liveEnabled: false)
        let clock = ContinuousClock()
        let t0 = clock.now
        let lookup = await provider.lookup(keys)
        let net = RoadNetwork(lookup.elements)
        let tBuild = clock.now - t0
        try #require(net.segments.count > 1000, "the pack covers downtown Dallas")
        let chips: Set<ScenarioFinder.Feature> = [.signals, .skewed, .stopSigns]
        let features = Array(net.features.values)
        let t1 = clock.now
        let g = P.graph(segments: net.segments, features: features, chips: chips, onlyMissing: false) { _, _ in false }
        let tGraph = clock.now - t1
        let q = P.Query(start: center, budgetM: 50_000, features: chips, alternatives: 3)
        let t2 = clock.now
        let routes = P.plan(q, graph: g)
        let tPlan = clock.now - t2
        let best = try #require(routes.first)
        // Baseline: the scenario finder's top clusters as targets.
        let found = ScenarioFinder.find(ScenarioFinder.Query(origin: center, radiusM: 15_000, features: chips),
                                        segments: net.segments, features: features) { _, _ in false }
        let base = try #require(P.baseline(q, graph: g, targets: found.map(\.center)))
        print("PLAN Dallas 50 km in 15 km: tiles \(keys.count), segments \(net.segments.count), arcs \(g.arcs.count); build \(tBuild), graph \(tGraph), plan \(tPlan) for \(routes.count) routes")
        print("PLAN Dallas planner: \(Int(best.lengthM)) m, new \(Int(best.newM)) m, features \(best.counts.values.reduce(0, +)), score \(Int(best.score)); baseline: \(Int(base.lengthM)) m, new \(Int(base.newM)) m, features \(base.counts.values.reduce(0, +)), score \(Int(base.score))")
        for r in routes {
            #expect(DiscoveryPlannerTests.legal(g, r), "every turn legal on the pack")
            #expect(r.lengthM >= 0.95 * 50_000 && r.lengthM <= 1.05 * 50_000, "length \(r.lengthM)")
        }
        #expect(best.newM >= base.newM, "more new metres than the baseline")
        #expect(best.counts.values.reduce(0, +) >= base.counts.values.reduce(0, +), "at least the baseline's features")
    }
}
