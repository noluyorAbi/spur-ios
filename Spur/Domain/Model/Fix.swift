import CoreLocation
import Foundation

/// One raw position fix exactly as Core Location delivered it.
///
/// Every field `CLLocation` offers is kept. A value Core Location marks invalid (a negative
/// accuracy, speed or course) is stored as nil, never as a made-up number.
nonisolated struct Fix: Sendable, Equatable, Hashable {
    /// Fix time in milliseconds since 1970-01-01 UTC.
    var timestampMs: Int64
    var latitude: Double
    var longitude: Double
    /// Radius of uncertainty in meters; nil when Core Location marks the position invalid.
    var horizontalAccuracy: Double?
    /// Altitude above mean sea level in meters.
    var altitude: Double?
    /// Altitude above the WGS 84 ellipsoid in meters.
    var ellipsoidalAltitude: Double?
    var verticalAccuracy: Double?
    /// Meters per second.
    var speed: Double?
    var speedAccuracy: Double?
    /// Degrees clockwise from true north, 0 to 360.
    var course: Double?
    var courseAccuracy: Double?
    var isSimulatedBySoftware: Bool?
    var isProducedByAccessory: Bool?

    /// Seconds since 1970, with millisecond precision.
    var time: Double { Double(timestampMs) / 1000 }
    var date: Date { Date(timeIntervalSince1970: time) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    init(
        timestampMs: Int64,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double? = nil,
        altitude: Double? = nil,
        ellipsoidalAltitude: Double? = nil,
        verticalAccuracy: Double? = nil,
        speed: Double? = nil,
        speedAccuracy: Double? = nil,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        isSimulatedBySoftware: Bool? = nil,
        isProducedByAccessory: Bool? = nil
    ) {
        self.timestampMs = timestampMs
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.isSimulatedBySoftware = isSimulatedBySoftware
        self.isProducedByAccessory = isProducedByAccessory
    }

    /// Copies every field of a `CLLocation`, mapping invalid values to nil.
    init(location l: CLLocation) {
        timestampMs = Int64((l.timestamp.timeIntervalSince1970 * 1000).rounded())
        latitude = l.coordinate.latitude
        longitude = l.coordinate.longitude
        horizontalAccuracy = Fix.valid(l.horizontalAccuracy)
        // A negative vertical accuracy marks both altitudes invalid.
        let altitudeValid = l.verticalAccuracy >= 0 && l.verticalAccuracy.isFinite
        verticalAccuracy = altitudeValid ? l.verticalAccuracy : nil
        altitude = altitudeValid && l.altitude.isFinite ? l.altitude : nil
        ellipsoidalAltitude = altitudeValid && l.ellipsoidalAltitude.isFinite ? l.ellipsoidalAltitude : nil
        speed = Fix.valid(l.speed)
        speedAccuracy = Fix.valid(l.speedAccuracy)
        course = Fix.valid(l.course)
        courseAccuracy = Fix.valid(l.courseAccuracy)
        if let source = l.sourceInformation {
            isSimulatedBySoftware = source.isSimulatedBySoftware
            isProducedByAccessory = source.isProducedByAccessory
        } else {
            isSimulatedBySoftware = nil
            isProducedByAccessory = nil
        }
    }

    /// nil for a negative or non-finite value (Core Location's marker for invalid).
    static func valid(_ value: Double) -> Double? {
        value >= 0 && value.isFinite ? value : nil
    }
}
