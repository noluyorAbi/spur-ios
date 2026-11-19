#if DEBUG
import Foundation
import simd

/// Debug only: physically consistent device-motion samples (SPEC 16.3.1 and 16.3.3). Vehicle frame
/// x forward, y left, z up; CoreMotion conventions: gravity points to the earth in device axes (g),
/// userAcceleration is MINUS the device's physical acceleration (g; the accelerometer reports minus
/// the specific force, and userAcceleration is that minus gravity), rotationRate follows the
/// right-hand rule (rad/s). `mount` turns vehicle vectors into device vectors.
nonisolated enum MotionSynth {
    /// A small reproducible generator.
    struct Noise: Sendable {
        var state: UInt64

        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }

        mutating func gauss() -> Double {
            var s = 0.0
            // Six uniforms on (-1, 1) have a standard deviation of sqrt(2).
            for _ in 0..<6 { s += uniform() }
            return s / 2.0.squareRoot()
        }
    }

    /// A mount rotation from yaw, pitch and roll in degrees.
    static func mount(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
        let r = Double.pi / 180
        return simd_quatd(angle: yaw * r, axis: SIMD3(0, 0, 1)) * simd_quatd(angle: pitch * r, axis: SIMD3(0, 1, 0))
            * simd_quatd(angle: roll * r, axis: SIMD3(1, 0, 0))
    }

    /// One sample for vehicle-frame acceleration (m/s²) and yaw rate (rad/s, positive = left),
    /// plus an extra device rotation rate (handling) in device axes. `negate` gives the opposite
    /// accelerometer sign (userAcceleration = +a), for the test that the fit does not depend on it.
    static func sample(time: Double, long: Double, lat: Double, vert: Double, yawRate: Double, mount: simd_quatd,
                       noise: inout Noise, accNoise: Double = 0.05, gyroNoise: Double = 0.01,
                       extraRotation: SIMD3<Double> = .zero, negate: Bool = false) -> MotionSample {
        let g = 9.80665
        // Engine vibration on top of the white noise.
        let vibration = 0.02 * sin(2 * .pi * 30 * time)
        let accVehicle = SIMD3(long, lat, vert) / g
        var acc = -mount.act(accVehicle) + SIMD3(noise.gauss(), noise.gauss(), noise.gauss()) * accNoise + SIMD3(0, 0, vibration)
        if negate { acc = -acc }
        let gravity = mount.act(SIMD3<Double>(0, 0, -1))
        let rot = mount.act(SIMD3(0, 0, yawRate)) + SIMD3(noise.gauss(), noise.gauss(), noise.gauss()) * gyroNoise + extraRotation
        let q = mount.vector
        return MotionSample(time: time, userAcceleration: SIMD3<Float>(acc), gravity: SIMD3<Float>(gravity),
                            rotationRate: SIMD3<Float>(rot), attitude: SIMD4<Float>(q))
    }

    /// Samples between two fixes, from the fixes alone (the simulator's synthetic source): the
    /// longitudinal acceleration from the speed change, the lateral from speed times the course
    /// rate, gravity, noise and a few bumps.
    static func between(_ a: Fix, _ b: Fix, rateHz: Double, mount: simd_quatd, noise: inout Noise) -> [MotionSample] {
        let dt = b.time - a.time
        guard dt > 0, dt <= 5 else { return [] }
        let va = a.speed ?? 0, vb = b.speed ?? va
        let long = (vb - va) / dt
        var dc = ((b.course ?? 0) - (a.course ?? 0)).truncatingRemainder(dividingBy: 360)
        if dc > 180 { dc -= 360 }
        if dc < -180 { dc += 360 }
        // Course grows clockwise, yaw rate is positive to the left. The gyro follows the course
        // exactly (as on a real phone, so the heading check agrees with GPS); routes with corners
        // turned within one fix would give lateral accelerations no car reaches, so only the
        // accelerometer's lateral is capped at 3.5 m/s² (the fit ignores such corner targets).
        let yaw = (a.course != nil && b.course != nil) ? -dc * .pi / 180 / dt : 0
        var out: [MotionSample] = []
        let n = Int(dt * rateHz)
        // A jolt is an 80 ms half-sine of 6 m/s² (a pothole as the phone feels it, not one sample).
        let joltSamples = max(2, Int(0.08 * rateHz))
        var jolt = -1
        for k in 0..<n {
            let t = a.time + Double(k) / rateHz
            let v = va + (vb - va) * Double(k) / Double(max(1, n))
            if jolt < 0, noise.uniform() > 0.9998, v > 3 { jolt = 0 }
            var bump = 0.0
            if jolt >= 0 {
                bump = 6 * sin(.pi * Double(jolt) / Double(joltSamples))
                jolt = jolt + 1 < joltSamples ? jolt + 1 : -1
            }
            out.append(sample(time: t, long: long, lat: max(-3.5, min(3.5, v * yaw)), vert: bump, yawRate: yaw, mount: mount, noise: &noise))
        }
        return out
    }
}
#endif
