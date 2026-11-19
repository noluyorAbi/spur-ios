import Foundation

/// A plain coordinate pair for display geometry (no MapKit dependency, easy to test).
nonisolated struct LatLon: Sendable, Equatable, Hashable, Codable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    // Stored compactly as `[lat, lon]`.
    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lat = try c.decode(Double.self)
        lon = try c.decode(Double.self)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lat)
        try c.encode(lon)
    }
}
