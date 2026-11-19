import Foundation

/// One reverse geocoding result taken during a trip.
nonisolated struct PlaceSample: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case start, moving, end
    }

    /// Time of the fix that was geocoded, in ms since 1970.
    var timestampMs: Int64
    var latitude: Double
    var longitude: Double
    var kind: Kind
    /// City or town.
    var locality: String?
    /// Street name without a house number.
    var street: String?
}
