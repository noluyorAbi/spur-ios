import Foundation

/// A marker the passenger drops during a trip ("Ereignis markieren").
nonisolated struct TripEvent: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Tag: String, Codable, Sendable, CaseIterable, Identifiable {
        case construction
        case interestingScenario
        case hazard
        case closure
        case poorLaneMarking
        case obscuredSign
        case other

        var id: String { rawValue }

        /// German label shown in the UI and written into exports.
        var label: String {
            switch self {
            case .construction: "Baustelle"
            case .interestingScenario: "Interessantes Szenario"
            case .hazard: "Gefahrenstelle"
            case .closure: "Sperrung"
            case .poorLaneMarking: "Fahrbahnmarkierung schlecht"
            case .obscuredSign: "Schild verdeckt"
            case .other: "Sonstiges"
            }
        }

        var symbol: String {
            switch self {
            case .construction: "cone"
            case .interestingScenario: "star"
            case .hazard: "exclamationmark.triangle"
            case .closure: "nosign"
            case .poorLaneMarking: "road.lanes"
            case .obscuredSign: "eye.slash"
            case .other: "mappin"
            }
        }
    }

    var id: UUID
    var timestampMs: Int64
    var latitude: Double
    var longitude: Double
    /// Altitude above mean sea level.
    var altitude: Double?
    /// Height above the WGS 84 ellipsoid (GeoJSON's third coordinate).
    var ellipsoidalAltitude: Double?
    var tag: Tag
    var note: String?

    var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1000) }
}
