import Foundation

/// The likely road between the two ends of a GPS gap (SPEC 18.8). Pure and deterministic; works
/// on the discovery planner's arc graph, so the same legality holds: oneway respected, private
/// ways left out, no U-turn except at a dead end.
nonisolated enum GapFiller {
    /// Why there is no suggestion, in the owner's words.
    enum NoSuggestion: String, Error, Sendable, Equatable {
        case noRoadData = "Keine Straßendaten hier"
        case implausible = "Kein plausibler Weg"
        case tooShort = "Lücke zu kurz"
    }

    struct End: Sendable {
        var position: LatLon
        /// Degrees, nil when unknown.
        var course: Double?
        var accuracy: Double = 10
    }

    struct Suggestion: Sendable, Equatable {
        /// Arc indexes in driving order (the first and last only partly driven).
        var arcs: [Int]
        var coords: [LatLon]
        var lengthM: Double
        var expectedSeconds: Double
        var elapsedSeconds: Double
        /// The streets of the path by length, longest first.
        var streets: [String]
        /// The method, stored with an accepted fill.
        static let method = 1
    }

    static let minStraightM = 50.0
    static let maxSnapM = 40.0
    /// The implied mean speed may be at most this times the path's free-flow speed.
    static let maxSpeedFactor = 1.3
    static let candidates = 3
    /// A car in a gap averages about this share of the free-flow speed.
    static let typicalPace = 0.8
    static let detourWeight = 1.0

    static func suggest(from a: End, to b: End, elapsed: Double, graph g: DiscoveryPlanner.Graph) -> Result<Suggestion, NoSuggestion> {
        guard OSMGeo.haversine(a.position, b.position) >= minStraightM else { return .failure(.tooShort) }
        let starts = snap(a, g, leaving: true), ends = snap(b, g, leaving: false)
        guard let s = starts.first, let e = ends.first else { return .failure(.noRoadData) }
        var options: [(arcs: [Int], length: Double, expected: Double)] = []
        var penalty: [Int: Double] = [:]
        var seen: Set<[Int]> = []
        for _ in 0..<(candidates * 2) {
            // Drivers take the fastest way: the candidates are the fastest path by the road speeds
            // and alternatives with its arcs made dearer.
            guard options.count < candidates, let p = path(g, from: s, to: e, penalty: penalty, perMetre: { secondsPerMetre(g, $0) }) else { break }
            if seen.insert(p.arcs).inserted {
                options.append((p.arcs, p.length, expectedSeconds(g, p.arcs, firstOffset: s.offset, lastOffset: e.offset)))
            }
            for arc in p.arcs { penalty[arc, default: 1] *= 1.6 }
        }
        guard !options.isEmpty else { return .failure(.noRoadData) }
        let elapsed = max(elapsed, 1)
        // Only paths the car could have driven in the time: at most 1.3 times the free flow.
        let plausible = options.filter { elapsed * maxSpeedFactor >= $0.expected }
        guard let fastest = plausible.map(\.expected).min() else { return .failure(.implausible) }
        // The candidate whose expected time fits the elapsed time best, with the usual slowdown
        // of a gap (lights, traffic: a car averages about `typicalPace` of the free flow), and
        // every detour weighed against the fastest path, so a slow gap does not pick a detour
        // only because it is longer.
        let best = plausible.enumerated().min { x, y in
            func score(_ e: Double) -> Double { abs(log(e / (elapsed * typicalPace))) + detourWeight * log(e / fastest) }
            let dx = score(x.element.expected), dy = score(y.element.expected)
            return dx != dy ? dx < dy : x.offset < y.offset
        }!.element
        var meters: [String: Double] = [:]
        for arc in best.arcs { meters[g.segments[g.arcs[arc].segment].streetName, default: 0] += g.arcs[arc].length }
        let streets = meters.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        return .success(Suggestion(arcs: best.arcs, coords: coords(g, best.arcs, s, e), lengthM: best.length,
                                   expectedSeconds: best.expected, elapsedSeconds: elapsed, streets: streets))
    }

    struct Snap: Sendable {
        var arc: Int
        /// Metres from the arc's entry to the projected point.
        var offset: Double
        var distance: Double
    }

    /// Arcs near an end whose direction agrees with the course (when known), nearest first.
    static func snap(_ end: End, _ g: DiscoveryPlanner.Graph, leaving: Bool) -> [Snap] {
        let reach = max(maxSnapM, end.accuracy * 1.5)
        var out: [Snap] = []
        for (i, a) in g.arcs.enumerated() {
            let s = g.segments[a.segment]
            let pts = a.direction == .forward ? s.coords : s.coords.reversed()
            let p = OSMGeo.project(end.position, onto: pts)
            guard p.distance <= reach else { continue }
            if let c = end.course, OSMGeo.angleDiff(c, p.bearing) > 60 { continue }
            out.append(Snap(arc: i, offset: min(max(0, p.offset), a.length), distance: p.distance))
        }
        return out.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.arc < $1.arc }
    }

    /// The cheapest legal path from a point on `s` to a point on `e`, costs scaled by `penalty`:
    /// the start arc costs its remainder, every further arc its length, the end arc up to the point.
    static func path(_ g: DiscoveryPlanner.Graph, from s: Snap, to e: Snap, penalty: [Int: Double],
                     perMetre: (Int) -> Double = { _ in 1 }) -> (arcs: [Int], length: Double)? {
        if s.arc == e.arc, e.offset >= s.offset { return ([s.arc], e.offset - s.offset) }
        let first = g.arcs[s.arc].length - s.offset
        var dist: [Int: Double] = [s.arc: first * (penalty[s.arc] ?? 1) * perMetre(s.arc)]
        var prev: [Int: Int] = [:]
        var done = Set<Int>()
        var heap = DiscoveryPlanner.Heap()
        heap.push(dist[s.arc]!, s.arc)
        while let (d, a) = heap.pop() {
            guard d <= (dist[a] ?? .infinity), done.insert(a).inserted else { continue }
            if a == e.arc && a != s.arc { break }
            if done.count > 200_000 { break }
            for b in g.outgoing[g.arcs[a].to] ?? [] where g.allows(a, b) && !done.contains(b) {
                let w = (b == e.arc ? e.offset : g.arcs[b].length) * (penalty[b] ?? 1) * perMetre(b)
                if d + w < (dist[b] ?? .infinity) - 1e-9 {
                    dist[b] = d + w
                    prev[b] = a
                    heap.push(d + w, b)
                }
            }
        }
        guard prev[e.arc] != nil else { return nil }
        var out = [e.arc]
        var x = e.arc
        while let p = prev[x] { out.append(p); x = p }
        let arcs = Array(out.reversed())
        var length = first + e.offset
        for arc in arcs.dropFirst().dropLast() { length += g.arcs[arc].length }
        return (arcs, length)
    }

    static func secondsPerMetre(_ g: DiscoveryPlanner.Graph, _ arc: Int) -> Double {
        let len = g.arcs[arc].length
        return len > 0 ? DiscoveryPlanner.seconds(g, [arc]) / len : 0.1
    }

    static func expectedSeconds(_ g: DiscoveryPlanner.Graph, _ arcs: [Int], firstOffset: Double, lastOffset: Double) -> Double {
        guard !arcs.isEmpty else { return 0 }
        var t = 0.0
        for (k, arc) in arcs.enumerated() {
            let full = DiscoveryPlanner.seconds(g, [arc])
            let len = g.arcs[arc].length
            var part = len
            if arcs.count == 1 { part = lastOffset - firstOffset }
            else if k == 0 { part = len - firstOffset }
            else if k == arcs.count - 1 { part = lastOffset }
            t += len > 0 ? full * max(0, part) / len : 0
        }
        return t
    }

    static func coords(_ g: DiscoveryPlanner.Graph, _ arcs: [Int], _ s: Snap, _ e: Snap) -> [LatLon] {
        var out: [LatLon] = []
        for (k, arc) in arcs.enumerated() {
            let seg = g.segments[g.arcs[arc].segment]
            let pts = g.arcs[arc].direction == .forward ? seg.coords : seg.coords.reversed()
            let len = g.arcs[arc].length
            let from = k == 0 ? s.offset : 0
            let to = k == arcs.count - 1 ? e.offset : len
            var cum = 0.0
            var piece: [LatLon] = [OSMGeo.point(along: pts, offset: from)]
            for (p, q) in zip(pts, pts.dropFirst()) {
                cum += OSMGeo.haversine(p, q)
                if cum > from && cum < to { piece.append(q) }
            }
            piece.append(OSMGeo.point(along: pts, offset: to))
            out.append(contentsOf: out.isEmpty ? piece : Array(piece.dropFirst()))
        }
        return out
    }
}
