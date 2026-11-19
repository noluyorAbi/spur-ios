import Foundation
import simd
import Testing
@testable import Spur

/// SPEC 17.3: the live estimator against the trip analysis on the physics suite's drives.
struct LiveMotionTests {
    typealias Suite = MotionPhysicsSuiteTests

    struct Replay {
        var readings: [LiveMotionEstimator.Reading] = []
        /// Per refresh: its time, the last sample it read, and its summary.
        var checkpoints: [(time: Double, written: Double, summary: MotionSummary)] = []
        var estimator = LiveMotionEstimator()
    }

    /// Streams the drive through the estimator as the app would: samples and fixes as they come,
    /// a refresh every `every` seconds (and at the `extra` seconds from the start) on the samples
    /// written so far (`fileLag` seconds behind the stream) and the fixes so far. `refreshUntil`
    /// stops refreshing (to test the fast path alone). `every == 0`: the estimator's own policy
    /// (`refreshDue`) with `cost` seconds per refresh.
    static func replay(_ sc: Suite.Scenario, every: Double = 10, extra: [Double] = [], fileLag: Double = 0.5,
                       refreshUntil: Double = .infinity, cost: Double = 0) -> Replay {
        var r = Replay()
        let t0 = sc.samples[0].time
        var nextFix = 0
        var nextRefresh = t0 + every
        var pending = extra.sorted().map { t0 + $0 }
        var last: Double?
        for (i, s) in sc.samples.enumerated() {
            r.estimator.append([s])
            while nextFix < sc.fixes.count && sc.fixes[nextFix].time <= s.time {
                r.estimator.append(fix: sc.fixes[nextFix])
                nextFix += 1
            }
            var due = false
            if every > 0 {
                if s.time >= nextRefresh { nextRefresh += every; due = true }
            } else if s.time - t0 > 1 {
                due = r.estimator.refreshDue(now: s.time, lastRefresh: last, lastDuration: cost)
            }
            if let p = pending.first, s.time >= p { pending.removeFirst(); due = true }
            if due && s.time - t0 <= refreshUntil {
                last = s.time
                let written = Array(sc.samples[..<(sc.samples[...i].lastIndex { $0.time <= s.time - fileLag } ?? 0)])
                r.estimator.refresh(source: written, allFixes: Array(sc.fixes[..<nextFix]), now: Date(timeIntervalSince1970: s.time))
                if let summary = r.estimator.solution?.output.summary {
                    r.checkpoints.append((s.time, written.last?.time ?? t0, summary))
                }
            }
            if let reading = r.estimator.reading { r.readings.append(reading) }
        }
        return r
    }

    /// The trip analysis's 2 Hz longitudinal over the whole drive.
    static func final(_ sc: Suite.Scenario) -> (time: [Double], long: [Float]) {
        let live = MotionAnalyzer.live(source: sc.samples, fixes: sc.fixes, now: Date(), recentSeconds: 1e9)
        return (live.recentTime, live.recentLong)
    }

    static func index(_ time: [Double], _ t: Double) -> Int {
        var lo = 0, hi = time.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if time[mid] <= t { lo = mid } else { hi = mid }
        }
        return abs(time[hi] - t) < abs(time[lo] - t) ? hi : lo
    }

    struct Agreement {
        var name: String
        var firstAligned: Double?
        var shownShare: Double
        var flaps: Int
        var wrong: Int
        var wrongShare: Double
        /// Seconds of shown values more than 0.6 m/s² off the truth (an old orientation).
        var offSeconds: Double
        var worst: Double
        var peakDrift: Double
        var countsAtStop: Bool
        var line: String {
            let f = { (x: Double?) in x.map { String(format: "%.1f", $0) } ?? "never" }
            return "LIVE \(name): first signed at \(f(firstAligned)) s, shown \(Int(shownShare * 100)) %, flaps \(flaps), wrong sign \(wrong) (\(String(format: "%.2f", wrongShare * 100)) % of shown), off by more than 0.6 m/s² \(String(format: "%.1f", offSeconds)) s, worst \(String(format: "%.2f", worst)) m/s², max peak drift \(String(format: "%.2f", peakDrift)) m/s², counts at stop equal \(countsAtStop)"
        }
    }

    /// Against the generator's truth, smoothed like the analysis and taken 0.125 s before each
    /// reading (the live value is a trailing 0.25 s average, the analysis's centred one): a wrong
    /// sign is a shown value of at least 0.3 m/s² whose truth is at least 0.3 m/s² the other way.
    /// Peak drift: per refresh, Bremsen and Beschleunigen against the final analysis's 2 Hz signal
    /// over the samples that refresh read.
    static func agreement(_ name: String, _ sc: Suite.Scenario, every: Double = 10, extra: [Double] = []) -> Agreement {
        let r = replay(sc, every: every, extra: extra)
        let fin = final(sc)
        let time = sc.samples.map(\.time)
        let truLong = MotionAnalyzer.smooth(sc.truthLong.map { Float($0) }, time: time)
        let truLat = MotionAnalyzer.smooth(sc.truthLat.map { Float($0) }, time: time)
        let t0 = sc.samples[0].time
        let delay = 1 / (4 * MotionConstants.eventLowPassHz)
        var wrong = 0, flaps = 0, shown = 0
        var off = 0.0, worst = 0.0
        var first: Double?
        var previous: LiveMotionEstimator.State?
        var lastTime = t0
        for reading in r.readings {
            let dt = reading.time - lastTime
            lastTime = reading.time
            if previous == .aligned && reading.state != .aligned { flaps += 1 }
            previous = reading.state
            // Shown: either axis signed (an axis whose sign is not sure is left out, review round 2).
            guard reading.long != nil || reading.lat != nil else { continue }
            shown += 1
            if first == nil { first = reading.time - t0 }
            let k = index(time, reading.time - delay)
            let tl = Double(truLong[k]), ta = Double(truLat[k])
            var e = 0.0
            if let l = reading.long {
                if abs(l) >= 0.3 && abs(tl) >= 0.3 && (l > 0) != (tl > 0) { wrong += 1 }
                e = max(e, abs(l - tl))
            }
            if let a = reading.lat {
                if abs(a) >= 0.3 && abs(ta) >= 0.3 && (a > 0) != (ta > 0) { wrong += 1 }
                e = max(e, abs(a - ta))
            }
            worst = max(worst, e)
            if e > 0.6 { off += dt }
        }
        var drift = 0.0
        for cp in r.checkpoints where cp.summary.isAligned {
            let span = zip(fin.time, fin.long).filter { $0.0 <= cp.written && !$0.1.isNaN }.map { Double($0.1) }
            guard let lo = span.min(), let hi = span.max() else { continue }
            if let b = cp.summary.maxBraking { drift = max(drift, abs(b - min(0, lo))) }
            if let a = cp.summary.maxAcceleration { drift = max(drift, abs(a - max(0, hi))) }
        }
        var est = r.estimator
        est.refresh(source: sc.samples, allFixes: sc.fixes, now: Date(), final: true)
        let trip = MotionAnalyzer.analyze(samples: sc.samples, fixes: sc.fixes).summary
        return Agreement(name: name, firstAligned: first, shownShare: Double(shown) / Double(max(1, r.readings.count)),
                         flaps: flaps, wrong: wrong, wrongShare: Double(wrong) / Double(max(1, shown)), offSeconds: off,
                         worst: worst, peakDrift: drift, countsAtStop: est.solution?.output.summary.counts == trip.counts)
    }

    /// The physics reviewer's live drive set (live round 1), with its extra refresh points (seconds
    /// from the start: right after remounts and swivels, during slow swivels, before alignment).
    static func drives() -> [(name: String, scenario: Suite.Scenario, extra: [Double])] {
        typealias P = Phase
        var out: [(String, Suite.Scenario, [Double])] = []
        let std = Suite.standard()
        let tRemount = Suite.dur(Array(std[..<std.firstIndex { $0.remount }!]))
        out.append(("standard (remount)", Suite.build(std), [tRemount + 0.5, tRemount + 1.0, tRemount + 2.0, tRemount + 3.0, 25, 30, 35]))
        let noRemount = Suite.standard(remount: [])
        let tMid = Suite.dur(Array(noRemount[..<(noRemount.firstIndex { $0.bump }! + 2)]))
        var sw = Suite.build(noRemount)
        Suite.applyMount(&sw, start: tMid, seconds: 1.5, to: Suite.q1 * simd_quatd(angle: 45 * .pi / 180, axis: SIMD3(0, 0, 1)))
        out.append(("swivel 45 in 1.5 s", sw, [tMid + 1, tMid + 2, tMid + 3, tMid + 5]))
        for T in [6.0, 20.0] {
            var s = Suite.build(noRemount)
            Suite.applyMount(&s, start: tMid, seconds: T, to: Suite.q1 * simd_quatd(angle: 40 * .pi / 180, axis: SIMD3(0, 0, 1)))
            out.append(("slow swivel 40 in \(Int(T)) s", s, [tMid + T / 3, tMid + T / 2, tMid + T, tMid + T + 2]))
        }
        var tl = Suite.build(noRemount)
        Suite.applyMount(&tl, start: tMid, seconds: 3, to: Suite.q1 * simd_quatd(angle: 40 * .pi / 180, axis: SIMD3(0, 1, 0)))
        out.append(("tilt 40 in 3 s", tl, [tMid + 1, tMid + 2, tMid + 4]))
        var sr = Suite.build(noRemount)
        Suite.applyMount(&sr, start: tMid, seconds: 8, to: Suite.q2)
        out.append(("slow remount 8 s", sr, [tMid + 3, tMid + 6, tMid + 9]))
        out.append(("latency 2.5 s", Suite.build(std, gpsLatency: 2.5), [tRemount + 1, 30, 35]))
        out.append(("motorway lane changes", Suite.build(Suite.motorway(remount: false, straight: 18), gpsNoise: 0.2), [30, 60, 90]))
        out.append(("motorway remount + lanes", Suite.build(Suite.motorway(remount: true, straight: 18), gpsNoise: 0.2), [38.5, 40, 45, 60]))
        let lead: [P] = [P(seconds: 5), P(seconds: 6, long: 2), P(seconds: 20)] + Suite.excitation() + [P(seconds: 20)]
        let end: [P] = [P(seconds: 30)] + Suite.excitation() + [P(seconds: 4, yaw: 0.3), P(seconds: 10), P(seconds: 11.2 / 6, long: -6), P(seconds: 5)]
        var dr = Suite.build(lead + Suite.winding(120) + end)
        Suite.addBias(&dr, 0.001)
        out.append(("winding drift 0.001", dr, [200, 400, 560]))
        let mid = Suite.dur(lead + Suite.winding(60))
        var sd = Suite.build(lead + Suite.winding(60) + Suite.winding(60) + end)
        Suite.addBias(&sd, 0.001)
        Suite.applyMount(&sd, start: mid, seconds: 1.5, to: Suite.q1 * simd_quatd(angle: 45 * .pi / 180, axis: SIMD3(0, 0, 1)))
        out.append(("45 swivel inside drift road", sd, [mid + 1, mid + 3, mid + 10, mid + 30]))
        let before: [P] = [P(seconds: 5), P(seconds: 4, long: 2.8), P(seconds: 10)] + Suite.excitation() + [P(seconds: 4, yaw: 0.3), P(seconds: 5), P(seconds: 11.2 / 3, long: -3)]
        let after: [P] = [P(seconds: 5, long: 2), P(seconds: 10)] + Suite.excitation() + [P(seconds: 4, yaw: -0.3), P(seconds: 5), P(seconds: 0.1, bump: true), P(seconds: 4), P(seconds: 11.2 / 6, long: -6), P(seconds: 5)]
        var z = Suite.build(before + [P(seconds: 8)] + after)
        Suite.applyMount(&z, start: Suite.dur(before) + 2, seconds: 2, to: Suite.q2)
        out.append(("remount at red light", z, [Suite.dur(before) + 4.5, Suite.dur(before) + 9, Suite.dur(before) + 15]))
        let pre: [P] = [P(seconds: 5), P(seconds: 4, long: 2.8), P(seconds: 10)] + Suite.excitation() + [P(seconds: 4, yaw: 0.3), P(seconds: 5), P(seconds: 4, yaw: -0.3), P(seconds: 5)]
        var cup = Suite.build(pre + [P(seconds: 11.2 / 6, long: -6), P(seconds: 5), P(seconds: 6, long: 2), P(seconds: 20)] + Suite.excitation() + [P(seconds: 4, yaw: 0.3), P(seconds: 20)])
        Suite.applyMount(&cup, start: Suite.dur(pre) + 0.8, seconds: 0.3, to: Suite.q1 * simd_quatd(angle: 30 * .pi / 180, axis: SIMD3(0, 0, 1)))
        out.append(("cupholder turn mid-brake", cup, [Suite.dur(pre) + 1.5, Suite.dur(pre) + 3, Suite.dur(pre) + 6]))
        var pa: [P] = [P(seconds: 5), P(seconds: 6, long: 2), P(seconds: 10)] + Suite.excitation()
        for _ in 0..<6 { pa += [P(seconds: 3, long: -4), P(seconds: 4), P(seconds: 3, long: 1.5, yaw: 0.5), P(seconds: 3, long: 1.5), P(seconds: 5)] }
        out.append(("pull-aways, latency 1.5", Suite.build(pa, gpsLatency: 1.5), [45, 50]))
        let g = 6.0
        let gph: [P] = [P(seconds: 5, grade: g), P(seconds: 4, long: 2.8, grade: g), P(seconds: 10, grade: g)] + Suite.excitation().map { var p = $0; p.grade = g; return p }
            + [P(seconds: 40, grade: -g), P(seconds: 4, yaw: 0.3, grade: -g), P(seconds: 5, grade: -g), P(seconds: 11.2 / 6, long: -6, grade: -g), P(seconds: 5, grade: -g)]
        out.append(("grade +6/-6", Suite.build(gph), [52, 53, 60]))
        return out
    }

    typealias Phase = Suite.Phase

    // MARK: Tests

    /// The reviewer's drives at refresh cadences of 5 and 30 s and at 10 s with its extra refresh
    /// points (review L1): never a wrong sign against the truth, never an old orientation shown.
    @Test(arguments: [(5.0, false), (30.0, false), (10.0, true)])
    func theAgreementTableHoldsOnTheReviewersDrives(_ c: (Double, Bool)) {
        for d in Self.drives() {
            let a = Self.agreement(d.name + (c.1 ? " | 10 s + extra refreshes" : " | every \(Int(c.0)) s"), d.scenario, every: c.0,
                                   extra: c.1 ? d.extra : [])
            print(a.line)
            #expect(a.wrong == 0, "\(a.name): never a wrong sign")
            #expect(a.offSeconds <= 0.5, "\(a.name): no old orientation shown")
            #expect(a.countsAtStop, "\(a.name): at Stop the counts are the trip's")
            #expect(a.peakDrift <= 0.3, "\(a.name): live maxima within 0.3 m/s² of the analysis over the same span")
        }
    }

    @Test func atStopTheEstimatorIsTheTripAnalysis() {
        let sc = Suite.build(Suite.standard())
        var r = Self.replay(sc)
        r.estimator.refresh(source: sc.samples, allFixes: sc.fixes, now: Date(timeIntervalSince1970: 0), final: true)
        var live = r.estimator.solution!.output
        let trip = MotionAnalyzer.analyze(samples: sc.samples, fixes: sc.fixes, now: Date(timeIntervalSince1970: 0))
        live.summary.analyzedAt = trip.summary.analyzedAt
        #expect(live.summary == trip.summary)
        #expect(live.details == trip.details)
    }

    @Test func noSignBeforeTheFirstAlignment() {
        let sc = Suite.build(Suite.standard())
        let r = Self.replay(sc)
        let t0 = sc.samples[0].time
        let firstAlignedRefresh = r.checkpoints.first { $0.summary.isAligned }!.time
        #expect(r.readings.filter { $0.time < firstAlignedRefresh }.allSatisfy { $0.long == nil && $0.lat == nil })
        // Magnitude is shown meanwhile: the 2.8 m/s² pull-away at 5 to 9 s.
        let pull = r.readings.filter { $0.time - t0 > 6 && $0.time - t0 < 8.5 }
        #expect(pull.allSatisfy { $0.state != .aligned } && pull.contains { abs($0.horizontal - 2.8) < 0.5 })
        #expect(r.readings.allSatisfy { $0.state == .aligned || ($0.long == nil && $0.lat == nil) })
    }

    /// A remount and a swivel drop the signed values at once, before any refresh.
    @Test func aRemountOrSwivelDropsAlignmentUntilARefresh() {
        for (name, phases, mark) in [("remount", Suite.standard(), { (p: Phase) in p.remount }),
                                     ("swivel", Suite.standard(remount: [Phase(seconds: 1.5, swivel: 45)]), { (p: Phase) in p.swivel != 0 })] {
            let sc = Suite.build(phases)
            let at = Suite.dur(Array(phases[..<phases.firstIndex(where: mark)!]))
            let t0 = sc.samples[0].time
            // Refresh until 2 s before the change, then the fast path alone.
            let r = Self.replay(sc, every: 5, refreshUntil: at - 2)
            let before = r.readings.filter { $0.time - t0 > at - 2 && $0.time - t0 < at - 0.2 }
            #expect(before.contains { $0.state == .aligned }, "\(name): aligned before")
            let after = r.readings.filter { $0.time - t0 > at + 4 }
            #expect(!after.isEmpty && after.allSatisfy { $0.state == .moved && $0.long == nil }, "\(name): dropped after, \(Set(after.map(\.state)))")
        }
    }

    @Test func theChartRollsOverTheLastMinute() {
        let sc = Suite.build(Suite.standard())
        let r = Self.replay(sc)
        let end = sc.samples.last!.time
        let chart = r.estimator.chart(now: end)
        #expect(!chart.isEmpty && chart.allSatisfy { $0.time >= end - 60 && $0.time <= end })
        #expect(chart.contains { $0.long < -5 }, "the final 6 m/s² stop is in it")
    }
    /// Review L1: a refresh 2 s after a swivel, then nothing for 60 s. The swivel stays until a
    /// refresh splits the trip after it; the old orientation is never shown signed.
    @Test func aSwivelSurvivesARefreshThatHasNotSplitIt() {
        let d = Self.drives().first { $0.name == "swivel 45 in 1.5 s" }!
        let noRemount = Suite.standard(remount: [])
        let tMid = Suite.dur(Array(noRemount[..<(noRemount.firstIndex { $0.bump }! + 2)]))
        let a = Self.agreement("swivel, refresh 2 s after, then 60 s", d.scenario, every: 60, extra: [tMid + 2])
        print(a.line)
        #expect(a.wrong == 0 && a.offSeconds <= 0.5, "\(a.line)")
        let r = Self.replay(d.scenario, every: 60, extra: [tMid + 2])
        let t0 = d.scenario.samples[0].time
        let stale = r.readings.filter { $0.time - t0 > tMid + 2.5 && $0.time - t0 < 120 }
        #expect(stale.allSatisfy { $0.state != .aligned }, "no signed values in the old orientation before the 120 s refresh")
    }

    /// Review L2: the cadence is at least 10 s and at least 50 times the last refresh's duration;
    /// a tripped gate asks for an early refresh 10 s later.
    @Test func theRefreshCadenceFollowsTheCostAndGates() {
        let e = LiveMotionEstimator()
        #expect(e.refreshDue(now: 100, lastRefresh: nil, lastDuration: 0))
        #expect(!e.refreshDue(now: 109, lastRefresh: 100, lastDuration: 0.01))
        #expect(e.refreshDue(now: 110, lastRefresh: 100, lastDuration: 0.01))
        #expect(!e.refreshDue(now: 140, lastRefresh: 100, lastDuration: 1))
        #expect(e.refreshDue(now: 150, lastRefresh: 100, lastDuration: 1))
        // With 1 s per refresh (a long trip on a phone): 50 s apart, but early after a remount.
        let sc = Suite.build(Suite.standard())
        let r = Self.replay(sc, every: 0, cost: 1)
        let t0 = sc.samples[0].time
        let times = r.checkpoints.map { $0.time - t0 }
        print("LIVE cadence at 1 s per refresh: refreshes at \(times.map { Int($0) }) s")
        let std = Suite.standard()
        let tRemount = Suite.dur(Array(std[..<std.firstIndex { $0.remount }!]))
        #expect(times.contains { $0 > tRemount && $0 < tRemount + 15 }, "an early refresh after the remount")
        for (a, b) in zip(times, times.dropFirst()) { #expect(b - a >= 10 - 0.02) }
    }
    // MARK: Review round 2: acceptance on the reviewer's city drive

    /// The reviewer's city block (round 2): a straight, a right turn, a roundabout, stop and go, a
    /// U-turn and a cloverleaf.
    static func cityBlock(uTurnYaw: Double = 1.1) -> [Phase] {
        typealias P = Phase
        var ph: [P] = []
        ph += [P(seconds: 5, long: 2), P(seconds: 15)]
        ph += [P(seconds: 2, long: -2.5), P(seconds: 5.2, yaw: -0.3), P(seconds: 2.5, long: 2), P(seconds: 10)]
        ph += [P(seconds: 2, long: -2), P(seconds: 1.5, yaw: -0.3), P(seconds: 11, yaw: 0.4), P(seconds: 1.5, yaw: -0.3), P(seconds: 2, long: 2), P(seconds: 10)]
        ph += [P(seconds: 10 / 3, long: -3), P(seconds: 5), P(seconds: 5, long: 2), P(seconds: 10)]
        ph += [P(seconds: 2, long: -2.5), P(seconds: Double.pi / uTurnYaw, yaw: uTurnYaw), P(seconds: 2.5, long: 2), P(seconds: 10)]
        ph += [P(seconds: 2.5, long: 2), P(seconds: 23.5, yaw: 0.2), P(seconds: 2.5, long: -2), P(seconds: 10)]
        return ph
    }

    static func cityDrive(blocks: Int = 3, uTurnYaw: Double = 1.1) -> [Phase] {
        [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Suite.excitation() + [Phase(seconds: 6, long: -2), Phase(seconds: 3)]
            + (0..<blocks).flatMap { _ in cityBlock(uTurnYaw: uTurnYaw) }
    }

    /// Normal drives keep signed values most of the time, also with gyro bias and low-speed GPS
    /// course noise, and the gate never trips on U-turns (M1).
    @Test func normalDrivesShowSignedValuesWithBiasAndCourseNoise() {
        let plain = Self.agreement("city 3 blocks, U-turn 1.3 rad/s", Suite.build(Self.cityDrive(uTurnYaw: 1.3)))
        var noisy = Suite.build(Self.cityDrive(), courseNoise: 30)
        Suite.addBias(&noisy, 0.002)
        let hard = Self.agreement("city, gyro bias 0.002 rad/s, course noise 30/v", noisy)
        for a in [plain, hard] {
            print(a.line)
            #expect(a.wrong == 0 && a.offSeconds <= 5, "\(a.line)")
        }
        #expect(plain.shownShare >= 0.85, "\(plain.line)")
        #expect(hard.shownShare >= 0.80, "\(hard.line)")
    }

    /// Slow swivels (M3): never a wrong sign, never more than 5 s shown more than 0.6 m/s² off,
    /// and signed values come back after the swivel (M1).
    @Test(arguments: [(20.0, 120.0), (40.0, 20.0)])
    func slowSwivelsNeitherShowAnOldOrientationNorHideForever(_ c: (Double, Double)) {
        let base = Self.cityDrive()
        let start = Suite.dur(Array(base[..<25]))
        var s = Suite.build(base)
        Suite.applyMount(&s, start: start, seconds: c.1, to: Suite.q1 * simd_quatd(angle: c.0 * .pi / 180, axis: SIMD3(0, 0, 1)))
        let a = Self.agreement("city, swivel \(Int(c.0)) deg over \(Int(c.1)) s", s)
        print(a.line)
        #expect(a.wrong == 0 && a.offSeconds <= 5, "\(a.line)")
        let r = Self.replay(s)
        let t0 = s.samples[0].time
        let after = r.readings.filter { $0.time - t0 > start + c.1 + 60 }
        #expect(after.contains { $0.long != nil }, "signed again within 60 s after the swivel")
    }

    /// A remount on a long trip with a phone that needs 16 s per refresh (an 8 h trip): the cheap
    /// segment refresh brings signed values back within 120 s (M2).
    @Test func afterARemountSignedValuesReturnWithinTwoMinutesAtEightHours() {
        let ph = [Phase(seconds: 5), Phase(seconds: 6, long: 2), Phase(seconds: 10)] + Suite.excitation() + [Phase(seconds: 6, long: -2), Phase(seconds: 3)]
            + Self.cityBlock() + [Phase(seconds: 1.5, remount: true)] + (0..<2).flatMap { _ in Self.cityBlock() }
        let sc = Suite.build(ph)
        let remountAt = Suite.dur(Array(ph[..<ph.firstIndex { $0.remount }!]))
        let r = Self.replay(sc, every: 0, cost: 16)
        let t0 = sc.samples[0].time
        let back = r.readings.first { $0.time - t0 > remountAt + 2 && $0.long != nil }.map { $0.time - t0 - remountAt }
        print("LIVE remount at 16 s per refresh: signed again after \(back.map { String(format: "%.0f s", $0) } ?? "never"), segment refreshes \(r.estimator.segmentRefreshes), full \(r.estimator.fullRefreshes)")
        #expect((back ?? .infinity) <= 120)
        #expect(r.estimator.segmentRefreshes >= 1)
    }

    // MARK: Review round 3

    /// F4: an event the analysis never splits gets at most `maxEventTries` window refreshes, then
    /// the cost-based cadence (here 1 s per refresh, so every 50 s).
    @Test func anUnresolvedEventStopsRefreshingEarly() {
        let base = Self.cityDrive()
        let start = Suite.dur(Array(base[..<25]))
        var s = Suite.build(base)
        Suite.applyMount(&s, start: start, seconds: 90, to: Suite.q1 * simd_quatd(angle: 45 * .pi / 180, axis: SIMD3(0, 0, 1)))
        let r = Self.replay(s, every: 0, cost: 1)
        let duration = s.samples.last!.time - s.samples.first!.time
        let total = r.estimator.segmentRefreshes + r.estimator.fullRefreshes
        print("LIVE F4: \(r.estimator.segmentRefreshes) window and \(r.estimator.fullRefreshes) full refreshes in \(Int(duration)) s")
        #expect(r.estimator.segmentRefreshes <= 2 * LiveMotionEstimator.maxEventTries)
        #expect(Double(total) <= duration / 50 + 2 * Double(LiveMotionEstimator.maxEventTries) + 2)
    }

    /// F6: the yaw test averages 0.2 s, so a noisy U-turn at 1.45 rad/s trips nothing.
    @Test func aSharpUTurnDoesNotTripTheYawTest() {
        let a = Self.agreement("city, U-turn 1.45 rad/s", Suite.build(Self.cityDrive(uTurnYaw: 1.45)))
        print(a.line)
        #expect(a.wrong == 0 && a.shownShare >= 0.85, "\(a.line)")
    }
}
