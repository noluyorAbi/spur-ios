import Foundation

/// Elevation (SPEC section 5), from fixes with a valid altitude above mean sea level.
///
/// Gain and loss use a 3 m hysteresis: a reference altitude moves only once the altitude has
/// changed by at least 3 m from it, and only that change is summed. Noise below 3 m adds nothing.
nonisolated struct ElevationStats: Codable, Sendable, Equatable {
    var min: Double
    var max: Double
    var gain: Double
    var loss: Double

    static func compute(_ fixes: [Fix]) -> ElevationStats? {
        let altitudes = fixes.compactMap(\.altitude)
        guard let first = altitudes.first else { return nil }
        var lo = first, hi = first, gain = 0.0, loss = 0.0
        var reference = first
        for a in altitudes {
            lo = Swift.min(lo, a)
            hi = Swift.max(hi, a)
            let delta = a - reference
            if delta >= StatsConstants.elevationHysteresis {
                gain += delta
                reference = a
            } else if -delta >= StatsConstants.elevationHysteresis {
                loss += -delta
                reference = a
            }
        }
        return ElevationStats(min: lo, max: hi, gain: gain, loss: loss)
    }
}
