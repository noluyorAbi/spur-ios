import Foundation

/// Streets by name from the road data, with how much of each is driven (SPEC 18.11, owner
/// request: search streets and route to the undiscovered ones). Pure and deterministic.
nonisolated enum StreetIndex {
    struct Street: Identifiable, Sendable, Equatable {
        var name: String
        var lengthM: Double
        /// Metres driven in at least one direction.
        var drivenM: Double
        /// Each segment's line, and whether it is driven.
        var lines: [[LatLon]]
        var driven: [Bool]
        /// Straight distance from the origin to the street's nearest point.
        var distanceM: Double
        var nearest: LatLon
        /// The nearest point on an undriven segment, nil when the street is driven throughout.
        var nearestUndriven: LatLon?
        var undrivenDistanceM: Double?

        var id: String { name }
        var undrivenM: Double { max(0, lengthM - drivenM) }
        var share: Double { lengthM > 0 ? drivenM / lengthM : 0 }
        /// Worth discovering: at least `minUndrivenM` not yet driven.
        var undiscovered: Bool { undrivenM >= StreetIndex.minUndrivenM }
    }

    static let minUndrivenM = 50.0

    /// One entry per street name; unnamed ways and private ones are left out.
    static func build(_ segments: [RoadSegment], origin: LatLon, driven: (RoadSegment, TravelDirection) -> Bool) -> [Street] {
        var byName: [String: Street] = [:]
        for s in segments where s.length > 0 && s.coords.count >= 2 && !DiscoveryPlanner.excluded(s) {
            guard let name = s.tags["name"] ?? s.tags["ref"], !name.isEmpty else { continue }
            let isDriven = driven(s, .forward) || driven(s, .backward)
            let p = OSMGeo.project(origin, onto: s.coords)
            let point = OSMGeo.point(along: s.coords, offset: max(0, min(p.offset, s.length)))
            var street = byName[name] ?? Street(name: name, lengthM: 0, drivenM: 0, lines: [], driven: [], distanceM: .infinity,
                                                nearest: point, nearestUndriven: nil, undrivenDistanceM: nil)
            street.lengthM += s.length
            if isDriven { street.drivenM += s.length }
            street.lines.append(s.coords)
            street.driven.append(isDriven)
            if p.distance < street.distanceM {
                street.distanceM = p.distance
                street.nearest = point
            }
            if !isDriven, p.distance < (street.undrivenDistanceM ?? .infinity) {
                street.undrivenDistanceM = p.distance
                street.nearestUndriven = point
            }
            byName[name] = street
        }
        return byName.values.sorted { $0.distanceM != $1.distanceM ? $0.distanceM < $1.distanceM : $0.name < $1.name }
    }

    /// Streets whose name matches the query, case and accents ignored: names that start with it
    /// first, then undiscovered before driven ones, then by distance. An empty query lists the
    /// nearest undiscovered streets.
    static func search(_ streets: [Street], query: String, limit: Int = 6) -> [Street] {
        let q = fold(query)
        if q.isEmpty {
            return Array(streets.filter(\.undiscovered)
                .sorted { ($0.undrivenDistanceM ?? .infinity, $0.name) < ($1.undrivenDistanceM ?? .infinity, $1.name) }
                .prefix(limit))
        }
        let hits = streets.compactMap { s -> (Street, Int)? in
            let n = fold(s.name)
            if n.hasPrefix(q) { return (s, 0) }
            if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return (s, 1) }
            if n.contains(q) { return (s, 2) }
            return nil
        }
        return Array(hits.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.undiscovered != b.0.undiscovered { return a.0.undiscovered }
            if a.0.distanceM != b.0.distanceM { return a.0.distanceM < b.0.distanceM }
            return a.0.name < b.0.name
        }.map(\.0).prefix(limit))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
