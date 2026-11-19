import Foundation
import simd
import Testing
@testable import Spur

/// The review of the motion sensor: every finding with a synthetic input that
/// contains the real-world effect (mount vibration, swivel, grade, the device sign convention,
/// clock steps, failing writes).
struct MotionReviewTests {
    typealias Phase = MotionTests.Phase
    static let t = MotionTests.self

    /// A decaying 8 Hz mount wobble after every bump, as a suction cup or vent arm rings.
    static func addWobble(_ s: inout MotionTests.Scenario, amplitude: Double, hz: Double = 8, seconds: Double = 0.6) {
        for bt in s.bumpTimes {
            for i in s.samples.indices where s.samples[i].time >= bt - 0.05 && s.samples[i].time <= bt + seconds {
                let u = s.samples[i].time - bt
                let w = amplitude * exp(-u / (seconds / 3)) * sin(2 * .pi * hz * u)
                s.samples[i].rotationRate += SIMD3<Float>(Float(w), 0, 0)
            }
        }
    }

    static func summary(_ s: MotionTests.Scenario) -> MotionAnalyzer.Output {
        MotionAnalyzer.analyze(samples: s.samples, fixes: s.fixes)
    }

    // MARK: 1 handling on rotation, not rate

    @Test(arguments: [0.6, 1.0, 1.7])
    func aBumpWithMountWobbleStillCounts(_ amplitude: Double) {
        var s = Self.t.build(Self.t.standard())
        Self.addWobble(&s, amplitude: amplitude)
        let m = Self.summary(s).summary
        print("REVIEW wobble \(amplitude): bumps \(m.counts.bumps), segments \(m.segments), aligned \(m.alignedSegments), handling \(m.handlingShare ?? -1)")
        #expect(m.counts.bumps == 2)
        #expect(m.segments == 2 && m.alignedSegments == 2)
    }

    @Test(arguments: [0.2, 0.3])
    func gyroRoadVibrationLeavesTheTripAligned(_ sd: Double) {
        var s = Self.t.build(Self.t.standard())
        var noise = MotionSynth.Noise(state: 5)
        for i in s.samples.indices {
            s.samples[i].rotationRate += SIMD3<Float>(Float(noise.gauss() * sd), Float(noise.gauss() * sd), 0)
        }
        let m = Self.summary(s).summary
        print("REVIEW gyro vibration std \(sd): handling \(m.handlingShare ?? -1), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0)")
        #expect((m.handlingShare ?? 1) < 0.1)
        #expect(m.alignedSegments == 2)
        #expect(m.counts.hardBraking == 1 && m.counts.bumps == 2)
    }

    // MARK: 2 hysteresis, merging, gaps

    @Test func aBrakeAtTheThresholdCountsOnceOverTwentySeeds() {
        var counts: [Int: Int] = [:]
        for seed in 0..<20 {
            let phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
                + [Phase(seconds: 5), Phase(seconds: 4, long: -3.1), Phase(seconds: 5)]
            let m = Self.summary(Self.t.build(phases, seed: UInt64(seed + 1))).summary
            counts[m.counts.hardBraking, default: 0] += 1
        }
        print("REVIEW threshold brake, hard braking count over 20 seeds: \(counts.sorted { $0.key < $1.key })")
        #expect(counts == [1: 20])
    }

    @Test func aSensorGapNeverJoinsTwoBlipsIntoABrake() {
        var phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
        phases += [Phase(seconds: 5), Phase(seconds: 0.2, long: -4), Phase(seconds: 3)]
        var s = Self.t.build(phases)
        let t0 = s.samples[0].time
        let blipEnd = 5 + 6 + 10 + 32 + 5 + 0.2
        s.samples.removeAll { $0.time - t0 > blipEnd && $0.time - t0 < blipEnd + 2 }
        let blip = s.samples.first { $0.time - t0 > blipEnd - 0.1 }!
        for i in s.samples.indices where s.samples[i].time - t0 >= blipEnd + 2 && s.samples[i].time - t0 < blipEnd + 2.15 {
            s.samples[i].userAcceleration = blip.userAcceleration
        }
        let m = Self.summary(s).summary
        #expect(m.sensorGaps == 1)
        #expect(m.counts.hardBraking == 0, "0.2 s and 0.15 s on either side of a 2 s gap are no brake")
    }

    // MARK: 3 swivel about the vertical, turning at a stop

    @Test(arguments: [45.0, 60.0])
    func aSwivelAboutTheVerticalIsANewMount(_ degrees: Double) {
        let phases = Self.t.standard().map { $0.remount ? Phase(seconds: 1.5, swivel: degrees) : $0 }
        let out = Self.summary(Self.t.build(phases))
        let m = out.summary
        print("REVIEW swivel \(degrees): segments \(m.segments), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0), right \(m.counts.lateralRight), good \(m.alignmentGood)")
        #expect(m.segments == 2 && m.alignedSegments == 2)
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.3)
        #expect(m.counts == MotionSummary.Counts(hardBraking: 1, veryHardBraking: 1, hardAcceleration: 1, lateralLeft: 1, lateralRight: 1, bumps: 2),
                "no false lateral event at the straight stop")
    }

    @Test func aPhoneTurnedAtAStopIsHandlingAndANewMount() {
        let phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 6, long: -2), Phase(seconds: 3), Phase(seconds: 2, swivel: 90), Phase(seconds: 3),
               Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 5), Phase(seconds: 2, long: -6), Phase(seconds: 5)]
        let m = Self.summary(Self.t.build(phases)).summary
        print("REVIEW turned at a stop: segments \(m.segments), aligned \(m.alignedSegments), handling \(m.handlingShare ?? -1), braking \(m.maxBraking ?? 0)")
        #expect(m.segments == 2 && m.alignedSegments == 2)
        #expect((m.handlingShare ?? 0) > 0)
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.4)
    }

    // MARK: 6 partial alignment and scale

    @Test func aScaleErrorIsFlagged() {
        var s = Self.t.build(Self.t.standard())
        for i in s.samples.indices { s.samples[i].userAcceleration *= 0.7 }
        let m = Self.summary(s).summary
        print("REVIEW userAcceleration x0.7: gains \(m.gains ?? []), r_long \(m.rLong ?? -9), good \(m.alignmentGood)")
        #expect((m.gains ?? []).allSatisfy { abs($0 - 0.7) < 0.05 })
        #expect(!m.gainsOK && !m.alignmentGood, "r stays 0.99, so only the gain shows the error")
    }

    @Test func partialAlignmentIsVisible() {
        // The second mount sees no excitation: cruise and a gentle stop.
        let phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 5), Phase(seconds: 1.5, remount: true), Phase(seconds: 60), Phase(seconds: 6, long: -2), Phase(seconds: 3)]
        let m = Self.summary(Self.t.build(phases)).summary
        print("REVIEW partial: aligned \(m.alignedSegments) of \(m.segments), share \(m.alignedShare ?? -1), good \(m.alignmentGood)")
        #expect(m.segments == 2 && m.alignedSegments == 1)
        #expect((m.alignedShare ?? 1) < 0.7)
        #expect(!m.alignmentGood)
        #expect(MotionDynamicsSection.alignmentLine(m).contains("1 von 2 Abschnitten"))
    }

    // MARK: 7 sign conventions

    @Test func leftTurnsLandOnTheLeftAndRYawConfirmsTheSign() {
        // Asymmetric turns: a short sharp left, then a longer right.
        let phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
            + [Phase(seconds: 3, yaw: 0.32), Phase(seconds: 6), Phase(seconds: 6, yaw: -0.3), Phase(seconds: 6)]
        let s = Self.t.build(phases)
        let out = Self.summary(s)
        let t0 = s.samples[0].time
        let leftStart = 5.0 + 6 + 10 + 32
        let left = out.details.events.filter { $0.kind == .lateralLeft }.map { $0.peakTime - t0 }
        let right = out.details.events.filter { $0.kind == .lateralRight }.map { $0.peakTime - t0 }
        print("REVIEW turns: left at \(left), right at \(right), r_yaw \(out.summary.rYaw ?? -9)")
        #expect(left.count == 1 && left.allSatisfy { $0 >= leftStart && $0 <= leftStart + 3.5 })
        #expect(right.count == 1 && right.allSatisfy { $0 >= leftStart + 9 && $0 <= leftStart + 15.5 })
        #expect((out.summary.rYaw ?? 0) > 0.9)
        #expect(out.summary.yawSwapped == nil)
    }

    @Test func aNegatedGravityIsCaughtByRYawAndLeftStaysLeft() {
        var s = Self.t.build(Self.t.standard())
        for i in s.samples.indices { s.samples[i].gravity = -s.samples[i].gravity }
        let out = Self.summary(s)
        let m = out.summary
        let left = out.details.events.first { $0.kind == .lateralLeft }?.peakTime ?? 0
        let right = out.details.events.first { $0.kind == .lateralRight }?.peakTime ?? 0
        print("REVIEW gravity negated: r_yaw \(m.rYaw ?? -9), swapped \(m.yawSwapped ?? false), left \(left - s.samples[0].time), right \(right - s.samples[0].time)")
        #expect((m.rYaw ?? 0) < -0.5 && m.yawSwapped == true)
        #expect(!m.alignmentGood)
        #expect(left > 0 && right > 0 && left < right, "the left turn comes first in the standard drive")
    }

    @Test func theDeviceSignGivesUpwardVertical() throws {
        let s = Self.t.build(Self.t.standard())
        let frame = MotionAnalyzer.vehicleFrame(samples: s.samples, fixes: s.fixes)
        let bump = try #require(s.bumpTimes.first)
        let near = s.samples.indices.filter { abs(s.samples[$0].time - bump) < 0.02 }
        let peak = near.map { frame.vert[$0] }.max() ?? 0
        #expect(peak > 5, "the bump pushes up at +7 m/s², read through userAcceleration = -a")
    }

    @Test func aGyroSignErrorIsAReflectionAndNeverAligned() {
        var s = Self.t.build(Self.t.standard())
        for i in s.samples.indices { s.samples[i].rotationRate = -s.samples[i].rotationRate }
        let m = Self.summary(s).summary
        print("REVIEW gyro negated: reflected \(m.reflected), aligned \(m.alignedSegments), r_yaw \(m.rYaw ?? -9)")
        #expect(m.reflected && m.alignedSegments == 0, "a winning reflection means a sign bug: not aligned")
        #expect(m.maxBraking == nil && m.counts.bumps == 2)
    }

    // MARK: 8 grade

    @Test func gradeDoesNotSplitTheMount() {
        let g = 6.0
        let phases = [Phase(seconds: 5, grade: g), Phase(seconds: 4, long: 2.8, grade: g), Phase(seconds: 10, grade: g)]
            + Self.t.excitation().map { var p = $0; p.grade = g; return p }
            + [Phase(seconds: 40, grade: -g), Phase(seconds: 4, yaw: 0.3, grade: -g), Phase(seconds: 5, grade: -g),
               Phase(seconds: 11.2 / 6, long: -6, grade: -g), Phase(seconds: 5, grade: -g)]
        let m = Self.summary(Self.t.build(phases)).summary
        print("REVIEW grade +6/-6: segments \(m.segments), aligned \(m.alignedSegments), braking \(m.maxBraking ?? 0)")
        #expect(m.segments == 1 && m.alignedSegments == 1)
        #expect(abs((m.maxBraking ?? 0) - -6) <= 0.4 && m.counts.hardBraking == 1)
    }

    // MARK: 17 lag range

    @Test func aTwoSecondGPSLatencyIsFoundAndAThreeAndAHalfIsFlagged() {
        let two = Self.summary(Self.t.build(Self.t.standard(), gpsLatency: 2)).summary
        print("REVIEW latency 2 s: lag \(two.lagSeconds ?? 9), r_long \(two.rLong ?? -9), boundary \(two.lagAtBoundary ?? false)")
        #expect(abs((two.lagSeconds ?? 9) - -2) <= 0.21 && (two.rLong ?? 0) >= 0.9 && two.lagAtBoundary == nil)
        let far = Self.summary(Self.t.build(Self.t.standard(), gpsLatency: 3.5)).summary
        #expect(far.lagAtBoundary == true)
    }

    // MARK: 18 roughness bandwidth and speed

    /// A drive at constant speed with a vertical road signal (2 to 12 Hz) independent of the rate.
    static func roughRoad(rate: Double, speed: Double) -> MotionTests.Scenario {
        let phases = [Phase(seconds: 5), Phase(seconds: speed / 2, long: 2), Phase(seconds: 60)]
        var s = MotionTests.build(phases, rate: rate)
        let mount = MotionTests.q1
        let t0 = s.samples[0].time
        // The road shakes only while the car moves (not in the first 5 s standing).
        for i in s.samples.indices where s.samples[i].time - t0 > 5 {
            let t = s.samples[i].time
            let road = 1.2 * sin(2 * .pi * 3 * t) + 0.9 * sin(2 * .pi * 7.3 * t + 1) + 0.6 * sin(2 * .pi * 11.1 * t + 2)
            s.samples[i].userAcceleration -= SIMD3<Float>(mount.act(SIMD3<Double>(0, 0, road / 9.80665)))
        }
        return s
    }

    @Test func roughnessAgreesAtFiftyAndAHundredHertz() {
        let a = Self.summary(Self.roughRoad(rate: 100, speed: 10)).details.stretches
        let b = Self.summary(Self.roughRoad(rate: 50, speed: 10)).details.stretches
        let ra = a.map(\.rms).reduce(0, +) / Double(max(1, a.count)), rb = b.map(\.rms).reduce(0, +) / Double(max(1, b.count))
        print("REVIEW roughness 100 Hz \(ra) (\(a.count) stretches), 50 Hz \(rb) (\(b.count))")
        #expect(a.count >= 4 && b.count >= 4)
        #expect(abs(ra - rb) / ra < 0.05)
        #expect(Set(a.map(\.roughness)) == Set(b.map(\.roughness)))
    }

    @Test func roughnessIsNormalisedToFiftyKilometresAnHour() {
        let slow = Self.summary(Self.roughRoad(rate: 100, speed: 50 / 3.6)).details.stretches
        let fast = Self.summary(Self.roughRoad(rate: 100, speed: 100 / 3.6)).details.stretches
        let rs = slow.map(\.rms).reduce(0, +) / Double(max(1, slow.count)), rf = fast.map(\.rms).reduce(0, +) / Double(max(1, fast.count))
        // The same vertical signal at twice the speed reads lower by the square root of 2.
        #expect(abs(rf / rs - 1 / 2.0.squareRoot()) < 0.05)
        #expect(slow.allSatisfy { $0.speed != nil })
    }

    // MARK: 5 chart

    @Test func theChartIsBoundedFlushedAndBreaksAtGaps() {
        var phases = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Self.t.excitation()
        for _ in 0..<60 { phases += [Phase(seconds: 10, long: 0.6), Phase(seconds: 10, long: -0.6)] }
        var s = Self.t.build(phases, rate: 25)
        let t0 = s.samples[0].time, end = s.samples[s.samples.count - 1].time
        s.samples.removeAll { $0.time - t0 > 600 && $0.time - t0 < 660 } // a minute without samples
        let d = Self.summary(s).details
        let step = d.seriesStep ?? 0
        print("REVIEW chart: \(d.seriesTime.count) buckets of \(step) s over \(end - t0) s")
        #expect(step > 0 && d.seriesTime.count <= MotionConstants.chartColumns + 1)
        #expect((d.seriesTime.last ?? 0) > end - 2 * step, "the last bucket is flushed")
        let holes = zip(d.seriesTime, d.seriesTime.dropFirst()).filter { $1 - $0 > 1.5 * step }
        #expect(holes.count == 1, "the gap leaves a hole the chart breaks at")
    }

    // MARK: the simulator's source on a route with instant corners

    @Test func instantCornersNeitherSplitTheMountNorBendTheFit() {
        // 1 Hz fixes of a square route: stop-and-go speed, the course turning 90° within one fix
        // every 20 s (as simulated routes do); motion from the fixes alone, as in the simulator.
        var fixes: [Fix] = []
        var v = 0.0, course = 0.0, lat = 32.78, lon = -96.80
        for k in 0..<400 {
            let phase = k % 20
            v = max(0, min(14, v + (phase < 8 ? 1.2 : (phase < 14 ? -1.2 : 0))))
            if phase == 19 { course = (course + 90).truncatingRemainder(dividingBy: 360) }
            lat += v * cos(course * .pi / 180) / 111_195
            lon += v * sin(course * .pi / 180) / (111_195 * cos(32.78 * .pi / 180))
            fixes.append(Fix(timestampMs: Int64((1_794_420_000 + Double(k)) * 1000), latitude: lat, longitude: lon,
                             horizontalAccuracy: 5, speed: v + 3, speedAccuracy: 0.3, course: course))
        }
        var noise = MotionSynth.Noise(state: 9)
        let mount = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)
        let samples = zip(fixes, fixes.dropFirst()).flatMap { MotionSynth.between($0, $1, rateHz: 100, mount: mount, noise: &noise) }
        let m = MotionAnalyzer.analyze(samples: samples, fixes: fixes).summary
        print("REVIEW instant corners: segments \(m.segments), aligned \(m.alignedSegments), gains \(m.gains ?? []), r_yaw \(m.rYaw ?? -9)")
        #expect(m.segments == 1 && m.alignedSegments == 1)
        #expect(m.gainsOK && (m.rYaw ?? 0) > 0.9 && m.alignmentGood)
    }

    // MARK: 24 noise

    @Test func theSynthNoiseHasUnitStandardDeviation() {
        var noise = MotionSynth.Noise(state: 1)
        var sum = 0.0, sq = 0.0
        for _ in 0..<200_000 {
            let g = noise.gauss()
            sum += g
            sq += g * g
        }
        let sd = (sq / 200_000 - pow(sum / 200_000, 2)).squareRoot()
        #expect(abs(sd - 1) < 0.02)
    }

    // MARK: 4, 11, 15, 25 the file

    static func samples(_ count: Int, from t0: Double, rate: Double = 100) -> [MotionSample] {
        (0..<count).map { k in
            MotionSample(time: t0 + Double(k) / rate, userAcceleration: SIMD3(0, 0, 0.01), gravity: SIMD3(0, 0, -1),
                         rotationRate: .zero, attitude: SIMD4(0, 0, 0, 1))
        }
    }

    @Test func aPartialWriteIsRolledBackSoTheRestStaysAligned() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        let w = try MotionFileWriter(url: url, rateHz: 100)
        try w.append(Self.samples(100, from: 1000))
        w.writeHook = { handle, data in
            try handle.write(contentsOf: data.prefix(137)) // the disk filled part-way
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #expect(throws: CocoaError.self) { try w.append(Self.samples(100, from: 1001)) }
        w.writeHook = nil
        try w.append(Self.samples(100, from: 1002))
        w.close()
        let file = try #require(MappedMotionFile(url: url))
        #expect(file.count == 200 && file.truncatedBytes == 0 && file.rejected == 0)
        #expect(file.time(100) == 1002 && file.time(199) == 1002.99)
    }

    @Test func aShortHeaderFileIsRepairedAndAResumeKeepsTheFileRate() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x53, 0x50, 0x55, 0x52, 1, 2, 3]))
        let w = try MotionFileWriter(url: url, rateHz: 50)
        try w.append(Self.samples(10, from: 1000, rate: 50))
        w.close()
        let file = try #require(MappedMotionFile(url: url))
        #expect(file.count == 10 && file.header.rateHz == 50)
        // A resume with the setting now at 100 Hz keeps the file's 50 Hz.
        let resumed = try MotionFileWriter(url: url, rateHz: 100)
        #expect(resumed.rateHz == 50)
        resumed.close()
    }

    @Test func aClockStepBackKeepsTheFileMonotonic() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        let w = try MotionFileWriter(url: url, rateHz: 100)
        try w.append(Self.samples(100, from: 1000))
        try w.append(Self.samples(100, from: 1000.3)) // the wall clock stepped back 0.7 s
        w.close()
        let file = try #require(MappedMotionFile(url: url))
        #expect(file.count == 200 && file.rejected == 0)
        #expect((1..<200).allSatisfy { file.time($0) > file.time($0 - 1) })
        #expect(abs((file.time(199) - file.time(100)) - 0.99) < 1e-6, "the batch's spacing is kept")
    }

    @Test func implausibleRecordsAreSkippedOnReading() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        let w = try MotionFileWriter(url: url, rateHz: 100)
        try w.append(Self.samples(50, from: 1000))
        // Written by an older build: time running backwards, then far outside the trip.
        try w.appendRaw(MotionFile.encode(Self.samples(10, from: 999)))
        try w.appendRaw(MotionFile.encode(Self.samples(10, from: 9_000_000)))
        try w.appendRaw(MotionFile.encode(Self.samples(20, from: 1001)))
        w.close()
        let file = try #require(MappedMotionFile(url: url, window: 900...1100))
        #expect(file.count == 70 && file.rejected == 20)
        #expect((1..<file.count).allSatisfy { file.time($0) > file.time($0 - 1) })
    }

    // MARK: 4, 16, 27 the recorder

    final class StallingSource: MotionSource, @unchecked Sendable {
        var starts = 0
        var isAvailable: Bool { true }
        func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) { starts += 1 }
        func stop() {}
    }

    @Test func aStalledDeliveryIsRestartedAndCounted() {
        let recorder = MotionRecorder()
        let source = StallingSource()
        let t0 = Date(timeIntervalSince1970: 1000)
        recorder.start(url: Fixtures.tempDir().appendingPathComponent(MotionFile.fileName), rateHz: 100, source: source, now: t0)
        #expect(!recorder.checkStall(now: t0.addingTimeInterval(10)))
        #expect(recorder.checkStall(now: t0.addingTimeInterval(15)))
        #expect(source.starts == 2 && recorder.currentHealth.restarts == 1)
        recorder.stop()
    }

    @Test func anOpenFailureIsReported() {
        let url = Fixtures.tempDir().appendingPathComponent("missing", isDirectory: true).appendingPathComponent(MotionFile.fileName)
        let recorder = MotionRecorder()
        let told = Locked<[String]>([])
        recorder.onProblem = { text in told.mutate { $0.append(text) } }
        #expect(!recorder.start(url: url, rateHz: 100, source: StallingSource()))
        #expect(recorder.currentHealth.openFailed)
        #expect(told.value.count == 1 && told.value[0].contains("ohne Sensordaten"))
    }

    final class ScriptedSource: MotionSource, @unchecked Sendable {
        var deliver: (@Sendable ([MotionSample]) -> Void)?
        var isAvailable: Bool { true }
        func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) { self.deliver = deliver }
        func stop() {}
    }

    @Test func repeatedWriteFailuresStopMotionAndSaySo() throws {
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        let recorder = MotionRecorder()
        let told = Locked<[String]>([])
        recorder.onProblem = { text in told.mutate { $0.append(text) } }
        let source = ScriptedSource()
        #expect(recorder.start(url: url, rateHz: 100, source: source))
        source.deliver?(Self.samples(100, from: 1000))
        recorder.setWriteHookForTesting { handle, data in
            try handle.write(contentsOf: data.prefix(61))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        for k in 1...3 { source.deliver?(Self.samples(100, from: 1000 + Double(k))) }
        _ = recorder.samplesWritten // waits for the writer queue
        let health = recorder.currentHealth
        #expect(health.writeFailures == 3 && health.gaveUp)
        #expect(told.value.count == 1 && told.value[0].contains("gestoppt"))
        recorder.stop()
        let file = try #require(MappedMotionFile(url: url))
        #expect(file.count == 100 && file.truncatedBytes == 0, "every failed batch was rolled back")
    }

    @Test func startAndStopStayShortOnTheCallingThread() {
        let recorder = MotionRecorder()
        let url = Fixtures.tempDir().appendingPathComponent(MotionFile.fileName)
        var worst = 0.0
        for _ in 0..<5 {
            let a = Date()
            recorder.start(url: url, rateHz: 100, source: StallingSource())
            let b = Date()
            recorder.stop()
            worst = max(worst, b.timeIntervalSince(a), Date().timeIntervalSince(b))
        }
        print("REVIEW recorder start/stop on the calling thread: worst \(String(format: "%.1f", worst * 1000)) ms")
        #expect(worst < 0.05)
    }
}

/// A value shared with a `@Sendable` callback in tests.
nonisolated final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
