import Foundation

/// Geodesy for the road code, ported verbatim from the parent's `src/lib/geo.ts` so that junction
/// angles and distances match the parent to the last bit (skew parity, SPEC 14.3). The trip
/// statistics keep using `Geo`; the two differ only in the last digits.
nonisolated enum OSMGeo {
    static let R = 6_371_008.8

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Great-circle distance in meters (parent `haversineM`, asin form).
    static func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let dLat = rad(lat2 - lat1)
        let dLon = rad(lon2 - lon1)
        let s = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2)
        return 2 * R * asin(min(1, sqrt(s)))
    }

    static func haversine(_ a: LatLon, _ b: LatLon) -> Double {
        haversine(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    /// Initial bearing from a to b, degrees clockwise from north, 0 to 360 (parent `bearingDeg`).
    static func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let y = sin(rad(b.lon - a.lon)) * cos(rad(b.lat))
        let x = cos(rad(a.lat)) * sin(rad(b.lat)) - sin(rad(a.lat)) * cos(rad(b.lat)) * cos(rad(b.lon - a.lon))
        // JavaScript `%` keeps the sign of the dividend, like `truncatingRemainder`.
        return (deg(atan2(y, x)) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute difference between two bearings, 0 to 180 (parent `angleDiffDeg`).
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Length of a polyline in meters (parent `lineLengthM`).
    static func lineLength(_ coords: [LatLon]) -> Double {
        var sum = 0.0
        if coords.count > 1 {
            for i in 1..<coords.count { sum += haversine(coords[i - 1], coords[i]) }
        }
        return sum
    }

    struct Projection: Sendable, Equatable {
        /// Perpendicular distance from the point to the polyline, meters.
        var distance: Double
        /// Distance along the polyline from its start to the snapped point, meters (plane metric).
        var offset: Double
        /// Index of the leg the point snapped to.
        var leg: Int
        /// Bearing of that leg in polyline order.
        var bearing: Double
        var point: LatLon
    }

    /// Projects a point onto a polyline in a local equirectangular plane (parent `projectOnLine`).
    static func project(_ p: LatLon, onto coords: [LatLon]) -> Projection {
        let c = cos(rad(p.lat))
        let kx = (Double.pi / 180) * R * c
        let ky = (Double.pi / 180) * R
        var best: Projection?
        var acc = 0.0
        if coords.count > 1 {
            for i in 1..<coords.count {
                let a = coords[i - 1], b = coords[i]
                let ax = (a.lon - p.lon) * kx, ay = (a.lat - p.lat) * ky
                let bx = (b.lon - p.lon) * kx, by = (b.lat - p.lat) * ky
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
                let px = ax + t * dx, py = ay + t * dy
                let dist = (px * px + py * py).squareRoot()
                let legLen = len2.squareRoot()
                if best == nil || dist < best!.distance {
                    best = Projection(distance: dist, offset: acc + t * legLen, leg: i - 1,
                                      bearing: bearing(a, b), point: LatLon(lat: p.lat + py / ky, lon: p.lon + px / kx))
                }
                acc += legLen
            }
        }
        if let best { return best }
        guard let first = coords.first else { return Projection(distance: .infinity, offset: 0, leg: 0, bearing: 0, point: p) }
        return Projection(distance: haversine(p, first), offset: 0, leg: 0, bearing: 0, point: first)
    }

    /// Point at `offset` meters along a polyline (parent `pointAlong`).
    static func point(along coords: [LatLon], offset: Double) -> LatLon {
        var acc = 0.0
        if coords.count > 1 {
            for i in 1..<coords.count {
                let a = coords[i - 1], b = coords[i]
                let leg = haversine(a, b)
                if acc + leg >= offset && leg > 0 {
                    let t = (offset - acc) / leg
                    return LatLon(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
                }
                acc += leg
            }
        }
        return coords.last ?? LatLon(lat: 0, lon: 0)
    }
}
