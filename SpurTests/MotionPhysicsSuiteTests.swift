import Foundation
import simd
import Testing
@testable import Spur

/// The physics reviewer's experiment table (review rounds 1 to 3), as a regression suite:
/// the reviewer's own generator and inputs, every row with its expected result and a tolerance.
/// Any change to `MotionAnalysis.swift` must keep this suite green. Each row prints one
/// "PHYSICS" line, the table of the final report.
struct MotionPhysicsSuiteTests {
    // MARK: The reviewer's generator (v3run/main.swift), verbatim apart from the namespace.

    struct Phase {
        var seconds: Double
        var long = 0.0
        var yaw = 0.0
        var bump = false
        var remount = false
        var swivel = 0.0
        var wobble = 0.0
        var grade = 0.0
    }

    struct Scenario {
        var samples: [MotionSample] = []
        var fixes: [Fix] = []
        var bumpTimes: [Double] = []
        /// The vehicle's true longitudinal and lateral acceleration per sample (the reviewer's
        /// live round, for SPEC 17.3).
        var truthLong: [Double] = []
        var truthLat: [Double] = []
    }

    static let q1 = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)
    static let q2 = MotionSynth.mount(yaw: -120, pitch: -40, roll: 25)

    static func excitation() -> [Phase] { (0..<4).flatMap { _ in [Phase(seconds: 4, long: 1.2), Phase(seconds: 4, long: -1.2)] } }

    static func standard(remount: [Phase] = [Phase(seconds: 1.5, remount: true)]) -> [Phase] {
        [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + excitation() + [
            Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5),
            Phase(seconds: 0.1, bump: true), Phase(seconds: 5)] + remount + [Phase(seconds: 5)] + excitation() + [
            Phase(seconds: 4, yaw: 0.15), Phase(seconds: 3), Phase(seconds: 4, yaw: -0.15), Phase(seconds: 3),
            Phase(seconds: 0.1, bump: true), Phase(seconds: 4), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
    }

    static func dur(_ ph: [Phase]) -> Double { ph.reduce(0) { $0 + $1.seconds } }

    /// `courseNoise` K: GPS course noise of K / max(v, 3) + 0.5 degrees (the reviewer's live round 2;
    /// 0 leaves every other output unchanged).
    static func build(_ phases: [Phase], seed: UInt64 = 7, rate: Double = 100, gpsNoise: Double = 0.1, gpsLatency: Double = 0.3,
                      courseNoise: Double = 0) -> Scenario {
        var out = Scenario()
        var noise = MotionSynth.Noise(state: seed)
        let t0 = 1_794_420_000.0
        var t = t0, v = 0.0, heading = 0.0, lat = 32.78, lon = -96.80
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
                    mount = simd_slerp(startMount, target, Double(k + 1) / Double(n))
                    if p.remount { extra = SIMD3(1.2, -0.8, 0.5) } else { extra = mount.act(SIMD3(0, 0, p.swivel * .pi / 180 / p.seconds)) }
                }
                if p.wobble > 0 && p.bump { extra += SIMD3(p.wobble * sin(2 * .pi * 8 * Double(k) / rate), 0, 0) }
                let pitch = simd_quatd(angle: p.grade * .pi / 180, axis: SIMD3(0, 1, 0))
                var s = MotionSynth.sample(time: t, long: long, lat: v * yaw, vert: vert, yawRate: yaw, mount: mount, noise: &noise, extraRotation: extra)
                if p.grade != 0 { s.gravity = SIMD3<Float>(mount.act(pitch.inverse.act(SIMD3<Double>(0, 0, -1)))) }
                out.samples.append(s)
                out.truthLong.append(long)
                out.truthLat.append(v * yaw)
                truth.append((t, v, heading, lat, lon))
                v = max(0, v + long * dt)
                heading += yaw * dt
                lat += v * dt * cos(heading) / 111_195
                lon += v * dt * sin(-heading) / (111_195 * cos(32.78 * .pi / 180))
                t += dt
            }
        }
        var k = 0
        var gn = MotionSynth.Noise(state: seed &+ 99)
        var ft = t0
        while ft < t {
            let delayed = max(t0, ft - gpsLatency)
            while k + 1 < truth.count && truth[k + 1].t <= delayed { k += 1 }
            let s = truth[k]
            var cdeg = -s.heading * 180 / .pi
            let speed = max(0, s.v + gn.gauss() * gpsNoise)
            if courseNoise > 0 { cdeg += gn.gauss() * (courseNoise / max(s.v, 3) + 0.5) }
            let course = (cdeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            out.fixes.append(Fix(timestampMs: Int64(ft * 1000), latitude: s.lat, longitude: s.lon, horizontalAccuracy: 5,
                                 speed: speed, speedAccuracy: 0.3, course: s.v > 1 ? course : nil))
            ft += 1
        }
        return out
    }

    static func addWobble(_ s: inout Scenario, amplitude: Double, hz: Double = 8, seconds: Double = 0.6) {
        for bt in s.bumpTimes {
            for i in s.samples.indices where s.samples[i].time >= bt - 0.05 && s.samples[i].time <= bt + seconds {
                let u = s.samples[i].time - bt
                let w = amplitude * exp(-u / (seconds / 3)) * sin(2 * .pi * hz * u)
                s.samples[i].rotationRate += SIMD3<Float>(Float(w), 0, 0)
            }
        }
    }

    /// A physically consistent change of the mount from `q1` to `target` over `T` seconds.
    static func applyMount(_ s: inout Scenario, start: Double, seconds T: Double, to target: simd_quatd) {
        let t0 = s.samples[0].time
        let r = target * q1.inverse
        let omega = -(r.angle / T) * r.axis
        for i in s.samples.indices {
            let u = s.samples[i].time - t0 - start
            let q = simd_slerp(q1, target, min(1, max(0, u / T)))
            let m = q * q1.inverse
            s.samples[i].userAcceleration = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].userAcceleration)))
            s.samples[i].gravity = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].gravity)))
            s.samples[i].rotationRate = SIMD3<Float>(m.act(SIMD3<Double>(s.samples[i].rotationRate)))
            if u >= 0 && u < T { s.samples[i].rotationRate += SIMD3<Float>(m.act(omega)) }
        }
    }

    /// The standard drive with a mount change after the first bump (the reviewer's remountScenario).
    static func mountChange(seconds T: Double, to target: (simd_quatd) -> simd_quatd, gpsNoise: Double = 0.1) -> Scenario {
        var phases = standard(remount: [])
        let idx = phases.firstIndex { $0.bump }! + 2
        phases.insert(Phase(seconds: T), at: idx)
        var s = build(phases, gpsNoise: gpsNoise)
        applyMount(&s, start: dur(Array(phases[..<idx])), seconds: T, to: target(q1))
        return s
    }

    static func tilt(_ deg: Double, _ axis: SIMD3<Double> = SIMD3(0, 1, 0)) -> (simd_quatd) -> simd_quatd {
        { $0 * simd_quatd(angle: deg * .pi / 180, axis: axis) }
    }

    static func motorway(remount: Bool, changes: Int = 40, straight: Double = 20, half: Double = 1.5) -> [Phase] {
        var ph = [Phase(seconds: 5), Phase(seconds: 12, long: 2.5)]
        if remount { ph += [Phase(seconds: 20), Phase(seconds: 1.5, remount: true), Phase(seconds: 5)] }
        for _ in 0..<changes { ph += [Phase(seconds: straight), Phase(seconds: half, yaw: 0.04), Phase(seconds: half, yaw: -0.04)] }
        return ph
    }

    static func winding(_ count: Int) -> [Phase] {
        (0..<count).map { k in Phase(seconds: 4, long: k % 3 == 0 ? 0.6 : (k % 3 == 1 ? -0.6 : 0), yaw: k % 2 == 0 ? 0.12 : -0.1) }
    }

    static func addBias(_ s: inout Scenario, _ bias: Double) {
        for i in s.samples.indices {
            let g = SIMD3<Double>(s.samples[i].gravity)
            s.samples[i].rotationRate += SIMD3<Float>(-g / simd_length(g) * bias)
        }
    }

    // MARK: Reporting

    @discardableResult
    static func run(_ name: String, _ s: Scenario) -> MotionAnalyzer.Output {
        let o = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes)
        let m = o.summary
        func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "nil" }
        print("PHYSICS \(name): seg \(m.segments) al \(m.alignedSegments) share \(f(m.alignedShare)) rFit \(f(m.rFit))\(m.rFitLateralOnly == true ? " (lat)" : "") good \(m.alignmentGood) lag \(f(m.lagSeconds)) refl \(m.reflected) brk \(f(m.maxBraking)) acc \(f(m.maxAcceleration)) L \(f(m.maxLateralLeft)) R \(f(m.maxLateralRight)) hs \(f(m.handlingShare)) gains \(m.gains ?? []) rYaw \(f(m.rYaw)) swapped \(m.yawSwapped ?? false) counts b\(m.counts.hardBraking)/a\(m.counts.hardAcceleration)/L\(m.counts.lateralLeft)/R\(m.counts.lateralRight)/jolt\(m.counts.bumps) rough m \(m.roughnessMeters.map { Int($0) })")
        return o
    }

    static func near(_ x: Double?, _ y: Double, _ tol: Double) -> Bool { x.map { abs($0 - y) <= tol } ?? false }

    /// Seed offsets for the rows that depend on noise (final physics review, R2): each claim is
    /// the minimum over all three.
    static let seedOffsets: [UInt64] = [0, 1000, 2000]

    /// Metres in any class above glatt.
    static func rougherThanSmooth(_ m: MotionSummary) -> Int { Int(m.roughnessMeters[1...].reduce(0, +)) }

    static let standardCounts = MotionSummary.Counts(hardBraking: 1, veryHardBraking: 1, hardAcceleration: 1, lateralLeft: 1, lateralRight: 1, bumps: 2)

    // MARK: Conventions and gains

    @Test func conventions() {
        let base = Self.build(Self.standard())
        let a = Self.run("A baseline", base).summary
        #expect(a.segments == 2 && a.alignedSegments == 2 && a.alignmentGood && a.counts == Self.standardCounts)
        #expect(Self.near(a.maxBraking, -6, 0.3) && Self.near(a.maxLateralLeft, 3.36, 0.4) && Self.near(a.maxLateralRight, -3.36, 0.4) && (a.rYaw ?? 0) > 0.9)

        var g = base
        for i in g.samples.indices { g.samples[i].gravity = -g.samples[i].gravity }
        let bOut = Self.run("B gravity negated", g)
        let b = bOut.summary
        let left = bOut.details.events.first { $0.kind == .lateralLeft }?.peakTime ?? 0
        let right = bOut.details.events.first { $0.kind == .lateralRight }?.peakTime ?? 0
        #expect(b.yawSwapped == true && (b.rYaw ?? 0) < -0.9 && !b.alignmentGood && left > 0 && left < right)

        var r = base
        for i in r.samples.indices { r.samples[i].rotationRate = -r.samples[i].rotationRate }
        let c = Self.run("C rotationRate negated", r).summary
        #expect(c.reflected && c.alignedSegments == 0 && c.counts.bumps == 2)

        var u = base
        for i in u.samples.indices { u.samples[i].userAcceleration = -u.samples[i].userAcceleration }
        let d = Self.run("D userAcceleration = +a", u).summary
        #expect(d.alignedSegments == 2 && d.counts == Self.standardCounts && Self.near(d.maxBraking, -6, 0.3))
    }

    @Test(arguments: [0.7, 0.8, 1.25])
    func gains(_ k: Double) {
        var s = Self.build(Self.standard())
        for i in s.samples.indices { s.samples[i].userAcceleration *= Float(k) }
        let m = Self.run("E userAcceleration x\(k)", s).summary
        #expect((m.gains ?? []).allSatisfy { abs($0 - k) < 0.04 } && !(m.gains ?? []).isEmpty)
        #expect(!m.gainsOK && !m.alignmentGood && Self.near(m.maxBraking, -6 * k, 0.35))
    }

    @Test(arguments: [0.0, 1.0, 2.0])
    func speedSmoothing(_ tau: Double) {
        let extra = [Phase(seconds: 3), Phase(seconds: 3, long: 2.5), Phase(seconds: 4), Phase(seconds: 2, long: -4), Phase(seconds: 4),
                     Phase(seconds: 2.5, long: 3), Phase(seconds: 4), Phase(seconds: 2, long: -4.5), Phase(seconds: 6)]
        var s = Self.build(Self.standard() + extra)
        if tau > 0 {
            var y = s.fixes[0].speed ?? 0
            for k in s.fixes.indices {
                y += ((s.fixes[k].speed ?? 0) - y) / (tau + 1)
                s.fixes[k].speed = y
            }
        }
        let m = Self.run("P GPS speed smoothed tau \(tau) s", s).summary
        #expect(m.alignedSegments == 2 && m.gainsOK && m.alignmentGood)
    }

    // MARK: Mounts

    @Test(arguments: [12.0, 15.0, 20.0, 30.0, 45.0, 60.0])
    func fastSwivel(_ deg: Double) {
        let m = Self.run("F swivel \(deg) deg in 1.5 s", Self.build(Self.standard(remount: [Phase(seconds: 1.5, swivel: deg)]))).summary
        #expect(m.segments == 2 && m.alignedSegments == 2 && m.alignmentGood && m.counts == Self.standardCounts && Self.near(m.maxBraking, -6, 0.3))
    }

    @Test(arguments: [(1.5, 0.0), (4.0, 0.0), (8.0, 0.0), (15.0, 0.0)])
    func slowRemount(_ c: (Double, Double)) {
        let m = Self.run("T remount to q2 over \(c.0) s", Self.mountChange(seconds: c.0, to: { _ in Self.q2 })).summary
        #expect(m.alignedSegments >= 2 && Self.near(m.maxBraking, -6, 0.4) && m.counts.hardBraking == 1)
    }

    @Test(arguments: [(40.0, 1.5), (40.0, 6.0), (20.0, 4.0), (30.0, 4.0), (40.0, 3.0)])
    func slowSwivel(_ c: (Double, Double)) {
        let m = Self.run("T2 swivel \(c.0) deg over \(c.1) s", Self.mountChange(seconds: c.1, to: Self.tilt(c.0, SIMD3(0, 0, 1)))).summary
        #expect(m.segments == 2 && m.alignedSegments == 2 && Self.near(m.maxBraking, -6, 0.35) && m.counts.hardBraking == 1)
    }

    @Test(arguments: [(25.0, 1.5), (25.0, 8.0), (40.0, 2.0), (40.0, 3.0), (60.0, 4.0)])
    func slowTilt(_ c: (Double, Double)) {
        let m = Self.run("T3 tilt \(c.0) deg over \(c.1) s", Self.mountChange(seconds: c.1, to: Self.tilt(c.0))).summary
        #expect(Self.near(m.maxBraking, -6, 0.35) && m.counts.hardBraking == 1 && m.alignedSegments == m.segments)
    }

    @Test(arguments: [6.0, 10.0])
    func grade(_ g: Double) {
        let ph = [Phase(seconds: 5, grade: g), Phase(seconds: 4, long: 2.8, grade: g), Phase(seconds: 10, grade: g)]
            + Self.excitation().map { var p = $0; p.grade = g; return p }
            + [Phase(seconds: 40, grade: -g), Phase(seconds: 4, yaw: 0.3, grade: -g), Phase(seconds: 5, grade: -g),
               Phase(seconds: 11.2 / 6, long: -6, grade: -g), Phase(seconds: 5, grade: -g)]
        let m = Self.run("H grade +\(g)/-\(g)", Self.build(ph)).summary
        #expect(m.segments == 1 && m.alignedSegments == 1 && Self.near(m.maxBraking, -6, 0.35))
    }

    @Test(arguments: [(2.0, 0), (1.0, 0), (3.0, 1)])
    func redLightRemount(_ c: (Double, Int)) {
        let before = [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.excitation()
            + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 11.2 / 3, long: -3)]
        let after = [Phase(seconds: 5, long: 2), Phase(seconds: 10)] + Self.excitation()
            + [Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5), Phase(seconds: 0.1, bump: true), Phase(seconds: 4), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
        var s = Self.build(before + [Phase(seconds: 8)] + after)
        Self.applyMount(&s, start: Self.dur(before) + 2, seconds: c.0, to: c.1 == 0 ? Self.q2 : MotionSynth.mount(yaw: 90, pitch: -20, roll: 0))
        let m = Self.run("Z remount at a red light over \(c.0) s", s).summary
        #expect(m.segments == 2 && m.alignedSegments == 2 && Self.near(m.maxBraking, -6, 0.4))
    }

    @Test(arguments: [2.0, 0.5])
    func phoneTurnedAtARedLight(_ lead: Double) {
        let before = [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.excitation()
            + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 11.2 / 3, long: -3)]
        let after = [Phase(seconds: 5, long: 2), Phase(seconds: 10)] + Self.excitation()
            + [Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
        var s = Self.build(before + [Phase(seconds: 8)] + after)
        Self.applyMount(&s, start: Self.dur(before) + 8 - lead - 1.0, seconds: 1.0, to: Self.q1 * simd_quatd(angle: 60 * .pi / 180, axis: SIMD3(0, 0, 1)))
        let m = Self.run("FE phone turned 60 deg at a red light \(lead) s before pulling away", s).summary
        #expect(m.segments == 2 && m.alignedSegments == 2 && Self.near(m.maxBraking, -6, 0.4))
    }

    // MARK: Motorway

    @Test(arguments: [0.05, 0.1, 0.2, 0.3])
    func motorwayLaneChanges(_ noise: Double) {
        let m = Self.run("O motorway lane changes, noise \(noise)", Self.build(Self.motorway(remount: false), gpsNoise: noise)).summary
        #expect(m.alignedSegments == 1 && (m.rFit ?? 0) >= 0.95 && m.alignmentGood && m.yawSwapped == nil)
    }

    @Test(arguments: [0.05, 0.1, 0.2, 0.3])
    func motorwayRemount(_ noise: Double) {
        let m = Self.run("O2 motorway remount, lane changes, noise \(noise)", Self.build(Self.motorway(remount: true), gpsNoise: noise)).summary
        #expect(m.segments == 2 && m.alignedSegments == 1 && (m.alignedShare ?? 0) > 0.9 && m.yawSwapped == nil)
    }

    @Test(arguments: [(0.3, 0.3), (0.3, 0.1), (0.2, 0.05)])
    func motorwayUnderReportedSpeedAccuracy(_ c: (Double, Double)) {
        var s = Self.build(Self.motorway(remount: true), gpsNoise: c.0)
        for k in s.fixes.indices { s.fixes[k].speedAccuracy = c.1 }
        let m = Self.run("X motorway remount, speed noise \(c.0) reported \(c.1)", s).summary
        #expect(m.alignedSegments == 1 && (m.alignedShare ?? 0) > 0.9)
    }

    @Test(arguments: [(20.0, 2.5), (30.0, 3.0), (45.0, 4.0)])
    func motorwaySlowTilt(_ c: (Double, Double)) {
        var ph: [Phase] = [Phase(seconds: 5), Phase(seconds: 12, long: 2.5)]
        for _ in 0..<40 { ph += [Phase(seconds: 18), Phase(seconds: 1.5, yaw: 0.04), Phase(seconds: 1.5, yaw: -0.04)] }
        var s = Self.build(ph, gpsNoise: 0.2)
        Self.applyMount(&s, start: 17 + 20 * 21 + 5, seconds: c.1, to: Self.q1 * simd_quatd(angle: c.0 * .pi / 180, axis: SIMD3(0, 1, 0)))
        let m = Self.run("Y motorway, slow tilt \(c.0) deg over \(c.1) s mid-leg", s).summary
        #expect(m.alignedSegments == m.segments && m.alignmentGood)
    }

    // The axis goes in as an index: a SIMD3 test argument crashes Swift Testing's async thunk
    // ("freed pointer was not the last allocation" in swift_task_dealloc).
    @Test(arguments: [(0, 30.0, 3.0), (0, 45.0, 4.0), (1, 30.0, 3.0)])
    func motorwayTiltThenExit(_ arg: (Int, Double, Double)) {
        let c = (arg.0 == 0 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0), arg.1, arg.2)
        var ph: [Phase] = [Phase(seconds: 5), Phase(seconds: 12, long: 2.5)]
        for _ in 0..<20 { ph += [Phase(seconds: 18), Phase(seconds: 1.5, yaw: 0.04), Phase(seconds: 1.5, yaw: -0.04)] }
        ph += [Phase(seconds: 30 / 5, long: -5), Phase(seconds: 3), Phase(seconds: 4, long: 2), Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5)]
        var s = Self.build(ph, gpsNoise: 0.2)
        Self.applyMount(&s, start: 17 + 10 * 21 + 5, seconds: c.2, to: Self.q1 * simd_quatd(angle: c.1 * .pi / 180, axis: c.0))
        let m = Self.run("FA motorway tilt \(c.1) deg about \(c.0.x == 1 ? "x" : "y") over \(c.2) s, exit brake -5", s).summary
        #expect(m.alignedSegments == m.segments && Self.near(m.maxBraking, -5, 0.4) && m.counts.hardBraking == 1)
    }

    // MARK: Lag

    @Test(arguments: [1.5, 2.0, 2.5, 3.0])
    func latency(_ l: Double) {
        let m = Self.run("L GPS latency \(l) s", Self.build(Self.standard(), gpsLatency: l)).summary
        #expect(m.alignedSegments == 2 && Self.near(m.lagSeconds, -l, 0.21) && Self.near(m.maxBraking, -6, 0.3) && m.counts == Self.standardCounts)
    }

    @Test func latencyBeyondTheSearchIsFlagged() {
        let m = Self.run("L GPS latency 3.5 s", Self.build(Self.standard(), gpsLatency: 3.5)).summary
        #expect(m.lagAtBoundary == true)
    }

    @Test(arguments: [(0.3, 0.3), (0.3, 0.5), (1.5, 0.3), (1.5, 0.5)])
    func pullAwaysIntoTurns(_ c: (Double, Double)) {
        var ph: [Phase] = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.excitation()
        for _ in 0..<6 { ph += [Phase(seconds: 12 / 4, long: -4), Phase(seconds: 4), Phase(seconds: 3, long: 1.5, yaw: c.1), Phase(seconds: 3, long: 1.5), Phase(seconds: 5)] }
        let m = Self.run("U 6 pull-aways into a \(c.1) rad/s turn, latency \(c.0)", Self.build(ph, gpsLatency: c.0)).summary
        #expect(m.segments == 1 && m.alignedSegments == 1 && m.counts.hardBraking == 6)
        // The turn data survive (the version 2 bug erased them): left turns read 4.5 m/s times the
        // yaw rate on the left, and nothing comparable on the right.
        #expect(Self.near(m.maxLateralLeft, 4.5 * c.1, 0.25) && (m.maxLateralRight ?? 0) > -0.6 && (m.rLat ?? 0) >= 0.85,
                "left \(m.maxLateralLeft ?? 0), right \(m.maxLateralRight ?? 0), r_lat \(m.rLat ?? -9)")
    }

    // MARK: Hands, vibration of the mount

    @Test func loosePhone() {
        var phases: [Phase] = [Phase(seconds: 5), Phase(seconds: 4, long: 2), Phase(seconds: 5)] + Self.excitation()
        for _ in 0..<10 { phases += [Phase(seconds: 4), Phase(seconds: 0.6)] }
        var s = Self.build(phases)
        var noise = MotionSynth.Noise(state: 3)
        var t = s.samples[0].time
        var hts: [ClosedRange<Double>] = []
        for (i, p) in phases.enumerated() {
            if i >= 3 + 8 && p.seconds == 0.6 { hts.append(t...(t + p.seconds)) }
            t += p.seconds
        }
        for i in s.samples.indices where hts.contains(where: { $0.contains(s.samples[i].time) }) {
            s.samples[i].userAcceleration.x += Float(-8 / 9.80665 + noise.uniform() * 0.2)
            s.samples[i].rotationRate += SIMD3<Float>(2, -1.5, 1)
        }
        let m = Self.run("loose phone", s).summary
        #expect(m.counts.hardBraking == 0 && (m.handlingShare ?? 0) > 0.1)
    }

    @Test(arguments: [(15.0, 0.5, 0.0), (45.0, 0.2, 0.0), (30.0, 0.3, 0.8), (60.0, 0.4, 0.5)])
    func cupholderTurnInABrake(_ c: (Double, Double, Double)) {
        let pre = [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.excitation()
            + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 4, yaw: -0.3), Phase(seconds: 5)]
        let brake = 11.2 / 6
        let post = [Phase(seconds: c.2, long: -6), Phase(seconds: c.1, long: -6, swivel: c.0), Phase(seconds: brake - c.2 - c.1, long: -6),
                    Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 20)] + Self.excitation() + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 20)]
        let m = Self.run("Cup \(c.0) deg in \(c.1) s at +\(c.2) s into a -6 brake", Self.build(pre + post.filter { $0.seconds > 0 })).summary
        #expect(m.counts.hardBraking == 1 && (m.maxBraking ?? 0) <= -5.5, "one stop, one event")
    }

    @Test(arguments: [(0.6, 8.0), (1.0, 8.0), (1.7, 8.0), (1.0, 3.0), (1.5, 2.0), (3.0, 8.0)])
    func mountWobble(_ c: (Double, Double)) {
        var s = Self.build(Self.standard())
        Self.addWobble(&s, amplitude: c.0, hz: c.1)
        let m = Self.run("G wobble \(c.0) rad/s at \(c.1) Hz", s).summary
        #expect(m.segments == 2 && m.alignedSegments == 2 && m.counts == Self.standardCounts)
    }

    @Test(arguments: [0.2, 0.3, 0.6])
    func gyroNoise(_ sd: Double) {
        var s = Self.build(Self.standard())
        var nz = MotionSynth.Noise(state: 5)
        for i in s.samples.indices { s.samples[i].rotationRate += SIMD3<Float>(Float(nz.gauss() * sd), Float(nz.gauss() * sd), 0) }
        let m = Self.run("G2 gyro noise std \(sd)", s).summary
        #expect(m.alignedSegments == 2 && m.counts.hardBraking == 1 && Self.near(m.maxBraking, -6, 0.3))
    }

    // MARK: Event counting

    @Test(arguments: [(-3.1, 4.0), (-3.05, 4.0), (-3.2, 2.0), (-3.4, 6.0)])
    func thresholdBrakeOverTwentySeeds(_ c: (Double, Double)) {
        var hist: [Int: Int] = [:]
        for seed in 0..<20 {
            let ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.excitation() + [Phase(seconds: 5), Phase(seconds: c.1, long: c.0), Phase(seconds: 5)]
            let s = Self.build(ph, seed: UInt64(seed + 1))
            hist[MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary.counts.hardBraking, default: 0] += 1
        }
        print("PHYSICS brake \(c.0) for \(c.1) s, hard braking count over 20 seeds: \(hist.sorted { $0.key < $1.key })")
        #expect(hist == [1: 20])
    }

    @Test func modulatedBrakeOverTwentySeeds() {
        var hist: [Int: Int] = [:]
        for seed in 0..<20 {
            var ph = [Phase(seconds: 5), Phase(seconds: 8, long: 2), Phase(seconds: 10)] + Self.excitation() + [Phase(seconds: 5)]
            for k in 0..<50 { ph.append(Phase(seconds: 0.1, long: -3.5 + 0.8 * sin(2 * .pi * 0.8 * Double(k) / 10))) }
            ph.append(Phase(seconds: 5))
            let s = Self.build(ph, seed: UInt64(seed + 1))
            hist[MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary.counts.hardBraking, default: 0] += 1
        }
        print("PHYSICS modulated brake -3.5 +- 0.8 at 0.8 Hz, count over 20 seeds: \(hist.sorted { $0.key < $1.key })")
        #expect(hist == [1: 20])
    }

    @Test(arguments: [(0.45, 1, 0), (0.6, 0, 1), (2.0, 0, 1)])
    func blipsAroundAHole(_ c: (Double, Int, Int)) {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.excitation()
        ph += [Phase(seconds: 5), Phase(seconds: 0.2, long: -4), Phase(seconds: 3)]
        var s = Self.build(ph)
        let t0 = s.samples[0].time
        let blipEnd = 5 + 6 + 10 + 32 + 5 + 0.2
        s.samples.removeAll { $0.time - t0 > blipEnd && $0.time - t0 < blipEnd + c.0 }
        let blip = s.samples.first { $0.time - t0 > blipEnd - 0.1 }!
        for i in s.samples.indices where s.samples[i].time - t0 >= blipEnd + c.0 && s.samples[i].time - t0 < blipEnd + c.0 + 0.15 {
            s.samples[i].userAcceleration = blip.userAcceleration
        }
        let m = Self.run("blips at -4 around a \(c.0) s hole", s).summary
        #expect(m.counts.hardBraking == c.1 && m.sensorGaps == c.2, "a hole under 0.5 s is no sensor gap; above it never bridges")
    }

    // MARK: Drift

    @Test(arguments: [0.0, 0.001, 0.002])
    func biasOnAWindingRoadWithStraights(_ bias: Double) {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 20)] + Self.excitation() + [Phase(seconds: 20)]
        ph += Self.winding(120)
        ph += [Phase(seconds: 30)] + Self.excitation() + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 10), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
        var s = Self.build(ph)
        if bias != 0 { Self.addBias(&s, bias) }
        let m = Self.run("N2 gyro bias \(bias) rad/s, 8 min winding road", s).summary
        #expect(m.segments == 1 && m.counts.hardBraking == 1 && Self.near(m.maxBraking, -6, 0.35))
    }

    @Test(arguments: [(0.0005, 2), (0.0005, 4), (0.0005, 8), (0.001, 2), (0.001, 4), (0.001, 8)])
    func biasOnAWindingRoadWithoutStraights(_ c: (Double, Int)) {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 20)] + Self.excitation() + [Phase(seconds: 20)]
        ph += Self.winding(c.1 * 15)
        ph += [Phase(seconds: 30)] + Self.excitation() + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 10), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
        var s = Self.build(ph)
        Self.addBias(&s, c.0)
        let m = Self.run("Drift bias \(c.0) rad/s, \(c.1) min winding without straights", s).summary
        #expect(m.segments == 1 && m.counts.hardBraking == 1 && m.alignedSegments == 1 && (m.handlingShare ?? 1) < 0.1)
    }

    @Test(arguments: [0.0, 0.001])
    func fastSwivelInsideADriftingWindingRoad(_ bias: Double) {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 20)] + Self.excitation() + [Phase(seconds: 20)]
        ph += Self.winding(60)
        let mid = Self.dur(ph)
        ph += Self.winding(60)
        ph += [Phase(seconds: 30)] + Self.excitation() + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 10), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 5)]
        var s = Self.build(ph)
        Self.addBias(&s, bias)
        Self.applyMount(&s, start: mid, seconds: 1.5, to: Self.q1 * simd_quatd(angle: 45 * .pi / 180, axis: SIMD3(0, 0, 1)))
        let m = Self.run("FB 45 deg swivel mid winding road, bias \(bias)", s).summary
        #expect(m.segments == 2 && Self.near(m.maxBraking, -6, 0.4))
    }

    // MARK: Turn sign

    @Test(arguments: [1.5, 2.0])
    func yawCheckNeverSwapsACorrectMotorwayTrip(_ half: Double) {
        var swapped = 0, rMin = 9.0
        for seed in 1...20 {
            let s = Self.build(Self.motorway(remount: true, straight: 18, half: half), seed: UInt64(seed * 13), gpsNoise: 0.3)
            let m = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary
            if m.yawSwapped == true { swapped += 1 }
            rMin = min(rMin, m.rYaw ?? 9)
        }
        print("PHYSICS r_yaw, motorway remount, lane changes \(half)+\(half) s, noise 0.3, 20 seeds: swapped \(swapped), min r_yaw \(String(format: "%.2f", rMin))")
        #expect(swapped == 0)
    }

    @Test(arguments: [(1.5, 0.1, 0.3, 7), (1.5, 0.3, 0.3, 8), (2.0, 0.2, 1.0, 9), (3.0, 0.2, 0.3, 10), (1.5, 0.2, 1.5, 11), (2.5, 0.3, 1.0, 12)])
    func laneChangeVariations(_ c: (Double, Double, Double, Int)) {
        let s = Self.build(Self.motorway(remount: true, straight: 18, half: c.0), seed: UInt64(c.3), gpsNoise: c.1, gpsLatency: c.2)
        let m = Self.run("Lanes remount, change \(c.0)+\(c.0) s, noise \(c.1), latency \(c.2)", s).summary
        #expect(m.alignedSegments >= 1 && m.yawSwapped == nil)
    }

    @Test(arguments: [7, 21, 35])
    func negatedGravityOnLaneChangesIsCaught(_ seed: Int) {
        var s = Self.build(Self.motorway(remount: false, straight: 18, half: 2), seed: UInt64(seed), gpsNoise: 0.2)
        for i in s.samples.indices { s.samples[i].gravity = -s.samples[i].gravity }
        let m = Self.run("FF gravity negated, lane changes only, seed \(seed)", s).summary
        #expect(m.yawSwapped == true)
    }

    // MARK: Jolts, vibration, roughness

    static func jolts(rate: Double, ms: Double, peak: Double, seedOffset: UInt64 = 0) -> Int {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)]
        for _ in 0..<5 { ph += [Phase(seconds: 3), Phase(seconds: ms / 1000, bump: true)] }
        ph.append(Phase(seconds: 3))
        var s = build(ph, seed: 7 &+ seedOffset, rate: rate)
        let t0 = s.samples[0].time
        var bt: [Double] = []
        var acc = 0.0
        for p in ph {
            if p.bump { bt.append(acc) }
            acc += p.seconds
        }
        for i in s.samples.indices {
            let u = s.samples[i].time - t0
            guard let b = bt.first(where: { u >= $0 - 1e-6 && u < $0 + ms / 1000 - 1e-6 }) else { continue }
            let k = (u - b) * rate, n = max(1, (ms / 1000 * rate).rounded())
            let v7 = 7 * sin(.pi * k / n)
            let g = SIMD3<Double>(s.samples[i].gravity)
            s.samples[i].userAcceleration += SIMD3<Float>(g * ((peak / 7 - 1) * v7) / 9.80665)
        }
        return MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary.counts.bumps
    }

    /// The documented claim for a jolt cell: the measured minimum over the three seeds (final
    /// physics review, R2), rows 30/40/50/80/100 ms, columns 5/6/8/10/15 m/s².
    static let joltMinima: [Double: [Double: [Int]]] = [
        100: [30: [0, 3, 5, 5, 5], 40: [3, 5, 5, 5, 5], 50: [5, 5, 5, 5, 5], 80: [5, 5, 5, 5, 5], 100: [5, 5, 5, 5, 5]],
        50: [30: [2, 2, 4, 4, 5], 40: [0, 1, 5, 5, 5], 50: [5, 5, 5, 5, 5], 80: [5, 5, 5, 5, 5], 100: [4, 5, 5, 5, 5]],
    ]

    static func joltClaim(rate: Double, ms: Double, peak: Double) -> Int {
        let column = [5.0, 6.0, 8.0, 10.0, 15.0].firstIndex(of: peak) ?? 0
        return joltMinima[rate]?[ms]?[column] ?? 5
    }

    @Test(arguments: [100.0, 50.0])
    func shortJolts(_ rate: Double) {
        var table = "PHYSICS jolts found of 5 at \(Int(rate)) Hz, minimum over seed offsets 0/1000/2000, rows ms, columns peak 5/6/8/10/15 m/s²:"
        var failures: [String] = []
        for ms in [30.0, 40.0, 50.0, 80.0, 100.0] {
            table += "\n   \(Int(ms)) ms:"
            for peak in [5.0, 6.0, 8.0, 10.0, 15.0] {
                let counts = Self.seedOffsets.map { Self.jolts(rate: rate, ms: ms, peak: peak, seedOffset: $0) }
                let found = counts.min() ?? 0
                table += " \(found)"
                print("PHYSICS JOLTSEED \(Int(rate)) Hz \(Int(ms)) ms \(peak): \(counts)")
                let need = Self.joltClaim(rate: rate, ms: ms, peak: peak)
                if found < need || (counts.max() ?? 0) > 5 { failures.append("\(Int(ms)) ms, \(peak): \(counts)") }
            }
        }
        print(table)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test(arguments: [0.12, 0.2])
    func clusteredJolts(_ gap: Double) {
        var ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)]
        for _ in 0..<5 { ph += [Phase(seconds: gap), Phase(seconds: 0.08, bump: true)] }
        ph += [Phase(seconds: 5), Phase(seconds: 0.08, bump: true), Phase(seconds: 3)]
        var s = Self.build(ph)
        let t0 = s.samples[0].time
        var bt: [Double] = []
        var acc = 0.0
        for p in ph {
            if p.bump { bt.append(acc) }
            acc += p.seconds
        }
        for i in s.samples.indices {
            let u = s.samples[i].time - t0
            guard let b = bt.first(where: { u >= $0 - 1e-6 && u < $0 + 0.08 - 1e-6 }) else { continue }
            let v7 = 7 * sin(.pi * (u - b) * 100 / 8)
            s.samples[i].userAcceleration += SIMD3<Float>(SIMD3<Double>(s.samples[i].gravity) * ((6.0 / 7 - 1) * v7) / 9.80665)
        }
        let m = Self.run("FC five 80 ms jolts \(gap) s apart, then one alone", s).summary
        #expect(m.counts.bumps == 2, "the cluster merges within 1 s")
    }

    @Test func speedBumpAtThirtyKilometresAnHour() {
        var s = Self.build([Phase(seconds: 5), Phase(seconds: 4, long: 2.1), Phase(seconds: 10)] + Self.excitation() + [Phase(seconds: 6)] + Self.excitation() + [Phase(seconds: 10)])
        let tb = s.samples[0].time + 60.0
        for i in s.samples.indices {
            let u = s.samples[i].time - tb
            guard u > -0.1 && u < 1.0 else { continue }
            let pitchDeg = 4 * (exp(-pow((u - 0.12) / 0.08, 2)) - exp(-pow((u - 0.45) / 0.08, 2)))
            let dpitch = 4 * (-2 * (u - 0.12) / 0.0064 * exp(-pow((u - 0.12) / 0.08, 2)) + 2 * (u - 0.45) / 0.0064 * exp(-pow((u - 0.45) / 0.08, 2))) * .pi / 180
            let heave = 6 * (exp(-pow((u - 0.1) / 0.04, 2)) + exp(-pow((u - 0.43) / 0.04, 2)) - 0.5 * exp(-pow((u - 0.25) / 0.06, 2)))
            let pitch = simd_quatd(angle: pitchDeg * .pi / 180, axis: SIMD3(0, 1, 0))
            s.samples[i].gravity = SIMD3<Float>(Self.q1.act(pitch.inverse.act(SIMD3<Double>(0, 0, -1))))
            s.samples[i].rotationRate += SIMD3<Float>(Self.q1.act(SIMD3(0, dpitch, 0)))
            s.samples[i].userAcceleration += SIMD3<Float>(-Self.q1.act(SIMD3(0, 0, heave)) / 9.80665)
        }
        let m = Self.run("Q speed bump at 30 km/h", s).summary
        #expect(m.counts.bumps == 1 && m.segments == 1)
    }

    // Engine vibration on a road whose only vertical input is the scenario's real jolts: the one
    // counted jolt, no false ones, and the roughness of the same drive without vibration, class by
    // class, at 100 and 50 Hz and over three seeds (final physics review, R1 and R2). The measured
    // exception: at 50 Hz, 0.2 g at 45 Hz aliases to 5 Hz, inside the road band, and adds up to
    // 100 m of "normal" (never "uneben").
    @Test(arguments: [(0.1, 30.0), (0.15, 30.0), (0.2, 30.0), (0.15, 45.0), (0.2, 45.0), (0.3, 30.0)])
    func engineVibrationMakesNoFalseJoltsOrRoughness(_ c: (Double, Double)) {
        for rate in [100.0, 50.0] {
            for offset in Self.seedOffsets {
                let phases = [Phase(seconds: 5), Phase(seconds: 4, long: 2.8), Phase(seconds: 10)] + Self.excitation()
                    + [Phase(seconds: 4, yaw: 0.3), Phase(seconds: 5), Phase(seconds: 11.2 / 6, long: -6), Phase(seconds: 20), Phase(seconds: 6, long: 1),
                       Phase(seconds: 60), Phase(seconds: 0.1, bump: true), Phase(seconds: 10)]
                var s = Self.build(phases, seed: 7 &+ offset, rate: rate)
                let base = MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes).summary
                for i in s.samples.indices {
                    let t = s.samples[i].time
                    s.samples[i].userAcceleration += SIMD3<Float>(Float(c.0 * sin(2 * .pi * c.1 * t)), Float(c.0 * sin(2 * .pi * c.1 * t + 1.1)), Float(c.0 * sin(2 * .pi * c.1 * t + 2.3)))
                }
                let m = Self.run("V engine vibration \(c.0) g per axis at \(c.1) Hz, \(Int(rate)) Hz, seed +\(offset), without vibration \(base.roughnessMeters.map { Int($0) })", s).summary
                #expect(m.counts.bumps == 1, "only the real jolt (\(Int(rate)) Hz, seed +\(offset))")
                let allowance = rate == 50 && c.1 == 45 && c.0 >= 0.2 ? 100 : 0
                let extra = Self.rougherThanSmooth(m) - Self.rougherThanSmooth(base)
                #expect(extra >= 0 && extra <= allowance && m.roughnessMeters[2...] == base.roughnessMeters[2...],
                        "as without vibration (\(Int(rate)) Hz, seed +\(offset)): \(m.roughnessMeters) against \(base.roughnessMeters)")
                if rate == 100 { #expect(Self.rougherThanSmooth(m) == 0, "glatt at 100 Hz (seed +\(offset)): \(m.roughnessMeters)") }
            }
        }
    }

    @Test(arguments: [0.3, 0.35, 0.4, 0.45])
    func verticalVibrationMakesNoJoltsOrRoughness(_ amp: Double) {
        for rate in [100.0, 50.0] {
            for offset in Self.seedOffsets {
                var s = Self.build([Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 60)], seed: 7 &+ offset, rate: rate)
                for i in s.samples.indices {
                    let t = s.samples[i].time
                    s.samples[i].userAcceleration += SIMD3<Float>(SIMD3<Double>(s.samples[i].gravity) * amp * sin(2 * .pi * 30 * t))
                }
                let m = Self.run("V2 vertical 30 Hz vibration \(amp) g, \(Int(rate)) Hz, seed +\(offset)", s).summary
                #expect(m.counts.bumps == 0, "no jolt (\(Int(rate)) Hz, seed +\(offset))")
                // At 100 Hz every metre is glatt. At 50 Hz, 30 Hz aliases onto the 20 Hz filter edge;
                // from 0.4 g the floor (2 m/s²) varies enough between stretches that one 100 m stretch
                // of 700 can read "normal" (measured: seed +1000), never "uneben".
                let allowance = rate == 50 && amp >= 0.4 ? 100 : 0
                #expect(m.roughnessMeters[0] > 0 && Self.rougherThanSmooth(m) <= allowance && m.roughnessMeters[2...].allSatisfy { $0 == 0 },
                        "glatt (\(Int(rate)) Hz, seed +\(offset)): \(m.roughnessMeters)")
            }
        }
    }

    @Test(arguments: [(5.5, false), (14.0, false), (30.0, false), (5.5, true), (14.0, true)])
    func smoothRoadReadsSmooth(_ c: (Double, Bool)) {
        for rate in [100.0, 50.0] {
            for offset in Self.seedOffsets {
                var s = Self.build([Phase(seconds: 2), Phase(seconds: c.0 / 2, long: 2), Phase(seconds: 200)], seed: 7 &+ offset, rate: rate)
                if c.1 {
                    for i in s.samples.indices {
                        let t = s.samples[i].time
                        let g = SIMD3<Double>(s.samples[i].gravity)
                        s.samples[i].userAcceleration += SIMD3<Float>(g * 0.1 * sin(2 * .pi * 30 * t))
                    }
                }
                let m = Self.run("W cruise \(c.0) m/s\(c.1 ? " with 0.1 g engine" : ""), \(Int(rate)) Hz, seed +\(offset)", s).summary
                #expect(m.roughnessMeters[0] > 0 && Self.rougherThanSmooth(m) == 0, "glatt only (\(Int(rate)) Hz, seed +\(offset)): \(m.roughnessMeters)")
            }
        }
    }

    @Test func idleOnlyEngineShakeKeepsARoughRoadRough() {
        var uneben: [Double] = []
        for idleG in [0.0, 0.15, 0.3] {
            var ph: [Phase] = [Phase(seconds: 20), Phase(seconds: 7, long: 2), Phase(seconds: 60), Phase(seconds: 7, long: -2), Phase(seconds: 20),
                               Phase(seconds: 7, long: 2), Phase(seconds: 60)]
            ph.insert(Phase(seconds: 0.01), at: 0)
            var s = Self.build(ph)
            var nz = MotionSynth.Noise(state: 77)
            let road: [(Double, Double, Double)] = (0..<12).map { _ in (2 + 10 * (nz.uniform() + 1) / 2, nz.uniform() * .pi, 0.42) }
            let t0 = s.samples[0].time
            for i in s.samples.indices {
                let t = s.samples[i].time - t0
                let g = SIMD3<Double>(s.samples[i].gravity)
                let moving = (t > 27 && t < 87) || (t > 121 && t < 188)
                var a = 0.0
                if moving { for (f, p, amp) in road { a += amp * sin(2 * .pi * f * t + p) } }
                let idle = (t < 20 || (t > 94 && t < 114)) ? idleG * 9.80665 * sin(2 * .pi * 30 * t) : 0
                s.samples[i].userAcceleration += SIMD3<Float>(g * (a + idle) / 9.80665)
            }
            let m = Self.run("Rough road, idle-only engine shake \(idleG) g", s).summary
            uneben.append(m.roughnessMeters[2] + m.roughnessMeters[3])
        }
        print("PHYSICS rough road, uneben or worse with idle shake 0/0.15/0.3 g: \(uneben.map { Int($0) }) m")
        #expect(uneben[0] >= 500 && uneben.allSatisfy { $0 >= 0.7 * uneben[0] }, "idle shake must not smooth a rough road")
    }
}
