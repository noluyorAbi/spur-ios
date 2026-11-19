import Foundation
import simd
import Testing
@testable import Spur

/// SPEC 16.3.3: the motion analysis against a synthetic drive whose truth is known.
struct MotionTests {
    struct Scenario {
        var samples: [MotionSample] = []
        var fixes: [Fix] = []
        var bumpTimes: [Double] = []
        var mountChangeTime = 0.0
    }

    /// Phases: duration (s), longitudinal acceleration (m/s²), yaw rate (rad/s, + left).
    struct Phase {
        var seconds: Double
        var long = 0.0
        var yaw = 0.0
        var bump = false
        var remount = false
        var handling = false
        /// Degrees about the vertical, turned over the phase (a swivelled ball-joint mount).
        var swivel = 0.0
        /// Vehicle pitch in degrees during the phase (road grade).
        var grade = 0.0
    }

    static let q1 = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)
    static let q2 = MotionSynth.mount(yaw: -120, pitch: -40, roll: 25)

    static func excitation() -> [Phase] {
        (0..<4).flatMap { _ in [Phase(seconds: 4, long: 1.2), Phase(seconds: 4, long: -1.2)] }
    }

    /// The brief's drive: accelerate hard, cruise, excite, a left and a right turn, a bump,
    /// remount, excite again, gentle turns, a second bump, a hard brake to a stop.
    static func standard() -> [Phase] {
        [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + excitation() + [
            Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5),
            Phase(seconds: 0.1, bump: true), Phase(seconds: 5), Phase(seconds: 1.5, remount: true), Phase(seconds: 5),
        ] + excitation() + [
            Phase(seconds: 4, yaw: 0.15), Phase(seconds: 3), Phase(seconds: 4, yaw: -0.15), Phase(seconds: 3),
            Phase(seconds: 0.1, bump: true), Phase(seconds: 4), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5),
        ]
    }

    static func build(_ phases: [Phase], seed: UInt64 = 7, negate: Bool = false, gpsLatency: Double = 0.3,
                      rate: Double = 100, speedNoise: Double = 0.1) -> Scenario {
        var out = Scenario()
        var noise = MotionSynth.Noise(state: seed)
        let t0 = 1_794_420_000.0
        var t = t0, v = 0.0, heading = 0.0
        var lat = 32.78, lon = -96.80
        var truth: [(t: Double, v: Double, heading: Double, lat: Double, lon: Double)] = []
        var mount = q1
        for p in phases {
            let n = max(1, Int((p.seconds * rate).rounded()))
            let startMount = mount
            let target = p.remount ? q2 : (p.swivel != 0 ? mount * simd_quatd(angle: p.swivel * .pi / 180, axis: SIMD3(0, 0, 1)) : mount)
            for k in 0..<n {
                let dt = 1 / rate
                var long = p.long
                if v + long * dt < 0 { long = -v / dt }
                let yaw = v > 0.5 ? p.yaw : 0
                var vert = 0.0
                if p.bump {
                    vert = 7 * sin(.pi * Double(k) / Double(n))
                    if k == n / 2 { out.bumpTimes.append(t) }
                }
                var extra = SIMD3<Double>.zero
                if p.remount || p.swivel != 0 {
                    if k == 0 { out.mountChangeTime = t }
                    mount = simd_slerp(startMount, target, Double(k + 1) / Double(n))
                    // A remount turns the phone about every axis; a swivel only about the vertical. A
                    // mount turned by +φ about up turns the device frame by -φ relative to the car,
                    // so its gyro reads -rate (checked against the change of gravity).
                    extra = p.remount ? SIMD3(1.2, -0.8, 0.5) : mount.act(SIMD3(0, 0, -p.swivel * .pi / 180 / p.seconds))
                }
                var sample = MotionSynth.sample(time: t, long: long, lat: v * yaw, vert: vert, yawRate: yaw, mount: mount,
                                                noise: &noise, extraRotation: extra, negate: negate)
                if p.grade != 0 {
                    // On a grade gravity tilts against the vehicle about its lateral axis.
                    let pitch = simd_quatd(angle: p.grade * .pi / 180, axis: SIMD3(0, 1, 0))
                    sample.gravity = SIMD3<Float>(mount.act(pitch.inverse.act(SIMD3<Double>(0, 0, -1))))
                }
                out.samples.append(sample)
                truth.append((t, v, heading, lat, lon))
                v = max(0, v + long * dt)
                heading += yaw * dt
                lat += v * dt * cos(heading) / 111_195
                lon += v * dt * sin(-heading) / (111_195 * cos(32.78 * .pi / 180))
                t += dt
            }
        }
        // 1 Hz fixes reporting the speed of 0.3 s earlier, with noise.
        var k = 0
        var gpsNoise = MotionSynth.Noise(state: seed &+ 99)
        var ft = t0
        while ft < t {
            let delayed = max(t0, ft - gpsLatency)
            while k + 1 < truth.count && truth[k + 1].t <= delayed { k += 1 }
            let s = truth[k]
            let course = ((-s.heading * 180 / .pi).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            out.fixes.append(Fix(timestampMs: Int64(ft * 1000), latitude: s.lat, longitude: s.lon, horizontalAccuracy: 5,
                                 speed: max(0, s.v + gpsNoise.gauss() * speedNoise), speedAccuracy: 0.3, course: s.v > 1 ? course : nil))
            ft += 1
        }
        return out
    }

    @Test func theStandardDriveIsAlignedAndItsEventsAreExact() {
        let s = Self.build(Self.standard())
        let out = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes)
        let m = out.summary
        print("MOTION standard: segments \(m.segments), aligned \(m.alignedSegments), rLong \(m.rLong ?? -9), rLat \(m.rLat ?? -9), lag \(m.lagSeconds ?? -9), reflected \(m.reflected), braking \(m.maxBraking ?? 0), accel \(m.maxAcceleration ?? 0), left \(m.maxLateralLeft ?? 0), right \(m.maxLateralRight ?? 0), counts \(m.counts), handling \(m.handlingShare ?? -1), coverage \(m.coverage ?? -1)")
        #expect(m.segments == 2, "the remount is detected")
        #expect(m.alignedSegments == 2)
        #expect((m.rLong ?? 0) >= 0.9)
        #expect(m.alignmentGood)
        #expect(!m.reflected, "a rotation fits, not a reflection")
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.3)
        #expect(abs((m.maxLateralLeft ?? 0) - 11.2 * 0.3) <= 0.4)
        #expect(abs((m.maxLateralRight ?? 0) - -11.2 * 0.3) <= 0.4)
        #expect(m.counts == MotionSummary.Counts(hardBraking: 1, veryHardBraking: 1, hardAcceleration: 1, lateralLeft: 1, lateralRight: 1, bumps: 2))
        let bumps = out.details.events.filter { $0.kind == .bump }.map(\.peakTime)
        #expect(bumps.count == 2)
        for (found, truth) in zip(bumps, s.bumpTimes) { #expect(abs(found - truth) <= 0.2, "bump at \(found), truth \(truth)") }
        #expect(abs((m.lagSeconds ?? 9) - -0.3) <= 0.21, "GPS latency 0.3 s")
    }

    @Test func aNegatedAccelerometerGivesTheSameResults() {
        let a = MotionAnalyzer.analyze(samples: Self.build(Self.standard()).samples, fixes: Self.build(Self.standard()).fixes).summary
        let neg = Self.build(Self.standard(), negate: true)
        let b = MotionAnalyzer.analyze(samples: neg.samples, fixes: neg.fixes).summary
        #expect(b.counts == a.counts)
        #expect(abs((b.maxBraking ?? 0) - (a.maxBraking ?? 0)) < 0.05)
        #expect(!b.reflected)
    }

    @Test func aLoosePhoneMakesNoHardBraking() {
        // Cruising, with the phone picked up and shaken ten times (fast rotation, big jolts).
        var phases: [Phase] = [Phase(seconds: 5), Phase(seconds: 4, long: 2), Phase(seconds: 5)] + Self.excitation()
        for _ in 0..<10 { phases += [Phase(seconds: 4), Phase(seconds: 0.6, handling: true)] }
        var s = Self.build(phases)
        // Shaking: jolts of -8 m/s² along the device's x axis plus a fast rotation.
        var noise = MotionSynth.Noise(state: 3)
        var handlingTimes: [ClosedRange<Double>] = []
        var t = s.samples[0].time
        for p in phases {
            if p.handling { handlingTimes.append(t...(t + p.seconds)) }
            t += p.seconds
        }
        for i in s.samples.indices where handlingTimes.contains(where: { $0.contains(s.samples[i].time) }) {
            s.samples[i].userAcceleration.x += Float(-8 / 9.80665 + noise.uniform() * 0.2)
            s.samples[i].rotationRate += SIMD3<Float>(2, -1.5, 1)
        }
        let m = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary
        print("MOTION loose phone: braking events \(m.counts.hardBraking), handling share \(m.handlingShare ?? -1)")
        #expect(m.counts.hardBraking == 0)
        #expect((m.handlingShare ?? 0) > 0.1)
    }

    @Test func tooLittleExcitationLeavesTheSegmentUnaligned() {
        let s = Self.build([Phase(seconds: 5), Phase(seconds: 4, long: 2), Phase(seconds: 60), Phase(seconds: 0.1, bump: true), Phase(seconds: 5)])
        let m = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary
        #expect(m.alignedSegments == 0)
        #expect(m.maxBraking == nil)
        #expect(m.counts.bumps == 1, "bumps count without alignment")
    }

    // File

    @Test func theFileRoundTripsCutsATruncatedTailAndAppendsAfterAResume() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        let s = Self.build([Phase(seconds: 3, long: 1)]).samples
        let w = try MotionFileWriter(url: url, rateHz: 100, created: 1)
        try w.append(Array(s.prefix(150)))
        try w.appendRaw(Data([1, 2, 3, 4, 5, 6, 7])) // a crash mid-record
        w.close()
        let crashed = try #require(MotionFile.read(url))
        #expect(crashed.samples.count == 150 && crashed.truncatedBytes == 7)
        #expect(crashed.header == MotionFile.Header(version: 1, recordSize: 60, rateHz: 100, frame: 1, created: 1))
        // Resume: the tail is cut, the rest appended.
        let resumed = try MotionFileWriter(url: url, rateHz: 100)
        try resumed.append(Array(s.dropFirst(150)))
        resumed.close()
        let back = try #require(MotionFile.read(url))
        #expect(back.truncatedBytes == 0)
        #expect(back.samples == s)
        let perHour = MotionFile.bytesPerHour(rateHz: 100)
        let measured = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int - MotionFile.headerSize) * 360_000 / s.count
        print("MOTION bytes per hour at 100 Hz: \(perHour) (measured from the file: \(measured))")
        #expect(perHour == 21_600_000 && measured == perHour)
    }
}
