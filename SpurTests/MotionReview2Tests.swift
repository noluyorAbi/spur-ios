import Foundation
import simd
import Testing
@testable import Spur

/// The second review of the motion sensor: the measured cases, each with
/// the effect in its input.
struct MotionReview2Tests {
    typealias Phase = MotionTests.Phase
    static let t = MotionTests.self

    static func summary(_ s: MotionTests.Scenario) -> MotionAnalyzer.Output {
        MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes)
    }

    /// The standard drive with a physically consistent change of the mount inserted after the
    /// first bump: the device frame turns from `q1` to `target(q1)` over `seconds`, and the gyro
    /// reads the matching rate (from the reviewer's driver).
    static func mountChange(seconds T: Double, to target: (simd_quatd) -> simd_quatd, speedNoise: Double = 0.1) -> MotionTests.Scenario {
        var phases = Self.t.standard().filter { !$0.remount }
        let idx = phases.firstIndex { $0.bump }! + 2
        phases.insert(Phase(seconds: T), at: idx)
        var s = Self.t.build(phases, speedNoise: speedNoise)
        let t0 = s.samples[0].time
        let start = phases[..<idx].reduce(0) { $0 + $1.seconds }
        let q1 = MotionTests.q1
        let q2 = target(q1)
        let r = q2 * q1.inverse
        let omega = -(r.angle / T) * r.axis
        for i in s.samples.indices {
            let u = s.samples[i].time - t0 - start
            let q = simd_slerp(q1, q2, min(1, max(0, u / T)))
            let m = q * q1.inverse
            s.samples[i].userAcceleration = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].userAcceleration)))
            s.samples[i].gravity = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].gravity)))
            s.samples[i].rotationRate = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].rotationRate)))
            if u >= 0 && u < T { s.samples[i].rotationRate += SIMD3<Float>(m.act(omega)) }
        }
        return s
    }

    static func tilt(_ degrees: Double) -> (simd_quatd) -> simd_quatd {
        { $0 * simd_quatd(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)) }
    }

    static func swivel(_ degrees: Double) -> (simd_quatd) -> simd_quatd {
        { $0 * simd_quatd(angle: degrees * .pi / 180, axis: SIMD3(0, 0, 1)) }
    }

    // MARK: 1 slow tilts and remounts

    @Test(arguments: [(25.0, 1.5), (40.0, 2.0), (40.0, 3.0), (60.0, 4.0)])
    func aSlowTiltOfTheMountKeepsTheBraking(_ c: (Double, Double)) {
        let m = Self.summary(Self.mountChange(seconds: c.1, to: Self.tilt(c.0))).summary
        print("REVIEW2 tilt \(c.0) deg in \(c.1) s: segments \(m.segments), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0), good \(m.alignmentGood)")
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.35, "not shrunk by cos(tilt)")
        #expect(m.counts.hardBraking == 1)
    }

    @Test(arguments: [4.0, 8.0])
    func aSlowFullRemountIsANewMount(_ seconds: Double) {
        let m = Self.summary(Self.mountChange(seconds: seconds, to: { _ in MotionTests.q2 })).summary
        print("REVIEW2 remount over \(seconds) s: segments \(m.segments), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0)")
        #expect(m.alignedSegments >= 2)
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.4)
    }

    @Test func aTenDegreeGradeChangeKeepsOneMount() {
        let g = 10.0
        let phases = [Phase(seconds: 5, grade: g), Phase(seconds: 4, long: 2.8, grade: g), Phase(seconds: 10, grade: g)]
            + Self.t.excitation().map { var p = $0; p.grade = g; return p }
            + [Phase(seconds: 40, grade: -g), Phase(seconds: 4, yaw: 0.3, grade: -g), Phase(seconds: 5, grade: -g),
               Phase(seconds: 11.2 / 6, long: -6, grade: -g), Phase(seconds: 5, grade: -g)]
        let m = Self.summary(Self.t.build(phases)).summary
        print("REVIEW2 grade +10/-10: segments \(m.segments), braking \(m.maxBraking ?? 0)")
        #expect(m.segments == 1 && abs((m.maxBraking ?? 0) - -6) <= 0.35)
    }

    // MARK: 2 motorway with lane changes only

    static func motorway(remount: Bool) -> [Phase] {
        var ph = [Phase(seconds: 5), Phase(seconds: 12, long: 2.5), Phase(seconds: 20)]
        if remount { ph += [Phase(seconds: 1.5, remount: true), Phase(seconds: 5)] }
        for _ in 0..<40 { ph += [Phase(seconds: 20), Phase(seconds: 1.5, yaw: 0.04), Phase(seconds: 1.5, yaw: -0.04)] }
        return ph
    }

    @Test(arguments: [0.1, 0.2, 0.3])
    func aMotorwayWithLaneChangesAligns(_ noise: Double) {
        let m = Self.summary(Self.t.build(Self.motorway(remount: false), speedNoise: noise)).summary
        print("REVIEW2 motorway noise \(noise): aligned \(m.alignedSegments) of \(m.segments), r_fit \(m.rFit ?? -9), lateral only \(m.rFitLateralOnly ?? false), r_yaw \(m.rYaw ?? -9)")
        #expect(m.alignedSegments == m.segments && (m.rFit ?? 0) >= 0.9)
        #expect((m.rYaw ?? 0) > 0.5, "lane changes are enough for the turn sign check")
    }

    @Test(arguments: [0.2, 0.3])
    func aRemountOnTheMotorwayAlignsBothMounts(_ noise: Double) {
        let m = Self.summary(Self.t.build(Self.motorway(remount: true), speedNoise: noise)).summary
        print("REVIEW2 motorway remount noise \(noise): aligned \(m.alignedSegments) of \(m.segments), share \(m.alignedShare ?? -1), lag \(m.lagSeconds ?? -9)")
        // The 37 s before the remount hold only 12 to 17 excited pairs (below 20): that mount stays
        // unaligned by rule; the motorway mount after it aligns on its lane changes.
        #expect(m.segments == 2 && m.alignedSegments == 1)
        #expect((m.alignedShare ?? 0) > 0.9)
        #expect(m.lagSeconds == nil && m.lagAtBoundary == nil, "no lag claimed from lane changes alone")
    }

    @Test func stopAndGoWithoutTurnsAlignsEvenWithAPessimisticSpeedAccuracy() {
        // Core Location may state 1 m/s of speed accuracy; consecutive speeds are filtered and far
        // better. The lateral alone must never veto a fit the stacked r accepts.
        let phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation() + Self.t.excitation()
            + [Phase(seconds: 5), Phase(seconds: 2, long: -6), Phase(seconds: 5)]
        var s = Self.t.build(phases)
        for k in s.fixes.indices { s.fixes[k].speedAccuracy = 1.0 }
        let m = Self.summary(s).summary
        print("REVIEW2 stop-and-go, accuracy 1 m/s: aligned \(m.alignedSegments), r_fit \(m.rFit ?? -9), lateral only \(m.rFitLateralOnly ?? false)")
        #expect(m.alignedSegments == 1 && m.rFitLateralOnly == nil && (m.rFit ?? 0) >= 0.9)
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.35)
    }

    // MARK: 3 a short swivel at a brake

    @Test func aCupholderTurnAtABrakeKeepsTheBrake() {
        let ph = [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5),
               Phase(seconds: 0.3, long: -6, swivel: 30), Phase(seconds: 11.2 / 6 - 0.3, long: -6), Phase(seconds: 5),
               Phase(seconds: 6, long: 2), Phase(seconds: 20)] + Self.t.excitation() + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 20)]
        let m = Self.summary(Self.t.build(ph)).summary
        print("REVIEW2 cupholder: segments \(m.segments), braking \(m.maxBraking ?? 0), hard \(m.counts.hardBraking), handling \(m.handlingShare ?? -1)")
        #expect(m.counts.hardBraking == 1 && (m.maxBraking ?? 0) <= -5.5)
    }

    // MARK: 4 standstill and GPS lag

    @Test(arguments: [1.5, 2.5])
    func aLaggingGPSDoesNotEraseThePullAways(_ latency: Double) {
        let m = Self.summary(Self.t.build(Self.t.standard(), gpsLatency: latency)).summary
        print("REVIEW2 latency \(latency): aligned \(m.alignedSegments), r_lat \(m.rLat ?? -9), handling \(m.handlingShare ?? -1)")
        #expect(m.alignedSegments == 2 && (m.rLat ?? 0) >= 0.9)
        #expect(m.counts.lateralLeft == 1 && m.counts.lateralRight == 1)
    }

    // MARK: 5 Core Location's speed smoothing

    @Test(arguments: [1.0, 2.0])
    func smoothedGPSSpeedIsNotAScaleError(_ tau: Double) {
        let extra = [Phase(seconds: 3), Phase(seconds: 3, long: 2.5), Phase(seconds: 4), Phase(seconds: 2, long: -4), Phase(seconds: 4),
                     Phase(seconds: 2.5, long: 3), Phase(seconds: 4), Phase(seconds: 2, long: -4.5), Phase(seconds: 6)]
        var s = Self.t.build(Self.t.standard() + extra)
        var y = s.fixes[0].speed ?? 0
        for k in s.fixes.indices {
            let x = s.fixes[k].speed ?? 0
            y += (x - y) / (tau + 1)
            s.fixes[k].speed = y
        }
        let m = Self.summary(s).summary
        print("REVIEW2 GPS smoothing tau \(tau): lateral gains \(m.gains ?? []), longitudinal \(m.gainsLong ?? []), good \(m.alignmentGood)")
        #expect(m.gainsOK, "a perfect sensor is not flagged for Core Location's smoothing")
    }

    // MARK: 6 slow swivel, gyro drift

    @Test func aSlowSwivelIsFound() {
        let m = Self.summary(Self.mountChange(seconds: 6, to: Self.swivel(40))).summary
        print("REVIEW2 swivel 40 deg in 6 s: segments \(m.segments), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0)")
        #expect(m.segments == 2 && abs((m.maxBraking ?? 0) - -6) <= 0.35)
    }

    @Test func aSlowGyroDriftOnAWindingRoadDoesNotSplit() {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
        for k in 0..<24 { ph += [Phase(seconds: 8, yaw: k % 2 == 0 ? 0.12 : -0.12), Phase(seconds: 12)] }
        var s = Self.t.build(ph)
        let bias = MotionTests.q1.act(SIMD3<Double>(0, 0, 0.001))
        for i in s.samples.indices { s.samples[i].rotationRate += SIMD3<Float>(bias) }
        let m = Self.summary(s).summary
        print("REVIEW2 gyro bias 0.001 rad/s, \(Int(ph.reduce(0) { $0 + $1.seconds })) s winding: segments \(m.segments)")
        #expect(m.segments == 1)
    }

    // MARK: 7 engine vibration

    @Test func engineVibrationMakesNoJolts() {
        var s = Self.t.build([Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 20), Phase(seconds: 6, long: 1),
               Phase(seconds: 60), Phase(seconds: 0.1, bump: true), Phase(seconds: 10)])
        var noise = MotionSynth.Noise(state: 9)
        for i in s.samples.indices {
            let t = s.samples[i].time
            s.samples[i].userAcceleration += SIMD3<Float>(Float(0.3 * sin(2 * .pi * 30 * t)), Float(0.3 * sin(2 * .pi * 30 * t + 1.1)),
                                                          Float(0.3 * sin(2 * .pi * 30 * t + 2.3)))
            s.samples[i].rotationRate += SIMD3<Float>(Float(0.4 * sin(2 * .pi * 30 * t + 0.4) + noise.gauss() * 0.02), Float(0.4 * sin(2 * .pi * 30 * t + 1.9)), 0)
        }
        let m = Self.summary(s).summary
        print("REVIEW2 engine vibration 0.3 g: jolts \(m.counts.bumps), vibration RMS \(m.vibrationRMS ?? -1)")
        #expect(m.counts.bumps == 1, "only the real jolt")
    }

    @Test func pureEngineVibrationReadsSmoothAtAnySpeed() {
        var classes: [Set<Int>] = []
        for v in [5.5, 14.0] {
            var s = Self.t.build([Phase(seconds: 8), Phase(seconds: v / 2, long: 2), Phase(seconds: 90)])
            for i in s.samples.indices {
                let t = s.samples[i].time
                s.samples[i].userAcceleration -= SIMD3<Float>(MotionTests.q1.act(SIMD3<Double>(0, 0, 0.1 * sin(2 * .pi * 30 * t))))
            }
            let d = Self.summary(s).details
            classes.append(Set(d.stretches.map(\.roughness)))
        }
        print("REVIEW2 pure vibration 0.1 g: classes at 5.5 and 14 m/s \(classes)")
        #expect(classes == [[0], [0]], "glatt at both speeds")
    }
}
