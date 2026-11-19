import Foundation

/// Spherical earth helpers. Pure.
nonisolated enum Geo {
    /// Mean earth radius in meters (IUGG).
    static let earthRadius = 6_371_008.8

    @inline(__always) static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    @inline(__always) static func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    /// Great circle distance in meters (haversine).
    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = rad(lat1), p2 = rad(lat2)
        let dp = p2 - p1
        let dl = rad(lon2 - lon1)
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    static func distance(_ a: Fix, _ b: Fix) -> Double {
        distance(lat1: a.latitude, lon1: a.longitude, lat2: b.latitude, lon2: b.longitude)
    }

    /// Initial bearing from point 1 to point 2 in degrees, 0 to 360, clockwise from north.
    static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = rad(lat1), p2 = rad(lat2)
        let dl = rad(lon2 - lon1)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let b = deg(atan2(y, x))
        return (b + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point at `distance` meters from a start along `bearing` degrees.
    static func destination(lat: Double, lon: Double, bearing: Double, distance: Double) -> (lat: Double, lon: Double) {
        let d = distance / earthRadius
        let b = rad(bearing)
        let p1 = rad(lat), l1 = rad(lon)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        let lon2 = (deg(l2) + 540).truncatingRemainder(dividingBy: 360) - 180
        return (deg(p2), lon2)
    }

    /// Degrees of latitude that span `meters` along a meridian.
    static func latitudeDegrees(forMeters meters: Double) -> Double {
        deg(meters / earthRadius)
    }
}
