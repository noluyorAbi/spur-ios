import Foundation

/// The owner's decision on a suggested route across a GPS gap (SPEC 18.8), kept in
/// `gap-fills.json` next to the raw files, which it never touches.
nonisolated struct GapFill: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case accepted, rejected
    }

    /// One driven edge of the fill, in the way's node order (as the coverage keys).
    struct Edge: Codable, Sendable, Equatable, Hashable {
        var wayId: Int64
        var a: Int64
        var b: Int64
        var forward: Bool
        var ca: LatLon
        var cb: LatLon
    }

    /// The gap's ends, so the fill belongs to one gap.
    var startMs: Int64
    var endMs: Int64
    var status: Status
    var edges: [Edge] = []
    var coords: [LatLon] = []
    var lengthM: Double = 0
    var streets: [String] = []
    /// Road features on the fill by the scenario finder's chips (the "ergänzt" bucket).
    var features: [String: Int] = [:]
    var method: Int = GapFiller.Suggestion.method

    var id: String { "\(startMs)-\(endMs)" }
}

nonisolated struct GapFillFile: Codable, Sendable, Equatable {
    var version = 1
    var fills: [GapFill] = []

    var accepted: [GapFill] { fills.filter { $0.status == .accepted } }
    var acceptedMeters: Double { accepted.reduce(0) { $0 + $1.lengthM } }

    /// The decision for one gap, replacing an earlier one.
    mutating func decide(_ fill: GapFill) {
        fills.removeAll { $0.id == fill.id }
        fills.append(fill)
        fills.sort { $0.startMs < $1.startMs }
    }

    /// "Ergänzung entfernen": back to undecided.
    mutating func undo(_ id: String) { fills.removeAll { $0.id == id } }

    /// The accepted fills as coverage runs, flagged as inferred (SPEC 18.8).
    func coverage() -> TripCoverage {
        var edges: [CoverageEdgeKey: (f: Int, b: Int, a: LatLon, bb: LatLon)] = [:]
        for fill in accepted {
            for e in fill.edges {
                let key = CoverageEdgeKey(wayId: e.wayId, a: e.a, b: e.b)
                var v = edges[key] ?? (0, 0, e.ca, e.cb)
                if e.forward { v.f += 1 } else { v.b += 1 }
                edges[key] = v
            }
        }
        return TripCoverage(runs: edges.keys.sorted().map { k in
            let v = edges[k]!
            return CoverageRun(wayId: k.wayId, nodes: [k.a, k.b], coords: [v.a, v.bb], forward: v.f > 0, backward: v.b > 0,
                               forwardPasses: v.f > 0 ? v.f : nil, backwardPasses: v.b > 0 ? v.b : nil, inferred: true)
        })
    }
}

nonisolated extension GapFiller.Suggestion {
    /// The suggestion as an accepted fill of the gap `startMs` to `endMs`.
    func fill(startMs: Int64, endMs: Int64, graph g: DiscoveryPlanner.Graph, features: [FeatureNode]) -> GapFill {
        var edges: [GapFill.Edge] = []
        var segments: [RoadSegment] = []
        for arc in arcs {
            let a = g.arcs[arc], s = g.segments[a.segment]
            segments.append(s)
            for i in 0..<(s.nodeIds.count - 1) where s.nodeIds[i] != s.nodeIds[i + 1] {
                edges.append(GapFill.Edge(wayId: s.wayId, a: s.nodeIds[i], b: s.nodeIds[i + 1], forward: a.direction == .forward,
                                          ca: s.coords[i], cb: s.coords[i + 1]))
            }
        }
        var counts: [String: Int] = [:]
        let hits = ScenarioFinder.analyze(segments, features: features, requested: Set(ScenarioFinder.Feature.allCases))
        var sites: [ScenarioFinder.Feature: Set<String>] = [:]
        for h in hits.values { for (f, s) in h.sites { sites[f, default: []].formUnion(s) } }
        for (f, s) in sites where !s.isEmpty { counts[f.rawValue] = s.count }
        return GapFill(startMs: startMs, endMs: endMs, status: .accepted, edges: edges, coords: coords, lengthM: lengthM,
                       streets: streets, features: counts)
    }
}
