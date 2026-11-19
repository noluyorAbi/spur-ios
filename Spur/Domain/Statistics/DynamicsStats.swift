import Foundation

/// Driving dynamics, approximate (SPEC section 5, "Fahrdynamik (ca.)").
///
/// Acceleration between two consecutive fixes that both report a valid speed and are at most
/// 2 s apart (and more than 0 s): a = Δv / Δt. A run of consecutive pairs above +3 m/s² is one
/// hard acceleration event, below -3 m/s² one hard braking event.
nonisolated struct DynamicsStats: Codable, Sendable, Equatable {
    var hardAccelerations: Int
    var hardBrakings: Int
    /// Strongest acceleration seen (m/s²), nil without eligible pairs.
    var maxAcceleration: Double?
    /// Strongest deceleration seen (m/s², negative), nil without eligible pairs.
    var maxDeceleration: Double?

    static func compute(_ track: Track) -> DynamicsStats {
        let f = track.fixes
        var accel = 0, brake = 0
        var inAccel = false, inBrake = false
        var maxA: Double?, maxD: Double?
        for i in 1..<max(1, f.count) {
            let dt = f[i].time - f[i - 1].time
            guard !track.crossesGap[i], dt > 0, dt <= StatsConstants.dynamicsMaxDt,
                  let v0 = f[i - 1].speed, let v1 = f[i].speed
            else {
                inAccel = false
                inBrake = false
                continue
            }
            let a = (v1 - v0) / dt
            maxA = Swift.max(maxA ?? a, a)
            maxD = Swift.min(maxD ?? a, a)
            if a > StatsConstants.dynamicsThreshold {
                if !inAccel { accel += 1 }
                inAccel = true
            } else {
                inAccel = false
            }
            if a < -StatsConstants.dynamicsThreshold {
                if !inBrake { brake += 1 }
                inBrake = true
            } else {
                inBrake = false
            }
        }
        return DynamicsStats(hardAccelerations: accel, hardBrakings: brake, maxAcceleration: maxA, maxDeceleration: maxD)
    }
}
