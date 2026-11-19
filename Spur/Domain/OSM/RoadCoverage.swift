import Foundation

/// Which directions of which roads were driven (SPEC 15). Pure.
///
/// The unit is an OSM edge: the piece of a way between two consecutive nodes, per travel
/// direction (forward = along the way's node order). Segments are not used as the key because
/// where a segment ends depends on the junctions the loaded tiles contain; an edge never changes.

/// One edge, `a` before `b` in the way's node order.
nonisolated struct CoverageEdgeKey: Hashable, Sendable, Codable, Comparable {
    var wayId: Int64
    var a: Int64
    var b: Int64

    static func < (l: Self, r: Self) -> Bool { (l.wayId, l.a, l.b) < (r.wayId, r.a, r.b) }
}

/// Consecutive edges of one way with the same driven directions (`nodes` and `coords` in the
/// way's order, one more than the edges).
nonisolated struct CoverageRun: Codable, Sendable, Equatable {
    var wayId: Int64
    var nodes: [Int64]
    var coords: [LatLon]
    var forward: Bool
    var backward: Bool
    /// The way's pairing key (`RoadCoverage.roadKey`): highway class plus name or ref, nil
    /// without either. Version 2.
    var road: String?
    /// The way is one-way. Version 2.
    var oneway: Bool?
    /// Passes per direction (SPEC 18.7): how many separate traversals of each edge of the run in
    /// that direction this trip made. Nil in files before 1.4: 1 for a driven direction.
    var forwardPasses: Int?
    var backwardPasses: Int?
    /// From an accepted gap fill (SPEC 18.8), not from fixes; nil for driven runs.
    var inferred: Bool?
    /// Drawing only, never stored: one carriageway of a divided road whose other carriageway was
    /// driven the other way (`RoadCoverage.paired`).
    var paired = false

    enum CodingKeys: String, CodingKey {
        case wayId, nodes, coords, forward, backward, road, oneway, forwardPasses, backwardPasses, inferred
    }

    /// Passes in a direction, with the fallback of 1 for a driven direction of an old file.
    var passesForward: Int { forward ? max(1, forwardPasses ?? 1) : 0 }
    var passesBackward: Int { backward ? max(1, backwardPasses ?? 1) : 0 }
}

/// What one trip drove, stored per trip in `coverage.json` (also when empty).
nonisolated struct TripCoverage: Codable, Sendable, Equatable {
    /// 2: runs carry the way's road key and one-way flag, for pairing divided roads. 3: runs carry
    /// pass counts (SPEC 18.7). An older file still draws (passes 1) while its trip is analyzed
    /// again; another version sends its trip back to the analysis.
    static let currentVersion = 3
    var version = TripCoverage.currentVersion
    var runs: [CoverageRun] = []
}

/// Collects the driven pieces of one trip's matched path and decides, per edge and direction,
/// whether it was driven: at least 70 % of the edge's length covered, the trip's intervals united
/// (the parent's `COVERAGE_MIN_FRACTION`). Pieces on the route guessed across a GPS gap and
/// pieces against a way's legal direction never count. A stretch of a way shorter than 50 m that
/// was not counted, between two driven edges of the same way and direction, counts too: the car
/// demonstrably drove through it (the shortfall comes from interval ends at junctions).
nonisolated struct CoverageAccumulator {
    static let minFraction = 0.7
    static let fillGapM = 50.0
    /// Below this an overlap is floating-point noise at a node, not driving.
    static let epsilon = 1e-6

    private struct EdgeData {
        var a: LatLon
        var b: LatLon
        var length: Double
        var forward: [ClosedRange<Double>] = []
        var backward: [ClosedRange<Double>] = []
        /// Separate traversals per direction (SPEC 18.7): a piece continues the last traversal
        /// when it follows the piece that last touched the edge, else it starts a new one.
        var forwardTraversals: [[ClosedRange<Double>]] = []
        var backwardTraversals: [[ClosedRange<Double>]] = []
        var lastForwardPiece = Int.min
        var lastBackwardPiece = Int.min

        mutating func record(_ range: ClosedRange<Double>, forward isForward: Bool, piece: Int) {
            if isForward {
                forward.append(range)
                if lastForwardPiece >= piece - 1, !forwardTraversals.isEmpty { forwardTraversals[forwardTraversals.count - 1].append(range) } else { forwardTraversals.append([range]) }
                lastForwardPiece = piece
            } else {
                backward.append(range)
                if lastBackwardPiece >= piece - 1, !backwardTraversals.isEmpty { backwardTraversals[backwardTraversals.count - 1].append(range) } else { backwardTraversals.append([range]) }
                lastBackwardPiece = piece
            }
        }

        /// Traversals that each cover the edge as a drive does (at least 1 when the united
        /// coverage counts as driven).
        func passes(forward isForward: Bool) -> Int {
            let all = isForward ? forward : backward
            guard CoverageAccumulator.isDriven(all, length: length) else { return 0 }
            let each = (isForward ? forwardTraversals : backwardTraversals).filter { CoverageAccumulator.isDriven($0, length: length) }.count
            return max(1, each)
        }
    }

    /// Counts the pieces added, so a later piece on an edge is a new traversal.
    private var pieceIndex = 0

    private var edges: [CoverageEdgeKey: EdgeData] = [:]
    /// Every segment a piece touched, per way, for the gap fill.
    private var seen: [Int64: [String: RoadSegment]] = [:]
    /// Road key and one-way flag per way.
    private var ways: [Int64: (road: String?, oneway: Bool)] = [:]

    var isEmpty: Bool { edges.isEmpty }

    /// One driven piece: `from` and `to` are meters from the segment's entry end in the travel
    /// direction (as the matchers report them).
    mutating func add(_ piece: DrivenPiece, segment s: RoadSegment) {
        let n = s.nodeIds.count
        guard !piece.bridged, s.allows(piece.direction), n >= 2, s.cum.count == n, s.coords.count == n else { return }
        pieceIndex += 1
        let lo = max(0, min(piece.from, piece.to)), hi = min(s.length, max(piece.from, piece.to))
        // Absolute offsets from the segment's first node (the way's order).
        let x0 = piece.direction == .forward ? lo : s.length - hi
        let x1 = piece.direction == .forward ? hi : s.length - lo
        guard x1 - x0 > Self.epsilon else { return }
        seen[s.wayId, default: [:]][s.id] = s
        ways[s.wayId] = (RoadCoverage.roadKey(s.tags), s.directions.count == 1)
        for i in 0..<(n - 1) {
            guard s.nodeIds[i] != s.nodeIds[i + 1] else { continue }
            let e0 = s.cum[i], e1 = s.cum[i + 1]
            let length = e1 - e0
            let o0 = max(x0, e0), o1 = min(x1, e1)
            if length > Self.epsilon {
                guard o1 - o0 > Self.epsilon else { continue }
            } else {
                // A zero-length edge (two nodes on one spot) counts when the piece runs through it.
                guard x0 < e0 - Self.epsilon, x1 > e1 + Self.epsilon else { continue }
            }
            let key = CoverageEdgeKey(wayId: s.wayId, a: s.nodeIds[i], b: s.nodeIds[i + 1])
            var d = edges[key] ?? EdgeData(a: s.coords[i], b: s.coords[i + 1], length: max(0, length))
            let range = (o0 - e0)...(max(o0, o1) - e0)
            d.record(range, forward: piece.direction == .forward, piece: pieceIndex)
            edges[key] = d
        }
    }

    /// Length of the union of intervals.
    static func unitedLength(_ ranges: [ClosedRange<Double>]) -> Double {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var total = 0.0
        var current: ClosedRange<Double>?
        for r in sorted {
            if let c = current, r.lowerBound <= c.upperBound {
                current = c.lowerBound...max(c.upperBound, r.upperBound)
            } else {
                if let c = current { total += c.upperBound - c.lowerBound }
                current = r
            }
        }
        if let c = current { total += c.upperBound - c.lowerBound }
        return total
    }

    static func isDriven(_ ranges: [ClosedRange<Double>], length: Double) -> Bool {
        guard !ranges.isEmpty else { return false }
        if length <= epsilon { return true }
        return unitedLength(ranges) >= minFraction * length - 1e-9
    }

    /// The driven edges, as runs.
    func coverage() -> TripCoverage {
        var driven: [CoverageEdgeKey: (f: Bool, b: Bool)] = [:]
        var passes: [CoverageEdgeKey: (f: Int, b: Int)] = [:]
        for (key, d) in edges {
            let f = Self.isDriven(d.forward, length: d.length)
            let b = Self.isDriven(d.backward, length: d.length)
            if f || b {
                driven[key] = (f, b)
                passes[key] = (d.passes(forward: true), d.passes(forward: false))
            }
        }
        var geometry: [CoverageEdgeKey: (LatLon, LatLon)] = edges.mapValues { ($0.a, $0.b) }
        fillGaps(&driven, &geometry, &passes)
        let out = driven.map { key, d in
            RoadCoverage.Edge(key: key, a: geometry[key]!.0, b: geometry[key]!.1, forward: d.f, backward: d.b,
                              road: ways[key.wayId]?.road, oneway: ways[key.wayId]?.oneway ?? false,
                              forwardPasses: d.f ? max(1, passes[key]?.f ?? 1) : 0, backwardPasses: d.b ? max(1, passes[key]?.b ?? 1) : 0)
        }
        return TripCoverage(runs: RoadCoverage.runs(out))
    }

    /// Fills stretches shorter than `fillGapM` between two driven edges of the same way and
    /// direction, along the node order of the segments the trip touched (only in a direction the
    /// way allows).
    private func fillGaps(_ driven: inout [CoverageEdgeKey: (f: Bool, b: Bool)], _ geometry: inout [CoverageEdgeKey: (LatLon, LatLon)],
                          _ passes: inout [CoverageEdgeKey: (f: Int, b: Int)]) {
        for wayId in seen.keys.sorted() {
            let list = seen[wayId]!.values.sorted { $0.id < $1.id }
            var byFrom: [Int64: RoadSegment] = [:]
            var toNodes: Set<Int64> = []
            for s in list {
                byFrom[s.fromNode] = s
                toNodes.insert(s.toNode)
            }
            let allowed = Set(list.first?.directions ?? [])
            var used: Set<String> = []
            // Chains of touched segments, from those nothing leads into, then any left (loops).
            for start in list.filter({ !toNodes.contains($0.fromNode) }) + list where !used.contains(start.id) {
                var nodes: [Int64] = []
                var coords: [LatLon] = []
                var cum: [Double] = []
                var current: RoadSegment? = start
                while let seg = current, !used.contains(seg.id) {
                    used.insert(seg.id)
                    let base = cum.last ?? 0
                    let skip = nodes.isEmpty ? 0 : 1
                    nodes.append(contentsOf: seg.nodeIds.dropFirst(skip))
                    coords.append(contentsOf: seg.coords.dropFirst(skip))
                    cum.append(contentsOf: seg.cum.dropFirst(skip).map { base + $0 })
                    current = byFrom[seg.toNode]
                }
                guard nodes.count >= 3 else { continue }
                for forward in [true, false] where allowed.contains(forward ? .forward : .backward) {
                    var lastDriven: Int?
                    for i in 0..<(nodes.count - 1) {
                        let key = CoverageEdgeKey(wayId: wayId, a: nodes[i], b: nodes[i + 1])
                        guard driven[key].map({ forward ? $0.f : $0.b }) ?? false else { continue }
                        if let last = lastDriven, i > last + 1, cum[i] - cum[last + 1] < Self.fillGapM {
                            // A filled stretch takes the smaller pass count of its two ends.
                            let lastKey = CoverageEdgeKey(wayId: wayId, a: nodes[last], b: nodes[last + 1])
                            let ends = [passes[lastKey], passes[key]].compactMap { $0.map { forward ? $0.f : $0.b } }.filter { $0 > 0 }
                            let fill = ends.min() ?? 1
                            for j in (last + 1)..<i where nodes[j] != nodes[j + 1] {
                                let k = CoverageEdgeKey(wayId: wayId, a: nodes[j], b: nodes[j + 1])
                                var d = driven[k] ?? (false, false)
                                var p = passes[k] ?? (0, 0)
                                if forward { d.f = true; p.f = max(p.f, fill) } else { d.b = true; p.b = max(p.b, fill) }
                                driven[k] = d
                                passes[k] = p
                                if geometry[k] == nil { geometry[k] = (coords[j], coords[j + 1]) }
                            }
                        }
                        lastDriven = i
                    }
                }
            }
        }
    }
}

nonisolated enum RoadCoverage {
    /// One driven edge with its directions.
    struct Edge: Sendable, Equatable {
        var key: CoverageEdgeKey
        var a: LatLon
        var b: LatLon
        var forward: Bool
        var backward: Bool
        var road: String? = nil
        var oneway = false
        /// Passes per direction (SPEC 18.7); within one trip the trip's own, after `merge` the
        /// sum over trips.
        var forwardPasses = 0
        var backwardPasses = 0
        /// The newest trip that drove the edge, after `merge` with dates.
        var lastDriven: Date? = nil
        /// Only from accepted gap fills (SPEC 18.8), never from fixes.
        var inferred = false
        /// Set by `paired` only.
        var paired = false

        var passes: Int { forwardPasses + backwardPasses }
    }

    /// Driven in one direction, or in both. A one-way way can only be `one` or `paired` (SPEC
    /// 15.1): `paired` is one carriageway of a divided road whose other carriageway was driven the
    /// other way. It is drawn green like `both` but keeps its own direction and single arrow.
    enum State: String, Sendable, Equatable {
        case one, both, paired
    }

    /// What pairs two carriageways: the highway class and the name (else the ref). Nil without a
    /// name or ref: unnamed ways never pair.
    static func roadKey(_ tags: [String: String]) -> String? {
        guard let label = tags["name"] ?? tags["ref"], !label.isEmpty else { return nil }
        return "\(tags["highway"] ?? "")|\(label.lowercased())"
    }

    /// The farthest apart two carriageways of one road may be (centre lines, meters).
    static let pairMaxM = 60.0
    /// Frontage (service) roads lie on both sides of a freeway, as far apart as the freeway is
    /// wide: on the owner's West Loop 60 to 80 m (2026-11-14).
    static let frontageMaxM = 120.0
    /// Classes that pair only with their own class: a frontage road often carries the freeway's
    /// name, and the two must never pair.
    static let freewayClasses: Set<Substring> = ["motorway", "trunk"]

    /// How far apart two ways with these road keys may lie and still be one road's carriageways,
    /// nil when they are not one road: the same name, and the same class unless neither is a
    /// freeway class (one side of a divided road is sometimes mapped one class higher).
    static func pairLimit(_ a: String?, _ b: String?) -> Double? {
        guard let a, let b, let ia = a.firstIndex(of: "|"), let ib = b.firstIndex(of: "|") else { return nil }
        let ca = a[..<ia], cb = b[..<ib], name = a[a.index(after: ia)...]
        guard name == b[b.index(after: ib)...], !name.isEmpty else { return nil }
        if ca != cb && (freewayClasses.contains(ca) || freewayClasses.contains(cb)) { return nil }
        return name.contains("frontage") || name.contains("service road") ? frontageMaxM : pairMaxM
    }
    /// Two carriageways run antiparallel: their driven bearings differ by at least this.
    static let pairMinAngle = 150.0

    /// Marks the driven edges of one-way ways that have, within `pairLimit` across from their middle, a
    /// driven edge of another one-way way of the same road (`pairLimit`) running the other way: the two
    /// carriageways of a divided road driven both ways (owner, 2026-11-12). Per edge, so only the
    /// stretch driven on both carriageways pairs; after the merge, so out on one trip and back on
    /// another pairs too. The stored directions do not change.
    static func paired(_ edges: [Edge]) -> [Edge] {
        guard let first = edges.first else { return edges }
        let kx = 111_320 * cos(first.a.lat * .pi / 180), ky = 110_540.0
        let cell = max(pairMaxM, frontageMaxM)
        struct Cell: Hashable {
            var x: Int
            var y: Int
        }
        func cellOf(_ p: LatLon) -> Cell {
            Cell(x: Int(((p.lon - first.a.lon) * kx / cell).rounded(.down)), y: Int(((p.lat - first.a.lat) * ky / cell).rounded(.down)))
        }
        /// Distance from `p` to the line through `o`, nil when the foot of the perpendicular falls
        /// more than 5 m beyond either end of `o` (where `o` ends, the other carriageway ends).
        func across(_ p: LatLon, _ o: Edge) -> Double? {
            let ax = (o.a.lon - p.lon) * kx, ay = (o.a.lat - p.lat) * ky
            let dx = (o.b.lon - o.a.lon) * kx, dy = (o.b.lat - o.a.lat) * ky
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { return nil }
            let along = -(ax * dx + ay * dy) / len
            guard along >= -5, along <= len + 5 else { return nil }
            return abs(ax * dy - ay * dx) / len
        }
        func drivenBearing(_ e: Edge) -> Double {
            e.forward ? OSMGeo.bearing(e.a, e.b) : OSMGeo.bearing(e.b, e.a)
        }
        let candidates = edges.indices.filter { edges[$0].oneway && edges[$0].road != nil && edges[$0].forward != edges[$0].backward }
        var grid: [Cell: [Int]] = [:]
        for k in candidates {
            let ca = cellOf(edges[k].a), cb = cellOf(edges[k].b)
            for x in min(ca.x, cb.x)...max(ca.x, cb.x) {
                for y in min(ca.y, cb.y)...max(ca.y, cb.y) { grid[Cell(x: x, y: y), default: []].append(k) }
            }
        }
        var out = edges
        for k in candidates {
            let e = edges[k]
            let mid = LatLon(lat: (e.a.lat + e.b.lat) / 2, lon: (e.a.lon + e.b.lon) / 2)
            let bearing = drivenBearing(e)
            let c = cellOf(mid)
            var near: Set<Int> = []
            for dx in -1...1 { for dy in -1...1 { near.formUnion(grid[Cell(x: c.x + dx, y: c.y + dy)] ?? []) } }
            out[k].paired = near.contains { n in
                let o = edges[n]
                guard o.key.wayId != e.key.wayId, let limit = pairLimit(e.road, o.road) else { return false }
                return OSMGeo.angleDiff(bearing, drivenBearing(o)) >= pairMinAngle
                    && (across(mid, o).map { $0 <= limit } ?? false)
            }
        }
        return out
    }

    static func state(forward: Bool, backward: Bool) -> State? {
        if forward && backward { return .both }
        return forward || backward ? .one : nil
    }

    /// The edges of a trip's runs.
    static func edges(_ coverage: TripCoverage) -> [Edge] {
        var out: [Edge] = []
        for run in coverage.runs where run.nodes.count >= 2 && run.coords.count == run.nodes.count {
            for i in 0..<(run.nodes.count - 1) {
                out.append(Edge(key: CoverageEdgeKey(wayId: run.wayId, a: run.nodes[i], b: run.nodes[i + 1]),
                                a: run.coords[i], b: run.coords[i + 1], forward: run.forward, backward: run.backward,
                                road: run.road, oneway: run.oneway ?? false,
                                forwardPasses: run.passesForward, backwardPasses: run.passesBackward,
                                inferred: run.inferred ?? false, paired: run.paired))
            }
        }
        return out
    }

    /// All trips together: an edge's directions are united and its passes summed (SPEC 18.7).
    /// `dates`, when given, is each trip's date in the same order, for "zuletzt am".
    static func merge(_ trips: [TripCoverage], dates: [Date]? = nil) -> [Edge] {
        var byKey: [CoverageEdgeKey: Edge] = [:]
        for (t, trip) in trips.enumerated() {
            let date = dates.flatMap { t < $0.count ? $0[t] : nil }
            for var e in edges(trip) {
                e.lastDriven = date
                if var seen = byKey[e.key] {
                    seen.forward = seen.forward || e.forward
                    seen.backward = seen.backward || e.backward
                    seen.forwardPasses += e.forwardPasses
                    seen.backwardPasses += e.backwardPasses
                    seen.inferred = seen.inferred && e.inferred
                    if let d = date, d > (seen.lastDriven ?? .distantPast) { seen.lastDriven = d }
                    byKey[e.key] = seen
                } else {
                    byKey[e.key] = e
                }
            }
        }
        return byKey.keys.sorted().map { byKey[$0]! }
    }

    /// Chains edges of one way that follow each other (`b` of one is `a` of the next) and have the
    /// same directions (and pairing) into runs. Deterministic: ways and starts in key order.
    static func runs(_ edges: [Edge]) -> [CoverageRun] {
        var byWay: [Int64: [Edge]] = [:]
        for e in edges { byWay[e.key.wayId, default: []].append(e) }
        struct NodeFlags: Hashable {
            var node: Int64
            var f: Bool
            var b: Bool
            var p: Bool
        }
        var out: [CoverageRun] = []
        for wayId in byWay.keys.sorted() {
            let list = byWay[wayId]!.sorted { $0.key < $1.key }
            var byStart: [Int64: [Int]] = [:]
            var ends: Set<NodeFlags> = []
            for (k, e) in list.enumerated() {
                byStart[e.key.a, default: []].append(k)
                ends.insert(NodeFlags(node: e.key.b, f: e.forward, b: e.backward, p: e.paired))
            }
            var used = [Bool](repeating: false, count: list.count)
            func next(after e: Edge) -> Int? {
                (byStart[e.key.b] ?? []).first { !used[$0] && list[$0].forward == e.forward && list[$0].backward == e.backward && list[$0].paired == e.paired
                    && list[$0].forwardPasses == e.forwardPasses && list[$0].backwardPasses == e.backwardPasses && list[$0].inferred == e.inferred }
            }
            // Starts first (no matching edge ends where they begin), then whatever is left (loops).
            let order = list.indices.filter { !ends.contains(NodeFlags(node: list[$0].key.a, f: list[$0].forward, b: list[$0].backward, p: list[$0].paired)) }
                + list.indices
            for start in order where !used[start] {
                used[start] = true
                var e = list[start]
                var run = CoverageRun(wayId: wayId, nodes: [e.key.a, e.key.b], coords: [e.a, e.b], forward: e.forward, backward: e.backward,
                                      road: e.road, oneway: e.oneway,
                                      forwardPasses: e.forward ? max(1, e.forwardPasses) : nil, backwardPasses: e.backward ? max(1, e.backwardPasses) : nil,
                                      inferred: e.inferred ? true : nil, paired: e.paired)
                while let k = next(after: e) {
                    used[k] = true
                    e = list[k]
                    run.nodes.append(e.key.b)
                    run.coords.append(e.b)
                }
                out.append(run)
            }
        }
        return out
    }

    // MARK: Heatmap (SPEC 18.7)

    /// The five bins of the heatmap: 1, 2, 3 to 4, 5 to 9, 10 or more passes.
    static let heatBinFloors = [1, 2, 3, 5, 10]

    static func heatBin(_ passes: Int) -> Int {
        heatBinFloors.lastIndex { passes >= $0 } ?? 0
    }

    /// A run of edges driven equally often, for the Häufigkeit mode.
    struct HeatLine: Identifiable, Sendable, Equatable {
        var id: String
        var coords: [LatLon]
        var forwardPasses: Int
        var backwardPasses: Int
        var lastDriven: Date?
        var inferred = false
        var length: Double
        var center: LatLon
        var box: BBox
        /// Travel bearing of the way's order (degrees), for "Richtung Nord".
        var bearing: Double

        var passes: Int { forwardPasses + backwardPasses }
        var bin: Int { RoadCoverage.heatBin(passes) }
    }

    /// "12-mal gefahren, 8 Richtung Nord, 4 Richtung Süd, zuletzt am 12.11." (SPEC 18.7).
    static func heatInfo(_ line: HeatLine, calendar: Calendar = .current) -> String {
        func compass(_ bearing: Double) -> String {
            let names = ["Nord", "Nordost", "Ost", "Südost", "Süd", "Südwest", "West", "Nordwest"]
            let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            return names[Int((b + 22.5) / 45) % 8]
        }
        var parts = ["\(line.passes)-mal gefahren" + (line.inferred ? " (ergänzt, ohne GPS)" : "")]
        let f = line.forwardPasses, b = line.backwardPasses
        if f > 0 && b > 0 {
            parts.append("\(f) Richtung \(compass(line.bearing))")
            parts.append("\(b) Richtung \(compass(line.bearing + 180))")
        } else {
            parts.append("Richtung \(compass(f > 0 ? line.bearing : line.bearing + 180))")
        }
        if let d = line.lastDriven, d > .distantPast {
            let c = calendar.dateComponents([.day, .month], from: d)
            parts.append(String(format: "zuletzt am %d.%d.", c.day ?? 0, c.month ?? 0))
        }
        return parts.joined(separator: ", ")
    }

    /// The heat line nearest to `p` within `maxMeters`, for a tap.
    static func heatLine(near p: LatLon, in lines: [HeatLine], maxMeters: Double) -> HeatLine? {
        var best: (HeatLine, Double)?
        for line in lines where line.coords.count >= 2 {
            let d = OSMGeo.project(p, onto: line.coords).distance
            if d <= maxMeters, d < (best?.1 ?? .infinity) { best = (line, d) }
        }
        return best?.0
    }

    /// The merged edges as heat lines: one per run of equal pass counts, scraps under
    /// `isolatedMinM` dropped.
    static func heatLines(_ edges: [Edge]) -> [HeatLine] {
        var dates: [CoverageEdgeKey: Date] = [:]
        for e in edges { if let d = e.lastDriven { dates[e.key] = d } }
        return runs(edges).compactMap { run -> HeatLine? in
            guard run.coords.count >= 2 else { return nil }
            let length = OSMGeo.lineLength(run.coords)
            guard length >= isolatedMinM else { return nil }
            var last: Date?
            for i in 0..<(run.nodes.count - 1) {
                if let d = dates[CoverageEdgeKey(wayId: run.wayId, a: run.nodes[i], b: run.nodes[i + 1])], d > (last ?? .distantPast) { last = d }
            }
            let mid = TrailGeometry.point(along: run.coords, at: length / 2)?.point ?? run.coords[0]
            return HeatLine(id: "\(run.wayId):\(run.nodes.first!):\(run.nodes.last!):h", coords: run.coords,
                            forwardPasses: run.passesForward, backwardPasses: run.passesBackward, lastDriven: last,
                            inferred: run.inferred ?? false,
                            length: length, center: mid, box: Line.box(run.coords),
                            bearing: OSMGeo.bearing(run.coords.first!, run.coords.last!))
        }
    }

    // MARK: Drawing

    /// A run as drawn: points in the driven direction for `one` and `paired`, in way order for `both`.
    struct Line: Identifiable, Sendable, Equatable {
        var id: String
        var coords: [LatLon]
        var state: State
        /// Length in meters, for culling and arrows.
        var length: Double
        var center: LatLon
        /// Bounding box, for culling against the view.
        var box: BBox

        init(id: String, coords: [LatLon], state: State, length: Double, center: LatLon) {
            self.id = id
            self.coords = coords
            self.state = state
            self.length = length
            self.center = center
            box = Self.box(coords)
        }

        static func box(_ coords: [LatLon]) -> BBox {
            var b = BBox(south: 90, west: 180, north: -90, east: -180)
            for c in coords {
                b.south = min(b.south, c.lat)
                b.north = max(b.north, c.lat)
                b.west = min(b.west, c.lon)
                b.east = max(b.east, c.lon)
            }
            return b
        }
    }

    /// Lines shorter than this that touch no other line are dropped (stray matched scraps).
    static let isolatedMinM = 15.0

    /// Lines for the map: runs joined end to start across ways and through junctions (an overlap
    /// at a junction is invisible) where the state matches (for one direction also the
    /// direction), taking the straightest continuation; isolated scraps under 15 m dropped.
    static func lines(_ runs: [CoverageRun]) -> [Line] {
        dropIsolated(joined(single(runs)))
    }

    static func single(_ runs: [CoverageRun]) -> [Line] {
        runs.compactMap { run -> Line? in
            guard run.coords.count >= 2, var state = state(forward: run.forward, backward: run.backward) else { return nil }
            if state == .one && run.paired { state = .paired }
            let coords = state != .both && run.backward ? Array(run.coords.reversed()) : run.coords
            let length = OSMGeo.lineLength(coords)
            let mid = TrailGeometry.point(along: coords, at: length / 2)?.point ?? coords[0]
            return Line(id: "\(run.wayId):\(run.nodes.first!):\(run.nodes.last!):\(state.rawValue)", coords: coords,
                        state: state, length: length, center: mid)
        }
    }

    static func joined(_ lines: [Line]) -> [Line] {
        var degree: [LatLon: Int] = [:]
        var touching: [LatLon: [Int]] = [:]
        for (k, l) in lines.enumerated() {
            for p in [l.coords[0], l.coords[l.coords.count - 1]] {
                degree[p, default: 0] += 1
                touching[p, default: []].append(k)
            }
        }
        func bearing(_ a: LatLon, _ b: LatLon) -> Double { Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon) }
        var used = [Bool](repeating: false, count: lines.count)
        var out: [Line] = []
        // Chains start where a line does not simply continue (an end shared by other than two).
        let order = lines.indices.filter { degree[lines[$0].coords[0]] != 2 } + lines.indices
        for k in order where !used[k] {
            used[k] = true
            var line = lines[k]
            while let end = line.coords.last, line.coords.count >= 2 {
                let heading = bearing(line.coords[line.coords.count - 2], end)
                var best: (index: Int, coords: [LatLon], turn: Double)?
                for n in touching[end] ?? [] where !used[n] && lines[n].state == line.state {
                    var c = lines[n].coords
                    if c[0] != end {
                        // Entered at its end: only a both line may be walked backwards.
                        guard lines[n].state == .both, c[c.count - 1] == end else { continue }
                        c.reverse()
                    }
                    let turn = OSMGeo.angleDiff(heading, bearing(c[0], c[1]))
                    if best == nil || turn < best!.turn { best = (n, c, turn) }
                }
                guard let next = best else { break }
                used[next.index] = true
                line.coords.append(contentsOf: next.coords.dropFirst())
                line.id += "+" + lines[next.index].id
                line.length += lines[next.index].length
            }
            if line.id != lines[k].id {
                line.center = TrailGeometry.point(along: line.coords, at: line.length / 2)?.point ?? line.coords[0]
                line.box = Line.box(line.coords)
            }
            out.append(line)
        }
        return out
    }

    static func dropIsolated(_ lines: [Line]) -> [Line] {
        var count: [LatLon: Int] = [:]
        for l in lines { for p in Set(l.coords) { count[p, default: 0] += 1 } }
        return lines.filter { l in
            guard l.length < isolatedMinM else { return true }
            // Its ends touch another line.
            return (count[l.coords[0]] ?? 0) > 1 || (count[l.coords[l.coords.count - 1]] ?? 0) > 1
        }
    }

    /// One arrow on the map: at `point`, pointing along `bearing` (degrees); `both` draws a pair.
    /// `id` stays the same while the arrow does (line plus the mark's number and spacing).
    struct Arrow: Sendable, Equatable, Hashable {
        var point: LatLon
        var bearing: Double
        var both: Bool
        var id: String = ""
    }

    /// Arrows along lines (SPEC 15.2): one every `spacing` meters, the spacing doubled until the
    /// count fits `budget` (so arrows thin out, they are not cut), every line at least `minLength`
    /// long gets one; the bearing is the chord over `chord` meters, so a mark on a corner points
    /// along the road. Only points `visible` keeps; nearest to `center` first, none closer than
    /// `separation` meters to one already kept (a dense grid would otherwise be all chevrons),
    /// at most `budget`.
    static func arrows(_ lines: [Line], spacing: Double, minLength: Double, chord: Double, center: LatLon, budget: Int,
                       separation: Double = 0, visible: (LatLon) -> Bool = { _ in true }) -> [Arrow] {
        guard spacing > 0, budget > 0 else { return [] }
        var s = spacing
        for _ in 0..<10 {
            let count = lines.reduce(0) { $0 + markCount(length: $1.length, spacing: s, minLength: minLength) }
            if count <= budget { break }
            s *= 2
        }
        var out: [(Arrow, Double)] = []
        for line in lines {
            let marks = TrailGeometry.marks(along: line.coords, spacing: s, minLength: minLength, chord: chord)
            for (k, mark) in marks.enumerated() where visible(mark.0) {
                out.append((Arrow(point: mark.0, bearing: mark.1, both: line.state == .both, id: "\(line.id)#\(k)@\(Int(s))"),
                            OSMGeo.haversine(center, mark.0)))
            }
        }
        out.sort { $0.1 < $1.1 }
        return thin(out.map(\.0), separation: separation, budget: budget, around: center)
    }

    /// Keeps marks in the given order unless one already kept lies within `separation` meters,
    /// at most `budget` (a grid of `separation` cells, flat approximation).
    static func thin(_ marks: [Arrow], separation: Double, budget: Int, around center: LatLon) -> [Arrow] {
        guard separation > 0 else { return Array(marks.prefix(budget)) }
        let kx = 111_320 * cos(center.lat * .pi / 180), ky = 110_540.0
        struct Cell: Hashable {
            var x: Int
            var y: Int
        }
        var grid: [Cell: [(Double, Double)]] = [:]
        var out: [Arrow] = []
        for m in marks {
            guard out.count < budget else { break }
            let x = (m.point.lon - center.lon) * kx, y = (m.point.lat - center.lat) * ky
            let cx = Int((x / separation).rounded(.down)), cy = Int((y / separation).rounded(.down))
            var free = true
            outer: for dx in -1...1 {
                for dy in -1...1 {
                    for (ox, oy) in grid[Cell(x: cx + dx, y: cy + dy)] ?? [] where hypot(ox - x, oy - y) < separation {
                        free = false
                        break outer
                    }
                }
            }
            guard free else { continue }
            grid[Cell(x: cx, y: cy), default: []].append((x, y))
            out.append(m)
        }
        return out
    }

    static func markCount(length: Double, spacing: Double, minLength: Double) -> Int {
        if length < spacing { return length >= minLength ? 1 : 0 }
        return Int(((length - spacing / 2) / spacing).rounded(.down)) + 1
    }

    /// The polylines of one mark, `size` meters long: a chevron (left wing, tip, right wing)
    /// pointing along the bearing, or for `both` two chevrons pointing away from each other,
    /// staggered along the road with a clear gap between them. Side by side or nearly touching
    /// they read as "VA" or as a diamond (both seen on screenshots).
    static func chevrons(_ arrow: Arrow, size: Double) -> [[LatLon]] {
        func move(_ q: LatLon, _ b: Double, _ d: Double) -> LatLon {
            let r = Geo.destination(lat: q.lat, lon: q.lon, bearing: b, distance: d)
            return LatLon(lat: r.lat, lon: r.lon)
        }
        func chevron(_ p: LatLon, _ bearing: Double) -> [LatLon] {
            let tip = move(p, bearing, size * 0.5)
            let base = move(p, bearing + 180, size * 0.5)
            return [move(base, bearing - 90, size * 0.55), tip, move(base, bearing + 90, size * 0.55)]
        }
        guard arrow.both else { return [chevron(arrow.point, arrow.bearing)] }
        return [chevron(move(arrow.point, arrow.bearing, size * 0.95), arrow.bearing),
                chevron(move(arrow.point, arrow.bearing + 180, size * 0.95), arrow.bearing + 180)]
    }
}
