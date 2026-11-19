import Foundation

/// "Entdeckerroute" (SPEC 18.5): a route on the road graph that collects as many new metres in the
/// wanted direction and as many wanted features as fit into a budget. Pure: no UI, MapKit or
/// network; deterministic (every choice runs over arrays in id order, ties by index).
///
/// The graph is one arc per legal direction of a segment (oneway respected; `access=private/no`
/// left out; service roads only as `RoadRules` keeps them). A turn from arc a to arc b is allowed
/// unless b is a's reverse, which is allowed only where nothing else leaves the node (a dead end).
/// Turn restriction relations are not in the tiles, so they are not checked (the card says so).
nonisolated enum DiscoveryPlanner {
    enum Mode: Sendable, Equatable {
        /// Back to the start; the length within ±5 % of the budget.
        case loop
        /// To a goal; at most the shortest way plus the detour budget.
        case toGoal(LatLon)
    }

    struct Query: Sendable {
        var start: LatLon
        var mode: Mode = .loop
        /// Length budget in metres (Rundkurs), or the detour budget (Zum Ziel).
        var budgetM: Double
        var features: Set<ScenarioFinder.Feature> = []
        var onlyMissing = false
        /// One feature site is worth this many new metres.
        var siteValueM = 150.0
        var alternatives = 3
    }

    struct Arc: Sendable, Equatable {
        var segment: Int
        var direction: TravelDirection
        var from: Int64
        var to: Int64
        var length: Double
        /// New metres this arc adds when driven (0 when driven already).
        var newM: Double
        /// Feature sites on its nodes (after the start node), for the chips.
        var sites: [String]
        var reverse: Int?
    }

    struct Route: Sendable, Equatable {
        /// Arc indexes in driving order.
        var arcs: [Int]
        var coords: [LatLon]
        var lengthM: Double
        var newM: Double
        var counts: [ScenarioFinder.Feature: Int]
        var seconds: Double
        /// Up to 9 points in order, for the hand-off (the parent's limit).
        var waypoints: [LatLon]
        var score: Double
        /// The length misses the window (a graph without a closed walk of that length): the card
        /// shows the real length.
        var outsideBudget = false
    }

    /// The arc graph of the segments.
    struct Graph: Sendable {
        var segments: [RoadSegment]
        var arcs: [Arc]
        var outgoing: [Int64: [Int]]
        var incoming: [Int64: [Int]]
        var siteFeature: [String: ScenarioFinder.Feature]

        func allows(_ a: Int, _ b: Int) -> Bool {
            guard arcs[a].reverse == b else { return true }
            // A U-turn only where nothing else leaves the node.
            return (outgoing[arcs[a].to] ?? []).allSatisfy { $0 == b }
        }
    }

    static func excluded(_ s: RoadSegment) -> Bool {
        ["private", "no"].contains(s.tags["access"] ?? "")
    }

    static func graph(segments raw: [RoadSegment], features: [FeatureNode], chips: Set<ScenarioFinder.Feature>,
                      onlyMissing: Bool, driven: (RoadSegment, TravelDirection) -> Bool) -> Graph {
        let segments = raw.filter { !excluded($0) && $0.length > 0 && $0.coords.count >= 2 }.sorted { $0.id < $1.id }
        // Feature sites by node, from the scenario rules (signals, stop signs, crossings, ...).
        let hits = ScenarioFinder.analyze(segments, features: features, requested: chips)
        var siteFeature: [String: ScenarioFinder.Feature] = [:]
        var sitesBySegment: [String: [String]] = [:]
        for (id, h) in hits {
            for (f, sites) in h.sites {
                for site in sites.sorted() {
                    siteFeature[site] = f
                    sitesBySegment[id, default: []].append(site)
                }
            }
        }
        var arcs: [Arc] = []
        var bySegDir: [String: Int] = [:]
        for (k, s) in segments.enumerated() {
            for d in [TravelDirection.forward, .backward] where s.allows(d) {
                let newHere = onlyMissing ? !driven(s, d) : !(driven(s, .forward) || driven(s, .backward))
                bySegDir["\(k)|\(d.rawValue)"] = arcs.count
                arcs.append(Arc(segment: k, direction: d, from: s.entryNode(d), to: s.exitNode(d), length: s.length,
                                newM: newHere ? s.length : 0, sites: (sitesBySegment[s.id] ?? []).sorted(), reverse: nil))
            }
        }
        var outgoing: [Int64: [Int]] = [:], incoming: [Int64: [Int]] = [:]
        for (i, a) in arcs.enumerated() {
            arcs[i].reverse = bySegDir["\(a.segment)|\(a.direction.reversed.rawValue)"]
            outgoing[a.from, default: []].append(i)
            incoming[a.to, default: []].append(i)
        }
        return Graph(segments: segments, arcs: arcs, outgoing: outgoing, incoming: incoming, siteFeature: siteFeature)
    }

    // MARK: Shortest paths on arcs

    /// Cost from the start node to the end of every arc (the arc included), and the predecessor.
    static func forward(_ g: Graph, from node: Int64, limit: Double = .infinity) -> (dist: [Double], prev: [Int]) {
        var dist = [Double](repeating: .infinity, count: g.arcs.count)
        var prev = [Int](repeating: -1, count: g.arcs.count)
        var heap = Heap()
        for a in g.outgoing[node] ?? [] {
            dist[a] = g.arcs[a].length
            heap.push(dist[a], a)
        }
        relax(g, &dist, &prev, &heap, limit: limit)
        return (dist, prev)
    }

    /// Cost from the end of `start` onwards (not counting `start` itself).
    static func forward(_ g: Graph, fromArc start: Int, limit: Double) -> (dist: [Double], prev: [Int]) {
        var dist = [Double](repeating: .infinity, count: g.arcs.count)
        var prev = [Int](repeating: -1, count: g.arcs.count)
        var heap = Heap()
        for b in g.outgoing[g.arcs[start].to] ?? [] where g.allows(start, b) {
            if g.arcs[b].length < dist[b] {
                dist[b] = g.arcs[b].length
                prev[b] = -2 - start
                heap.push(dist[b], b)
            }
        }
        relax(g, &dist, &prev, &heap, limit: limit)
        return (dist, prev)
    }

    private static func relax(_ g: Graph, _ dist: inout [Double], _ prev: inout [Int], _ heap: inout Heap, limit: Double) {
        while let (d, a) = heap.pop() {
            guard d <= dist[a], d <= limit else { continue }
            for b in g.outgoing[g.arcs[a].to] ?? [] where g.allows(a, b) {
                let nd = d + g.arcs[b].length
                if nd < dist[b] - 1e-9 || (abs(nd - dist[b]) <= 1e-9 && prev[b] >= 0 && a < prev[b]) {
                    dist[b] = nd
                    prev[b] = a
                    heap.push(nd, b)
                }
            }
        }
    }

    /// Cost from the end of every arc to `goal` (the arc itself not counted), and the next arc.
    static func backward(_ g: Graph, to goal: Int64) -> (dist: [Double], next: [Int]) {
        var dist = [Double](repeating: .infinity, count: g.arcs.count)
        var next = [Int](repeating: -1, count: g.arcs.count)
        var heap = Heap()
        for a in g.incoming[goal] ?? [] {
            dist[a] = 0
            heap.push(0, a)
        }
        while let (d, b) = heap.pop() {
            guard d <= dist[b] else { continue }
            // Arcs a that may turn into b.
            for a in g.incoming[g.arcs[b].from] ?? [] where g.allows(a, b) {
                let nd = d + g.arcs[b].length
                if nd < dist[a] - 1e-9 || (abs(nd - dist[a]) <= 1e-9 && next[a] >= 0 && b < next[a]) {
                    dist[a] = nd
                    next[a] = b
                    heap.push(nd, a)
                }
            }
        }
        return (dist, next)
    }

    // MARK: Planning

    static func snap(_ p: LatLon, _ g: Graph) -> Int64? {
        // Over the arcs in index order (no sort of the nodes); ties by node id.
        var best: (Int64, Double)?
        for a in g.arcs {
            let s = g.segments[a.segment]
            let c = a.direction == .forward ? s.coords[0] : s.coords[s.coords.count - 1]
            let d = OSMGeo.haversine(p, c)
            if d < (best?.1 ?? .infinity) - 1e-9 || (abs(d - (best?.1 ?? .infinity)) <= 1e-9 && a.from < best!.0) { best = (a.from, d) }
        }
        return best?.0
    }

    /// The best route and up to `alternatives - 1` others, best first.
    static func plan(_ q: Query, graph g: Graph) -> [Route] {
        guard let start = snap(q.start, g) else { return [] }
        let goal: Int64
        let minM: Double, maxM: Double
        let toStart = forward(g, from: start)
        switch q.mode {
        case .loop:
            goal = start
            minM = 0.95 * q.budgetM
            maxM = 1.05 * q.budgetM
        case .toGoal(let p):
            guard let gnode = snap(p, g) else { return [] }
            goal = gnode
            let back = backward(g, to: goal)
            let shortest = (g.outgoing[start] ?? []).map { g.arcs[$0].length + back.dist[$0] }.min() ?? .infinity
            guard shortest.isFinite else { return [] }
            minM = 0
            maxM = shortest + q.budgetM
        }
        let back = backward(g, to: goal)
        // First targets: the best prize per cost, each from a different sector, for diversity.
        let firsts = firstTargets(g, q, toStart.dist, back.dist, maxM: maxM, count: q.alternatives)
        var routes: [Route] = []
        var seen: Set<[Int]> = []
        for first in firsts {
            guard let r = build(g, q, start: start, first: first, back: back, minM: minM, maxM: maxM), !seen.contains(r.arcs) else { continue }
            seen.insert(r.arcs)
            routes.append(r)
        }
        if routes.isEmpty, let r = build(g, q, start: start, first: nil, back: back, minM: minM, maxM: maxM) { routes.append(r) }
        return routes.sorted { $0.score != $1.score ? $0.score > $1.score : $0.arcs.lexicographicallyPrecedes($1.arcs) }
    }

    static func value(_ g: Graph, _ q: Query, arcs: [Int]) -> (newM: Double, counts: [ScenarioFinder.Feature: Int], score: Double) {
        var seenSeg = Set<Int>(), seenArc = Set<Int>(), sites = Set<String>()
        var newM = 0.0
        for a in arcs {
            let arc = g.arcs[a]
            // New metres once per arc; with "egal" once per segment.
            if arc.newM > 0, q.onlyMissing ? seenArc.insert(a).inserted : seenSeg.insert(arc.segment).inserted { newM += arc.newM }
            for s in arc.sites { sites.insert(s) }
        }
        var counts: [ScenarioFinder.Feature: Int] = [:]
        for s in sites.sorted() { if let f = g.siteFeature[s] { counts[f, default: 0] += 1 } }
        return (newM, counts, newM + q.siteValueM * Double(sites.count))
    }

    private static func firstTargets(_ g: Graph, _ q: Query, _ dist: [Double], _ back: [Double], maxM: Double, count: Int) -> [Int?] {
        var scored: [(Int, Double, Int)] = []
        for (i, a) in g.arcs.enumerated() where dist[i].isFinite && dist[i] + back[i] <= maxM {
            let prize = a.newM + q.siteValueM * Double(a.sites.count)
            guard prize > 0 else { continue }
            let s = g.segments[a.segment]
            let sector = Int(OSMGeo.bearing(q.start, s.coords[s.coords.count / 2]) / 120) % 3
            scored.append((i, prize / max(dist[i], 1), sector))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var out: [Int?] = []
        var used = Set<Int>()
        for (i, _, sector) in scored where !used.contains(sector) {
            out.append(i)
            used.insert(sector)
            if out.count == count { break }
        }
        return out.isEmpty ? [nil] : out
    }

    /// Greedy: from the current arc, the reachable arc with the best prize along its path per
    /// cost that still lets the route get home within `maxM`; then home, with a fill phase so a
    /// Rundkurs reaches `minM`.
    private static func build(_ g: Graph, _ q: Query, start: Int64, first: Int?, back: (dist: [Double], next: [Int]),
                              minM: Double, maxM: Double) -> Route? {
        var path: [Int] = []
        var length = 0.0
        var takenArc = Set<Int>(), takenSeg = Set<Int>(), takenSite = Set<String>()
        func take(_ a: Int) {
            path.append(a)
            length += g.arcs[a].length
            takenArc.insert(a)
            takenSeg.insert(g.arcs[a].segment)
            for s in g.arcs[a].sites { takenSite.insert(s) }
        }
        func gain(_ a: Int) -> Double {
            let arc = g.arcs[a]
            var v = 0.0
            if arc.newM > 0, !(q.onlyMissing ? takenArc.contains(a) : takenSeg.contains(arc.segment)) { v += arc.newM }
            for s in arc.sites where !takenSite.contains(s) { v += q.siteValueM }
            return v
        }
        func pathTo(_ t: Int, _ prev: [Int]) -> [Int] {
            var out = [t]
            var cur = t
            while prev[cur] >= 0 { cur = prev[cur]; out.append(cur) }
            return out.reversed()
        }
        // The first leg from the start node.
        let s0 = forward(g, from: start, limit: maxM)
        if let t = first, s0.dist[t].isFinite {
            for a in pathTo(t, s0.prev) { take(a) }
        } else {
            guard let a = (g.outgoing[start] ?? []).min(by: { back.dist[$0] + g.arcs[$0].length < back.dist[$1] + g.arcs[$1].length }) else { return nil }
            take(a)
        }
        let search = Search(g.arcs.count)
        // Greedy legs; the end of each is a checkpoint the fill may start from.
        var checkpoints: [Int] = [path.count]
        for _ in 0..<400 {
            guard let cur = path.last else { break }
            let remaining = maxM - length
            guard remaining > 0 else { break }
            // A bounded search around the current arc (the prize per metre favours near targets);
            // the whole remaining budget only when nothing is in reach.
            var best: (Int, Double)?
            for limit in [min(remaining, Self.localSearchM), remaining] {
                bounded(g, fromArc: cur, limit: limit, into: search)
                // The prize of the whole leg, not only its target: in pop order along the search
                // tree, value(t) = value(prev(t)) + gain(t) (a site met twice on one leg is rare and
                // only biases the choice; the route's score is computed exactly afterwards).
                for t in search.order {
                    let p = search.prev[t]
                    search.value[t] = (p >= 0 ? search.value[p] : 0) + gain(t)
                    guard search.dist[t] + back.dist[t] <= remaining, gain(t) > 0 else { continue }
                    let ratio = search.value[t] / max(search.dist[t], 1)
                    if ratio > (best?.1 ?? 0) + 1e-12 { best = (t, ratio) }
                }
                if best != nil || limit >= remaining { break }
            }
            guard let (t, _) = best else { break }
            for a in pathFrom(cur, t, search.prev) { take(a) }
            checkpoints.append(path.count)
        }
        // Fill and home from the last checkpoint; when that misses the window, from earlier ones.
        var candidates: [[Int]] = []
        for cut in checkpoints.reversed() {
            let done = fillAndHome(g, Array(path.prefix(cut)), back: back, minM: minM, maxM: maxM, search: search)
            if let done { candidates.append(done) }
            if let done, pathLength(of: done, g) >= minM - 1e-6 { break }
        }
        guard let chosen = candidates.max(by: { a, b in
            let ina = pathLength(of: a, g) >= minM - 1e-6, inb = pathLength(of: b, g) >= minM - 1e-6
            if ina != inb { return !ina }
            return value(g, q, arcs: a).score < value(g, q, arcs: b).score
        }) else { return nil }
        let v = value(g, q, arcs: chosen)
        let total = pathLength(of: chosen, g)
        return Route(arcs: chosen, coords: coords(g, chosen), lengthM: total, newM: v.newM, counts: v.counts,
                     seconds: seconds(g, chosen), waypoints: waypoints(g, chosen), score: v.score,
                     outsideBudget: total < minM - 1e-6 || total > maxM + 1e-6)
    }

    /// The parent's method as the baseline (SPEC 18.5 acceptance): the scenario finder's top
    /// clusters, visited in nearest-neighbour order improved by 2-opt (great-circle, as the
    /// parent), joined by the same arc shortest paths, as many as fit into the budget with the
    /// way home. Scored like the planner.
    static func baseline(_ q: Query, graph g: Graph, targets: [LatLon]) -> Route? {
        guard let start = snap(q.start, g) else { return nil }
        let order = twoOpt(q.start, nearestNeighbour(q.start, targets))
        let back = backward(g, to: start)
        let maxM = 1.05 * q.budgetM
        var path: [Int] = []
        var length = 0.0
        var at: Int? = nil
        for p in order {
            guard let node = snap(p, g) else { continue }
            let f = at.map { forward(g, fromArc: $0, limit: maxM - length) } ?? forward(g, from: start, limit: maxM - length)
            // The cheapest arc into the target node that still lets the route get home.
            guard let t = (g.incoming[node] ?? []).filter({ f.dist[$0].isFinite && length + f.dist[$0] + back.dist[$0] <= maxM })
                .min(by: { f.dist[$0] != f.dist[$1] ? f.dist[$0] < f.dist[$1] : $0 < $1 }) else { continue }
            let leg = at.map { pathFrom($0, t, f.prev) } ?? {
                var out = [t]
                var x = t
                while f.prev[x] >= 0 { x = f.prev[x]; out.append(x) }
                return out.reversed()
            }()
            for a in leg { path.append(a); length += g.arcs[a].length }
            at = t
        }
        guard let home = fillAndHome(g, path.isEmpty ? [] : path, back: back, minM: 0, maxM: maxM), !home.isEmpty else { return nil }
        let v = value(g, q, arcs: home)
        let total = pathLength(of: home, g)
        return Route(arcs: home, coords: coords(g, home), lengthM: total, newM: v.newM, counts: v.counts,
                     seconds: seconds(g, home), waypoints: waypoints(g, home), score: v.score,
                     outsideBudget: total > maxM + 1e-6)
    }

    static func nearestNeighbour(_ o: LatLon, _ pts: [LatLon]) -> [LatLon] {
        var left = pts, out: [LatLon] = [], cur = o
        while !left.isEmpty {
            let k = left.indices.min { OSMGeo.haversine(cur, left[$0]) < OSMGeo.haversine(cur, left[$1]) }!
            cur = left.remove(at: k)
            out.append(cur)
        }
        return out
    }

    static func twoOpt(_ o: LatLon, _ pts: [LatLon]) -> [LatLon] {
        var t = [o] + pts
        func d(_ a: Int, _ b: Int) -> Double { OSMGeo.haversine(t[a], t[b]) }
        var improved = true, passes = 0
        while improved, passes < 1000 {
            improved = false
            passes += 1
            for i in 1..<max(1, t.count - 1) {
                for j in (i + 1)..<t.count {
                    let before = d(i - 1, i) + (j + 1 < t.count ? d(j, j + 1) : 0)
                    let after = d(i - 1, j) + (j + 1 < t.count ? d(i, j + 1) : 0)
                    if after < before - 1e-7 { t[i...j].reverse(); improved = true }
                }
            }
        }
        return Array(t.dropFirst())
    }

    static func pathLength(of arcs: [Int], _ g: Graph) -> Double { arcs.reduce(0) { $0 + g.arcs[$1].length } }

    /// Detours toward the window's middle (repeated: one-way streets can make one miss it), then
    /// the shortest way home.
    private static func fillAndHome(_ g: Graph, _ prefix: [Int], back: (dist: [Double], next: [Int]), minM: Double, maxM: Double,
                                    search: Search? = nil) -> [Int]? {
        let s = search ?? Search(g.arcs.count)
        var path = prefix
        var length = pathLength(of: path, g)
        for _ in 0..<20 {
            guard let cur = path.last, length + back.dist[cur] < minM else { break }
            let remaining = maxM - length
            bounded(g, fromArc: cur, limit: remaining, into: s)
            let want = (minM + maxM) / 2 - length
            var best: (Int, Double)?
            for t in s.order where s.dist[t] + back.dist[t] <= remaining {
                // Prefer a detour that ends in the window; else the longest step toward it.
                let total = s.dist[t] + back.dist[t]
                let miss = total >= minM - length ? abs(total - want) : 1e6 + (want - total)
                if miss < (best?.1 ?? .infinity) - 1e-9 || (abs(miss - (best?.1 ?? .infinity)) <= 1e-9 && t < best!.0) { best = (t, miss) }
            }
            guard let (t, _) = best else { break }
            for a in pathFrom(cur, t, s.prev) {
                path.append(a)
                length += g.arcs[a].length
            }
        }
        guard var cur = path.last, back.dist[cur].isFinite else { return nil }
        var steps = 0
        while back.next[cur] >= 0, steps < 100_000 {
            cur = back.next[cur]
            path.append(cur)
            steps += 1
        }
        return path
    }

    /// The arcs from after `cur` to `t` (both search ends from `forward(fromArc:)`).
    private static func pathFrom(_ cur: Int, _ t: Int, _ prev: [Int]) -> [Int] {
        var out = [t]
        var x = t
        while prev[x] >= 0 { x = prev[x]; out.append(x) }
        return out.reversed()
    }

    static func coords(_ g: Graph, _ arcs: [Int]) -> [LatLon] {
        var out: [LatLon] = []
        for a in arcs {
            let s = g.segments[g.arcs[a].segment]
            let pts = g.arcs[a].direction == .forward ? s.coords : s.coords.reversed()
            out.append(contentsOf: out.isEmpty ? pts : Array(pts.dropFirst()))
        }
        return out
    }

    /// From `maxspeed`, else the road class speeds (km/h).
    static func seconds(_ g: Graph, _ arcs: [Int]) -> Double {
        let classKmh: [String: Double] = ["motorway": 105, "trunk": 90, "primary": 70, "secondary": 60, "tertiary": 50,
                                          "residential": 40, "unclassified": 40, "living_street": 15, "service": 20]
        var t = 0.0
        for a in arcs {
            let s = g.segments[g.arcs[a].segment]
            var kmh = classKmh[(s.tags["highway"] ?? "").replacingOccurrences(of: "_link", with: "")] ?? 40
            if let limit = SpeedLimit.parse(s.tags["maxspeed"], unitless: .mph) {
                kmh = limit.unit == .mph ? Double(limit.value) * 1.609344 : Double(limit.value)
            }
            t += s.length / (kmh / 3.6)
        }
        return t
    }

    /// Up to 9 points spread over the route by length, in order (the parent's hand-off limit).
    static func waypoints(_ g: Graph, _ arcs: [Int]) -> [LatLon] {
        let c = coords(g, arcs)
        let total = OSMGeo.lineLength(c)
        guard total > 0 else { return [] }
        return (1...9).map { OSMGeo.point(along: c, offset: total * Double($0) / 10) }
    }

    /// Greedy legs look this far around the current arc first.
    static let localSearchM = 4000.0

    /// Reused buffers of a bounded search: only what a search touched is reset for the next one.
    final class Search {
        var dist: [Double]
        var prev: [Int]
        var value: [Double]
        var done: [Bool]
        var touched: [Int] = []
        /// Arcs in the order they were settled (increasing cost).
        var order: [Int] = []

        init(_ n: Int) {
            dist = [Double](repeating: .infinity, count: n)
            prev = [Int](repeating: -1, count: n)
            value = [Double](repeating: 0, count: n)
            done = [Bool](repeating: false, count: n)
        }

        func reset() {
            for a in touched {
                dist[a] = .infinity
                prev[a] = -1
                value[a] = 0
                done[a] = false
            }
            touched.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
        }
    }

    /// Cost from the end of `start` onwards, up to `limit`, into reused buffers.
    static func bounded(_ g: Graph, fromArc start: Int, limit: Double, into s: Search) {
        s.reset()
        var heap = Heap()
        for b in g.outgoing[g.arcs[start].to] ?? [] where g.allows(start, b) && g.arcs[b].length < s.dist[b] {
            if s.dist[b] == .infinity { s.touched.append(b) }
            s.dist[b] = g.arcs[b].length
            s.prev[b] = -2 - start
            heap.push(s.dist[b], b)
        }
        while let (d, a) = heap.pop() {
            guard !s.done[a], d <= s.dist[a], d <= limit else { continue }
            s.done[a] = true
            s.order.append(a)
            for b in g.outgoing[g.arcs[a].to] ?? [] where g.allows(a, b) && !s.done[b] {
                let nd = d + g.arcs[b].length
                if nd < s.dist[b] - 1e-9 || (abs(nd - s.dist[b]) <= 1e-9 && s.prev[b] >= 0 && a < s.prev[b]) {
                    if s.dist[b] == .infinity { s.touched.append(b) }
                    s.dist[b] = nd
                    s.prev[b] = a
                    heap.push(nd, b)
                }
            }
        }
    }

    // MARK: Hand-off (SPEC 18.5)

    /// "34 km, davon 21 km neu (62 %), 18 Ampeln, 9 schiefe Kreuzungen, etwa 48 min".
    static func card(_ r: Route) -> String {
        func km(_ m: Double) -> String { m < 10_000 ? String(format: "%.1f", m / 1000).replacingOccurrences(of: ".", with: ",") : "\(Int((m / 1000).rounded()))" }
        var parts = ["\(km(r.lengthM)) km, davon \(km(r.newM)) km neu (\(Int((100 * r.newM / max(r.lengthM, 1)).rounded())) %)"]
        for f in ScenarioFinder.Feature.allCases { if let n = r.counts[f], n > 0 { parts.append("\(n) \(n == 1 ? f.nouns.0 : f.nouns.1)") } }
        let minutes = Int((r.seconds / 60).rounded())
        parts.append(minutes < 60 ? "etwa \(minutes) min" : "etwa \(minutes / 60) h \(minutes % 60) min")
        return parts.joined(separator: ", ")
    }

    /// Google Maps directions with up to 9 waypoints in order (the parent's limit); only the
    /// coordinates of the route go into the URL.
    static func googleMapsURL(_ r: Route) -> URL? {
        guard let first = r.coords.first, let last = r.coords.last else { return nil }
        func f(_ p: LatLon) -> String { String(format: "%.6f,%.6f", p.lat, p.lon) }
        var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
        parts.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "origin", value: f(first)),
                            URLQueryItem(name: "destination", value: f(last)),
                            URLQueryItem(name: "waypoints", value: r.waypoints.prefix(9).map(f).joined(separator: "|")),
                            URLQueryItem(name: "travelmode", value: "driving")]
        return parts.url
    }

    /// The route as GPX 1.1: a route of the waypoints for navigation apps, and the full line as a track.
    static func gpx(_ r: Route, name: String) -> String {
        func pt(_ tag: String, _ p: LatLon) -> String { String(format: "<%@ lat=\"%.7f\" lon=\"%.7f\"/>", tag, p.lat, p.lon) }
        var out = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                   "<gpx version=\"1.1\" creator=\"Spur\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
                   "<rte><name>\(name)</name>"]
        if let first = r.coords.first { out.append(pt("rtept", first)) }
        out.append(contentsOf: r.waypoints.map { pt("rtept", $0) })
        if let last = r.coords.last { out.append(pt("rtept", last)) }
        out.append("</rte><trk><name>\(name)</name><trkseg>")
        out.append(contentsOf: r.coords.map { pt("trkpt", $0) })
        out.append("</trkseg></trk></gpx>")
        return out.joined(separator: "\n")
    }

    /// A small binary heap of (cost, arc), ties by arc.
    struct Heap {
        private var items: [(Double, Int)] = []
        mutating func push(_ d: Double, _ a: Int) {
            items.append((d, a))
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard less(items[i], items[p]) else { break }
                items.swapAt(i, p)
                i = p
            }
        }
        mutating func pop() -> (Double, Int)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, less(items[l], items[m]) { m = l }
                    if r < items.count, less(items[r], items[m]) { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
        private func less(_ a: (Double, Int), _ b: (Double, Int)) -> Bool { a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
    }
}
