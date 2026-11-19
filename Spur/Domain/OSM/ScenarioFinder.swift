import Foundation

/// "Was gibt es zu entdecken" (SPEC 18.4): the parent's scenario finder (parent SPEC 8,
/// `src/lib/scenario/*`) on Spur's own road data. Pure, deterministic.
///
/// 1. Every segment is checked against the requested feature rules.
/// 2. Segments with a hit whose nearest point lies within the radius are candidates.
/// 3. Candidates are grouped into clusters: from the nearest unassigned one, a cluster grows through
///    candidates sharing an end node, nearest first, up to `maxClusterM`.
/// 4. Score = feature density x share not yet driven x distance penalty; the top `maxResults`.
///
/// Left out against the parent, because Spur's tiles do not carry the data or the SPEC chips do
/// not ask for it: lane count changes, roads without lane markings, bridges and tunnels, sharp
/// curves (SPEC 18.4).
nonisolated enum ScenarioFinder {
    enum Feature: String, CaseIterable, Sendable, Identifiable, Hashable {
        case signals, skewed, stopSigns, roundabouts, levelCrossings, ramps, fastHighway, tollways, frontageTransitions

        var id: String { rawValue }

        /// The chip label.
        var label: String {
            switch self {
            case .signals: return "Ampeln"
            case .skewed: return "Schiefe Kreuzungen"
            case .stopSigns: return "Stoppschilder"
            case .roundabouts: return "Kreisverkehre"
            case .levelCrossings: return "Bahnübergänge"
            case .ramps: return "Auffahrten"
            case .fastHighway: return "Schnelle Straßen"
            case .tollways: return "Mautstraßen"
            case .frontageTransitions: return "Frontage-Übergänge"
            }
        }

        /// Singular and plural noun for the reason (the parent's German nouns).
        var nouns: (String, String) {
            switch self {
            case .signals: return ("Ampel", "Ampeln")
            case .skewed: return ("schiefe Kreuzung", "schiefe Kreuzungen")
            case .stopSigns: return ("Stoppschild", "Stoppschilder")
            case .roundabouts: return ("Kreisverkehr", "Kreisverkehre")
            case .levelCrossings: return ("Bahnübergang", "Bahnübergänge")
            case .ramps: return ("Rampe", "Rampen")
            case .fastHighway: return ("schnelle Strecke", "schnelle Strecken")
            case .tollways: return ("Mautstraße", "Mautstraßen")
            case .frontageTransitions: return ("Übergang Frontage Road zu Rampe", "Übergänge Frontage Road zu Rampe")
            }
        }

        /// Measured by the share of length that carries it (tag rules).
        var isLength: Bool { self == .ramps || self == .fastHighway || self == .tollways }
    }

    struct Query: Sendable {
        var origin: LatLon
        var radiusM: Double
        var features: Set<Feature>
        /// "nur fehlende Richtung": clusters without an open direction are left out.
        var onlyMissing = false
        var signalsPerKm = 3.0
    }

    struct Result: Identifiable, Sendable, Equatable {
        var id: String
        var segmentIds: [String]
        var coords: [[LatLon]]
        var center: LatLon
        var distanceM: Double
        var lengthM: Double
        var score: Double
        var counts: [Feature: Int]
        var missingCount: Int
        var reason: String
    }

    static let maxResults = 10
    static let maxClusterM = 2000.0
    static let distanceScaleM = 2000.0
    static let drivenFloor = 0.1
    static let densitySmoothingKm = 0.5
    static let fastHighwayMph = 65
    static let straightThroughDeg = 150.0

    // MARK: Rules

    static func isRamp(_ s: RoadSegment) -> Bool { (s.tags["highway"] ?? "").hasSuffix("_link") || s.categories.contains(.ramp) }

    static func isFrontage(_ s: RoadSegment) -> Bool {
        guard !isRamp(s) else { return false }
        if s.categories.contains(.frontage) || s.tags["frontage_road"] == "yes" { return true }
        let name = s.tags["name"] ?? ""
        return name.contains("Frontage") || name.contains("Service Road") || name.contains("Service Rd")
    }

    static func isRoundaboutWay(_ s: RoadSegment) -> Bool { ["roundabout", "circular"].contains(s.tags["junction"] ?? "") }

    static func matchesTag(_ f: Feature, _ s: RoadSegment) -> Bool {
        switch f {
        case .fastHighway:
            if s.tags["highway"] == "motorway" { return true }
            guard let limit = SpeedLimit.parse(s.tags["maxspeed"], unitless: .mph) else { return false }
            let mph = limit.unit == .mph ? Double(limit.value) : Double(limit.value) / 1.609344
            return mph >= Double(fastHighwayMph) - 1e-9
        case .ramps: return isRamp(s)
        case .tollways: return s.tags["toll"] == "yes" || s.categories.contains(.tollway)
        default: return false
        }
    }

    struct Hits {
        var segment: RoadSegment
        var sites: [Feature: Set<String>] = [:]
    }

    /// The requested rules on every segment; segments with at least one hit, by id.
    static func analyze(_ segments: [RoadSegment], features: [FeatureNode], requested: Set<Feature>) -> [String: Hits] {
        var unique: [String: RoadSegment] = [:]
        for s in segments where unique[s.id] == nil { unique[s.id] = s }
        var hits: [String: Hits] = [:]
        func add(_ s: RoadSegment, _ f: Feature, _ site: String) {
            var h = hits[s.id] ?? Hits(segment: s)
            h.sites[f, default: []].insert(site)
            hits[s.id] = h
        }
        let nodeFeature: [FeatureType: Feature] = [.trafficSignals: .signals, .stop: .stopSigns, .levelCrossing: .levelCrossings, .miniRoundabout: .roundabouts]
        var byNode: [Int64: [FeatureNode]] = [:]
        for f in features {
            let mapped = nodeFeature[f.type]
            let useful = (mapped.map { requested.contains($0) } ?? false) || (f.skewed == true && requested.contains(.skewed))
            if useful { byNode[f.nodeId, default: []].append(f) }
        }
        // One id per roundabout ring.
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        if requested.contains(.roundabouts) {
            for s in unique.values where isRoundaboutWay(s) {
                let a = find(s.fromNode), b = find(s.toNode)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        for s in unique.values.sorted(by: { $0.id < $1.id }) {
            for f in requested where f.isLength && matchesTag(f, s) { add(s, f, "w:\(s.wayId)") }
            if requested.contains(.roundabouts), isRoundaboutWay(s) { add(s, .roundabouts, "r:\(find(s.fromNode))") }
            for node in s.nodeIds {
                for f in byNode[node] ?? [] {
                    if let mapped = nodeFeature[f.type], requested.contains(mapped) { add(s, mapped, "n:\(node)") }
                    if f.skewed == true, requested.contains(.skewed) { add(s, .skewed, "n:\(node)") }
                }
            }
        }
        if requested.contains(.frontageTransitions) {
            var ends: [Int64: [RoadSegment]] = [:]
            for s in unique.values.sorted(by: { $0.id < $1.id }) {
                ends[s.fromNode, default: []].append(s)
                if s.toNode != s.fromNode { ends[s.toNode, default: []].append(s) }
            }
            for (node, list) in ends where list.count >= 2 {
                for i in 0..<list.count {
                    for j in (i + 1)..<list.count {
                        let a = list[i], b = list[j]
                        if (isFrontage(a) && isRamp(b)) || (isFrontage(b) && isRamp(a)) {
                            add(a, .frontageTransitions, "n:\(node)")
                            add(b, .frontageTransitions, "n:\(node)")
                        }
                    }
                }
            }
        }
        return hits
    }

    // MARK: Finder

    /// The top clusters within the radius, highest score first (ties: nearer, then id). `driven`
    /// says whether a segment is driven in a direction (Spur: at least 70 % of its length).
    static func find(_ q: Query, segments: [RoadSegment], features: [FeatureNode],
                     driven: (RoadSegment, TravelDirection) -> Bool) -> [Result] {
        let requested = q.features
        guard !requested.isEmpty, !segments.isEmpty else { return [] }
        struct Candidate {
            var hits: Hits
            var distanceM: Double
        }
        var candidates: [Candidate] = []
        for h in analyze(segments, features: features, requested: requested).values {
            let s = h.segment
            guard s.coords.count >= 2, s.length > 0 else { continue }
            let d = OSMGeo.project(q.origin, onto: s.coords).distance
            if d.isFinite, d <= q.radiusM { candidates.append(Candidate(hits: h, distanceM: d)) }
        }
        let sorted = candidates.sorted { ($0.distanceM, $0.hits.segment.id) < ($1.distanceM, $1.hits.segment.id) }
        var atNode: [Int64: [Int]] = [:]
        for (k, c) in sorted.enumerated() {
            atNode[c.hits.segment.fromNode, default: []].append(k)
            if c.hits.segment.toNode != c.hits.segment.fromNode { atNode[c.hits.segment.toNode, default: []].append(k) }
        }
        var assigned = Set<Int>()
        var results: [Result] = []
        for seed in sorted.indices where !assigned.contains(seed) {
            assigned.insert(seed)
            var cluster = [seed]
            var length = sorted[seed].hits.segment.length
            var i = 0
            while i < cluster.count {
                let cur = sorted[cluster[i]].hits.segment
                let next = ((atNode[cur.fromNode] ?? []) + (atNode[cur.toNode] ?? [])).filter { !assigned.contains($0) }.sorted()
                for c in next where !assigned.contains(c) && length + sorted[c].hits.segment.length <= maxClusterM {
                    assigned.insert(c)
                    cluster.append(c)
                    length += sorted[c].hits.segment.length
                }
                i += 1
            }
            if let r = evaluate(cluster.map { sorted[$0] }.map { ($0.hits, $0.distanceM) }, q, driven) { results.append(r) }
        }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.distanceM != b.distanceM { return a.distanceM < b.distanceM }
            return a.id < b.id
        }
        return Array(results.prefix(maxResults))
    }

    private static func evaluate(_ cluster: [(Hits, Double)], _ q: Query, _ driven: (RoadSegment, TravelDirection) -> Bool) -> Result? {
        let segments = cluster.map(\.0.segment)
        let lengthM = segments.reduce(0) { $0 + $1.length }
        guard lengthM > 0 else { return nil }
        let km = lengthM / 1000
        var counts: [Feature: Int] = [:]
        var density = 0.0
        for f in Feature.allCases where q.features.contains(f) {
            var sites = Set<String>()
            var carrying = 0.0
            for (h, _) in cluster {
                guard let found = h.sites[f] else { continue }
                sites.formUnion(found)
                carrying += h.segment.length
            }
            guard !sites.isEmpty else { continue }
            if f == .signals && !(Double(sites.count) / km > q.signalsPerKm) { continue }
            counts[f] = sites.count
            density += f.isLength ? carrying / 1000 / (km + densitySmoothingKm) : Double(sites.count) / (km + densitySmoothingKm)
        }
        guard density > 0 else { return nil }
        var existingM = 0.0, openM = 0.0, existing = 0, missing = 0
        var headingWeight: [String: Double] = [:]
        var headingOrder: [String] = []
        for s in segments {
            for d in [TravelDirection.forward, .backward] where s.allows(d) {
                existingM += s.length
                existing += 1
                guard !driven(s, d) else { continue }
                missing += 1
                openM += s.length
                let pts = d == .forward ? s.coords : s.coords.reversed()
                if let a = pts.first, let b = pts.last, OSMGeo.haversine(a, b) >= 1 {
                    let label = compass(OSMGeo.bearing(a, b))
                    if headingWeight[label] == nil { headingOrder.append(label) }
                    headingWeight[label, default: 0] += s.length
                }
            }
        }
        if q.onlyMissing && missing == 0 { return nil }
        let openShare = existingM > 0 ? openM / existingM : 0
        let undriven = q.onlyMissing ? openShare : drivenFloor + (1 - drivenFloor) * openShare
        let distance = cluster.map(\.1).min() ?? 0
        let score = density * undriven / (1 + distance / distanceScaleM)
        guard score.isFinite, score > 0 else { return nil }
        let heading = headingOrder.max { (headingWeight[$0] ?? 0) < (headingWeight[$1] ?? 0) }
        var parts = Feature.allCases.compactMap { f -> String? in
            guard let n = counts[f], n > 0 else { return nil }
            return "\(n) \(n == 1 ? f.nouns.0 : f.nouns.1)"
        }
        if missing == 0 { parts.append("bereits befahren") }
        else if missing == existing || heading == nil { parts.append("noch nicht befahren") }
        else { parts.append("Richtung \(heading!) fehlt") }
        return Result(id: segments[0].id, segmentIds: segments.map(\.id), coords: segments.map(\.coords),
                      center: center(segments), distanceM: distance, lengthM: lengthM, score: score, counts: counts,
                      missingCount: missing, reason: parts.joined(separator: ", "))
    }

    static func compass(_ bearing: Double) -> String {
        let names = ["Nord", "Nordost", "Ost", "Südost", "Süd", "Südwest", "West", "Nordwest"]
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((b / 45).rounded()) % 8]
    }

    private static func center(_ segments: [RoadSegment]) -> LatLon {
        var lat = 0.0, lon = 0.0, total = 0.0
        for s in segments {
            let mid = OSMGeo.point(along: s.coords, offset: s.length / 2)
            let w = max(s.length, 1e-9)
            lat += mid.lat * w
            lon += mid.lon * w
            total += w
        }
        let mean = LatLon(lat: lat / total, lon: lon / total)
        var best = mean, bestD = Double.infinity
        for s in segments where s.coords.count >= 2 {
            let p = OSMGeo.project(mean, onto: s.coords)
            if p.distance < bestD { bestD = p.distance; best = p.point }
        }
        return best
    }

    // MARK: Nearest undriven

    struct Nearest: Sendable, Equatable {
        var segment: RoadSegment
        var direction: TravelDirection
        var distanceM: Double
        var start: LatLon
    }

    /// "Nächste unbefahrene Strecke": the nearest legal segment-direction not yet driven that
    /// matches the chips (a segment with a hit for any of them; no chips, any segment), measured to
    /// where it has to be entered.
    static func nearestUndriven(from origin: LatLon, segments: [RoadSegment], features: [FeatureNode], chips: Set<Feature>,
                                driven: (RoadSegment, TravelDirection) -> Bool) -> Nearest? {
        let matching: Set<String>? = chips.isEmpty ? nil : Set(analyze(segments, features: features, requested: chips).keys)
        var best: Nearest?
        for s in segments where s.coords.count >= 2 {
            if let m = matching, !m.contains(s.id) { continue }
            for d in [TravelDirection.forward, .backward] where s.allows(d) && !driven(s, d) {
                let start = d == .forward ? s.coords[0] : s.coords[s.coords.count - 1]
                let dist = OSMGeo.haversine(origin, start)
                if best == nil || dist < best!.distanceM || (dist == best!.distanceM && s.id < best!.segment.id) {
                    best = Nearest(segment: s, direction: d, distanceM: dist, start: start)
                }
            }
        }
        return best
    }

    // MARK: Driven, from Spur's coverage

    /// A segment-direction counts as driven when at least 70 % of its length lies on edges driven
    /// in that direction (the edge rule of the coverage, SPEC 15).
    static func drivenLookup(_ edges: [RoadCoverage.Edge]) -> (RoadSegment, TravelDirection) -> Bool {
        var byKey: [CoverageEdgeKey: (Bool, Bool)] = [:]
        for e in edges { byKey[e.key] = (e.forward, e.backward) }
        return { s, d in
            guard s.nodeIds.count >= 2, s.cum.count == s.nodeIds.count, s.length > 0 else { return false }
            var drivenM = 0.0
            for i in 0..<(s.nodeIds.count - 1) {
                // Segment nodes run in the way's order, as the coverage keys do.
                guard let flags = byKey[CoverageEdgeKey(wayId: s.wayId, a: s.nodeIds[i], b: s.nodeIds[i + 1])] else { continue }
                if d == .forward ? flags.0 : flags.1 { drivenM += s.cum[i + 1] - s.cum[i] }
            }
            return drivenM >= CoverageAccumulator.minFraction * s.length - 1e-9
        }
    }
}
