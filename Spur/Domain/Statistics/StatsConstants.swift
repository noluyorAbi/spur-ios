import Foundation

/// Every threshold used by the statistics, in one place.
nonisolated enum StatsConstants {
    /// Default limit for a usable fix: horizontal accuracy known and at most this many meters.
    static let defaultUsableAccuracy: Double = 30
    /// Two consecutive fixes further apart than this (seconds) are separated by a gap.
    static let gapThreshold: Double = 5
    /// A fix with a speed of at least this (m/s) is moving.
    static let movingSpeed: Double = 1.0
    /// A stop is speed below `movingSpeed` for at least this many seconds.
    static let stopMinDuration: Double = 3
    /// Max speed only counts fixes whose speed accuracy (when known) is at most this (m/s).
    static let maxSpeedAccuracy: Double = 2
    /// Speed histogram bin width in km/h.
    static let histogramBinKmh: Double = 10

    // Road type (geschätzt)
    /// Rolling window length in seconds.
    static let roadWindow: Double = 60
    /// Median moving speed at or above this (km/h) is Autobahn.
    static let autobahnMinKmh: Double = 85
    /// Median moving speed at or above this (km/h), and below Autobahn, is Land.
    static let landMinKmh: Double = 50
    /// More than this many stops per km in the window is Stadt.
    static let stadtStopsPerKm: Double = 2
    /// A new class must hold this many seconds before it replaces the old one.
    static let roadHysteresis: Double = 30

    /// Elevation gain and loss ignore changes smaller than this (meters).
    static let elevationHysteresis: Double = 3
    /// Hard acceleration or braking above this magnitude (m/s²).
    static let dynamicsThreshold: Double = 3
    /// Dynamics only use speed pairs at most this many seconds apart.
    static let dynamicsMaxDt: Double = 2
    /// Sun altitude (degrees) above which it is day: refraction plus solar semi-diameter.
    static let sunHorizon: Double = -0.833
    /// GPS quality: a fix this accurate (meters) or better counts as precise.
    static let preciseAccuracy: Double = 5
    /// GPS quality: the second share shown (SPEC 14.1), fixes at most this many meters.
    static let goodAccuracy: Double = 10

    // Precision banner while recording (SPEC 14.1)
    /// The median horizontal accuracy is taken over the fixes of this many seconds.
    static let precisionWindow: Double = 30
    /// The banner shows when that median is above this many meters ...
    static let precisionPoorAccuracy: Double = 15
    /// ... without interruption for this many seconds; it clears as soon as the median recovers.
    static let precisionHold: Double = 30

    // Geocoding sampler
    /// At most one moving reverse geocode per this many seconds.
    static let geocodeMinInterval: Double = 60
    /// And only when at least this far (meters) from the previous sample.
    static let geocodeMinDistance: Double = 1000
}

/// Settings that change the statistics.
nonisolated struct StatsConfig: Sendable, Equatable {
    var usableAccuracy: Double = StatsConstants.defaultUsableAccuracy
    static let `default` = StatsConfig()
}
