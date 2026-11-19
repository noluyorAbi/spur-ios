import Foundation
import simd

/// The live estimator of the vehicle's acceleration while a trip records (SPEC 17.3). Pure: no
/// UI, no CoreMotion, no clock. It is fed samples and fixes as they arrive and, when the caller
/// decides, the samples and fixes so far for a refresh.
///
/// A refresh runs the trip analysis itself (`MotionAnalyzer.live`, the same mount segments, fit,
/// gains, event and jolt detectors), so the maxima, counts, roughness and alignment shown are the
/// analysis of the trip so far, and at Stop they are the trip's. Between refreshes the newest
/// samples are carried in the last segment's basis and fit. A signed value is shown only while
/// that fit holds: before the first alignment, with a hand at work, after the up vector moved
/// more than the remount threshold, or when the gyro's heading leaves GPS's (a swivel), only the
/// horizontal magnitude is shown until a refresh decides again. Never a wrong sign.
nonisolated struct LiveMotionEstimator: Sendable {
    enum State: String, Sendable, Equatable {
        /// Fewer samples than the analysis needs.
        case waiting
        /// No aligned segment yet (needs pulling away and braking).
        case aligning
        /// Signed values shown.
        case aligned
        /// A hand at work, a remount or a swivel since the last refresh.
        case moved
    }

    /// The acceleration now: 2 Hz like the analysis (a trailing 0.25 s window here, 0.125 s late; the same width centred there).
    struct Reading: Sendable, Equatable {
        var time: Double
        /// Horizontal magnitude, m/s².
        var horizontal: Double
        /// m/s², + forward. Nil unless `state == .aligned`, and while the other axis is so large that an unseen misalignment could flip its sign.
        var long: Double?
        /// m/s², + left. Nil under the same rules.
        var lat: Double?
        var state: State
        /// While aligned, the size of an axis whose sign is withheld (`long` or `lat` nil), so it
        /// is shown without a direction rather than not at all.
        var longSize: Double? = nil
        var latSize: Double? = nil
    }

    /// Seconds of raw samples kept for replaying after a refresh (the file can lag the stream).
    static let ringSeconds = 70.0
    /// Seconds of the rolling chart.
    static let chartSeconds = 60.0
    /// Heading drift between gyro and GPS over this window that counts as a swivel.
    static let swivelWindowSeconds = 5.0
    /// A yaw rate no car reaches (a U-turn on full lock is about 1.0 to 1.3 rad/s): above it a hand
    /// turns the phone. Not coupled to the GPS speed, which lags.
    static let maxCarYawRate = 1.5
    /// The yaw rate is averaged over this long before the test (review round 3, F6: single noisy
    /// samples of a 1.3 to 1.45 rad/s U-turn crossed it).
    static let yawAverageSeconds = 0.2
    /// Window refreshes and early triggers for one unresolved event, then back to the cost-based
    /// cadence (review round 3, F4: an event the analysis never splits cost 10 to 20 % of a core
    /// at 8 h).
    static let maxEventTries = 6
    /// The recent pairs' own rotation may differ from the shown fit by this much (a 6° error is at
    /// most 0.3 m/s² at 3 m/s²).
    static let fitHoldsDegrees = 6.0
    /// While an event is unresolved, every this many refreshes is a full one (to see whether the
    /// analysis has split the trip there).
    static let fullEvery = 3
    /// The largest misalignment that can stay unseen: a swivel too slow to tell from gyro bias
    /// (below about 0.2°/s) until the straight-point check trips at about 10°, plus the fit's own
    /// error.
    static let undetectedDegrees = 12.0
    /// Excited pairs after the flag that judge whether the fit holds: fewer than an alignment
    /// needs, since this only confirms a rotation already known (a real swivel of 10° or more moves
    /// the refit well beyond `fitHoldsDegrees`).
    static let fitHoldsPairs = 10
    /// The window check's tolerance grows by this share of the course change in it.
    static let turnTolerance = 0.1
    /// Gyro bias the straight-point reference follows, °/s (0.001 rad/s). A larger bias trips the
    /// gate, and the next refresh's fit check clears it again (review round 2, M1, M3).
    static let biasDegreesPerSecond = 0.06
    /// Straight points only at this speed or more: GPS course noise falls with speed (M1).
    static let straightMinSpeed = 8.0
    /// Disagreeing straight points in a row that confirm a swivel (M1).
    static let confirmPoints = 2
    /// A refresh whose last segment starts no earlier than this before the flag has split the trip
    /// after the swivel (a slow swivel is flagged late; M1).
    static let splitMarginSeconds = 30.0
    /// A segment refresh after a remount or swivel reads from this long before it.
    static let segmentLeadSeconds = 5.0
    /// Refresh cadence (review L2): at least `minRefreshSeconds`, and at least
    /// `refreshCostFactor` times the last refresh's duration (2 % of one core).
    static let minRefreshSeconds = 10.0
    static let refreshCostFactor = 50.0

    private(set) var solution: MotionAnalyzer.LiveSolution?
    private(set) var reading: Reading?
    /// The 2 Hz longitudinal after the last refresh's tail (10 per second), for the chart.
    private(set) var liveTime: [Double] = []
    private(set) var liveLong: [Float] = []

    private var ring: [MotionSample] = []
    private var fixes: [Fix] = []
    private var tail: MotionAnalyzer.LiveTail?
    // Carried filter states.
    private var lp = SIMD3<Double>(0, 0, 1)
    private var lp2 = SIMD3<Double>(0, 0, 1)
    private var lastTime: Double?
    // Trailing 0.25 s average of the basis components (the analysis's event window).
    private var window: [(t: Double, x: Double, y: Double)] = []
    private var sumX = 0.0, sumY = 0.0
    // Hand at work: net horizontal rotation over 0.5 s.
    private var turns: [(t: Double, w: SIMD3<Double>)] = []
    private var turnSum = SIMD3<Double>.zero
    private var handlingUntil = -Double.infinity
    private var moved = false
    // Swivel: gyro heading (integral of the yaw rate about up) at each sample time, for the check
    // against the GPS course.
    private var heading = 0.0
    private var senseTime: Double?
    private var yaws: [(t: Double, y: Double)] = []
    private var yawSum = 0.0
    // Trailing 0.25 s average of the horizontal acceleration as a vector in device axes: its
    // magnitude needs no basis, so it is shown from the first sample.
    private var horizontals: [(t: Double, a: SIMD3<Double>)] = []
    private var horizontalSum = SIMD3<Double>.zero
    private var headings: [(t: Double, h: Double)] = []
    private var lastChartTime = -Double.infinity
    /// A swivel (the phone turned about up) since this sensor time: no signed values until a
    /// refresh's last segment starts after it, or a straight point shows gyro and GPS agree after
    /// all. Kept across refreshes (review L1).
    private(set) var swivelAt: Double?
    /// Which check set the swivel gate last: "yaw", "window" or "straight" (diagnostics, tests).
    private(set) var swivelReason: String?
    private var swivelConfirmed = false
    /// The reference of the straight-point check: sensor time, and gyro heading plus GPS course
    /// (°), which stays constant while the mount does.
    private var anchor: (t: Double, r: Double)?
    /// The car has moved at the swivel speed at least once.
    private var drove = false
    private var disagreements = 0
    /// A remount or confirmed swivel at this sensor time that the last full refresh does not cover:
    /// once `MotionConstants.excitationCount` excited GPS intervals are in after it, a segment
    /// refresh runs on the samples from shortly before it (review round 2, M2).
    private(set) var eventAt: Double?
    private var excitedSince = 0
    /// The last full refresh: what a segment refresh keeps for the time before it.
    private var lastFull: (end: Double, output: MotionAnalyzer.Output)?
    private var windowRefreshesSinceFull = 0
    /// The counts shown so far (never lower during the drive).
    private var countFloor = MotionSummary.Counts()
    private var shownMaxima: (brake: Double?, accel: Double?, left: Double?, right: Double?)?
    /// The open event has had a window refresh (later ones follow the cadence).
    private var eventWindowed = false
    /// Window refreshes for the open event so far (F4).
    private var eventTries = 0
    /// Refreshes run so far, full and segment-only (tests).
    private(set) var fullRefreshes = 0
    private(set) var segmentRefreshes = 0
    /// A gate tripped (remount or confirmed swivel): refresh early, `minRefreshSeconds` after it.
    private(set) var earlyRefreshAt: Double?

    /// While nobody looks (the feed inactive), only the gates run per sample: no reading, no chart
    /// (17.4, the cost in the background). A refresh rebuilds both when someone looks again.
    var quiet = false

    init() {}

    var state: State { reading?.state ?? .waiting }

    /// Why values are hidden, in the owner's words (SPEC 18.10a): the phone is in a hand, or it was
    /// put down and the mount is being found again (on the owner's drives about 67 s per put-down).
    enum Hidden: Sendable, Equatable {
        case inHand
        case realigning(remainingSeconds: Double)
    }

    static let typicalRealignSeconds = 67.0

    var hidden: Hidden? {
        guard let t = lastTime, handlingUntil > -Double.infinity else { return nil }
        if t < handlingUntil { return .inHand }
        let since = t - handlingUntil
        guard since < 3 * Self.typicalRealignSeconds, state == .aligning || state == .moved else { return nil }
        return .realigning(remainingSeconds: max(0, Self.typicalRealignSeconds - since))
    }

    // MARK: Feeding

    mutating func append(_ samples: [MotionSample]) {
        for s in samples { step(s, record: true) }
    }

    mutating func append(fix: Fix) {
        fixes.append(fix)
        if fixes.count > 32 { fixes.removeFirst(fixes.count - 32) }
        if (fix.speed ?? 0) >= MotionConstants.swivelMinSpeed { drove = true }
        countExcitation()
        checkSwivel()
        checkStraight()
    }

    /// The last fix interval as a GPS target, counted after an event when it carries at least
    /// the analysis's excitation (0.5 m/s² longitudinal or lateral).
    private mutating func countExcitation() {
        guard let at = eventAt, fixes.count >= 2 else { return }
        let a = fixes[fixes.count - 2], b = fixes[fixes.count - 1]
        let dt = b.time - a.time
        guard dt > 0, dt <= MotionConstants.targetMaxGapSeconds, let va = a.speed, let vb = b.speed,
              b.time + (tail?.lag ?? 0) >= at else { return }
        let long = (vb - va) / dt
        var lat = 0.0
        if let ca = a.course, let cb = b.course, min(va, vb) >= MotionConstants.targetMinSpeed {
            lat = (va + vb) / 2 * MotionAnalyzer.wrap180(cb - ca) * .pi / 180 / dt
        }
        let size = (long * long + lat * lat).squareRoot()
        if size >= MotionConstants.excitationTarget && size <= MotionConstants.maxTarget { excitedSince += 1 }
    }

    /// Whether a refresh is due at sensor time `now`: the cadence of review L2 (at least
    /// `minRefreshSeconds`, at least `refreshCostFactor` times the last refresh's duration), or
    /// early after a gate tripped. The caller measures `lastDuration`.
    func refreshDue(now: Double, lastRefresh: Double?, lastDuration: Double) -> Bool {
        guard let lastRefresh else { return true }
        let interval = max(Self.minRefreshSeconds, Self.refreshCostFactor * lastDuration)
        if now - lastRefresh >= interval { return true }
        if let early = earlyRefreshAt, now >= early, now - lastRefresh >= Self.minRefreshSeconds { return true }
        // A segment refresh: cheap (only the samples since the event), as soon as the new segment
        // can align.
        guard eventTries < Self.maxEventTries else { return false }
        if eventAt != nil, lastFull != nil, excitedSince >= MotionConstants.excitationCount, now - lastRefresh >= 2 { return true }
        // Its window not aligned yet: the cheap window refresh again every `minRefreshSeconds`.
        if eventAt != nil, eventWindowed, tail?.fit == nil, now - lastRefresh >= Self.minRefreshSeconds { return true }
        return false
    }

    /// The analysis of the samples from shortly before the event only; what came before keeps
    /// the last full refresh's values (M2). The full analysis at Stop decides.
    private mutating func windowRefresh<S: MotionSampleSource>(_ source: S, _ allFixes: [Fix], _ now: Date) -> MotionAnalyzer.LiveSolution {
        #if DEBUG
        PerfCounters.add("est.refresh.window")
        #endif
        let at = eventAt ?? now.timeIntervalSince1970
        let from = at - Self.segmentLeadSeconds
        let slice = MotionSourceSlice(source, from: from)
        let fixesFrom = allFixes.filter { $0.time >= from - 5 }
        var w = MotionAnalyzer.live(source: slice, fixes: fixesFrom, now: now, recentSeconds: Self.chartSeconds, checkFrom: swivelAt)
        if let full = lastFull { w.output = Self.merged(full: full.output, fullEnd: full.end, window: w.output) }
        segmentRefreshes += 1
        windowRefreshesSinceFull += 1
        eventTries += 1
        excitedSince = 0
        eventWindowed = true
        return w
    }

    /// The last segment's fit still explains the excited pairs after the flag: the gate's r, and
    /// the pairs' own rotation within `fitHoldsDegrees` of it.
    static func fitHolds(_ recent: MotionAnalyzer.RecentFit?) -> Bool {
        guard let r = recent, r.excited >= Self.fitHoldsPairs, !r.reflected else { return false }
        return (r.r ?? 0) >= MotionConstants.goodRLong && abs(r.thetaChange) <= fitHoldsDegrees * .pi / 180
    }

    private var segmentRefreshWanted: Bool {
        eventAt != nil && lastFull != nil && (excitedSince >= MotionConstants.excitationCount || eventWindowed)
    }

    /// Runs the analysis on everything so far (`source` and `allFixes` are the trip's samples and
    /// fixes up to now, for instance `motion.bin` read back), then replays the ring samples newer
    /// than the source's last one.
    /// `final`: the trip's last refresh (at Stop): its counts are the analysis's as they are.
    /// Before that a shown count never falls: a window refresh and a full one can disagree by an
    /// event at a swivel the analysis has not split, and a count the driver saw must not vanish.
    mutating func refresh<S: MotionSampleSource>(source: S, allFixes: [Fix], now: Date, final: Bool = false) {
        var solved: MotionAnalyzer.LiveSolution
        if !final && segmentRefreshWanted && windowRefreshesSinceFull < Self.fullEvery - 1 {
            solved = windowRefresh(source, allFixes, now)
        } else {
            solved = MotionAnalyzer.live(source: source, fixes: allFixes, now: now, recentSeconds: Self.chartSeconds,
                                         checkFrom: swivelAt ?? eventAt)
            fullRefreshes += 1
        #if DEBUG
        PerfCounters.add("est.refresh.full")
        #endif
            windowRefreshesSinceFull = 0
            if let end = solved.tail?.time { lastFull = (end, solved.output) }
            if let at = eventAt, let t = solved.tail {
                if t.fit != nil && t.segmentStart >= at - Self.splitMarginSeconds {
                    // The analysis split the trip after the event and aligned the new segment.
                    eventAt = nil
                } else if t.fit != nil && Self.fitHolds(solved.recent) {
                    // The shown fit still explains the data after it: nothing changed after all.
                    eventAt = nil
                } else if !final && segmentRefreshWanted {
                    // Unresolved: the analysis of the samples since the event describes now.
                    solved = windowRefresh(source, allFixes, now)
                }
            }
        }
        if final {
            countFloor = MotionSummary.Counts()
            shownMaxima = nil
        } else {
            // Maxima likewise never shrink during the drive.
            var m = solved.output.summary
            if let p = shownMaxima {
                func lo(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.min() }
                func hi(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.max() }
                m.maxBraking = lo(m.maxBraking, p.brake)
                m.maxAcceleration = hi(m.maxAcceleration, p.accel)
                m.maxLateralLeft = hi(m.maxLateralLeft, p.left)
                m.maxLateralRight = lo(m.maxLateralRight, p.right)
            }
            shownMaxima = (m.maxBraking, m.maxAcceleration, m.maxLateralLeft, m.maxLateralRight)
            solved.output.summary = m
            var c = solved.output.summary.counts
            c.hardBraking = max(c.hardBraking, countFloor.hardBraking)
            c.veryHardBraking = max(c.veryHardBraking, countFloor.veryHardBraking)
            c.hardAcceleration = max(c.hardAcceleration, countFloor.hardAcceleration)
            c.lateralLeft = max(c.lateralLeft, countFloor.lateralLeft)
            c.lateralRight = max(c.lateralRight, countFloor.lateralRight)
            c.bumps = max(c.bumps, countFloor.bumps)
            solved.output.summary.counts = c
            countFloor = c
        }
        solution = solved
        tail = solved.tail
        moved = false
        earlyRefreshAt = nil
        // The swivel gate clears when the data says the current fit holds (M1): the analysis split
        // the trip after the flag, or the last segment's fit still explains the excited pairs after
        // it (the gate's r, and a refit on those pairs within the swivel threshold).
        if let at = swivelAt, let t = solved.tail, t.fit != nil {
            let split = t.segmentStart >= at - Self.splitMarginSeconds
            if split || Self.fitHolds(solved.recent) {
                swivelAt = nil
                swivelConfirmed = false
                anchor = nil
                disagreements = 0
            }
        }
        liveTime = []
        liveLong = []
        lastChartTime = -.infinity
        window = []
        sumX = 0
        sumY = 0
        guard let tail else {
            reading = ring.last.map { Reading(time: $0.time, horizontal: currentHorizontal, long: nil, lat: nil, state: .waiting) }
            return
        }
        lp = tail.upLowPass
        lp2 = tail.basisUp
        lastTime = tail.time
        if tail.handling { handlingUntil = max(handlingUntil, tail.time + MotionConstants.handlingPadSeconds) }
        // Fill the averaging window from the ring's last half second up to the tail (the analysis
        // already carried those), then replay what is newer.
        let half = 1 / (2 * MotionConstants.eventLowPassHz)
        for s in ring where s.time > tail.time - half && s.time <= tail.time {
            let (x, y) = MotionAnalyzer.basisComponents(s, e1: tail.e1, e2: tail.e2, from: tail.segmentUp, lowPassUp: lp2)
            push(s.time, x, y)
        }
        let newer = ring.filter { $0.time > tail.time }
        for s in newer { step(s, record: false) }
        if newer.isEmpty { publish(tail.time) }
    }

    // MARK: Values for the panel

    /// The rolling chart: the refresh's 2 Hz longitudinal, then the live one after its tail.
    func chart(now: Double) -> [(time: Double, long: Double)] {
        var out: [(Double, Double)] = []
        if let s = solution {
            for (t, v) in zip(s.recentTime, s.recentLong) where t >= now - Self.chartSeconds && !v.isNaN { out.append((t, Double(v))) }
        }
        for (t, v) in zip(liveTime, liveLong) where t >= now - Self.chartSeconds && !v.isNaN { out.append((t, Double(v))) }
        return out
    }

    // MARK: Steps

    /// `record`: a new sample (kept, and its hand and heading checks run once); else a replay
    /// after a refresh.
    private mutating func step(_ s: MotionSample, record: Bool) {
        #if DEBUG
        PerfCounters.add("est.step")
        #endif
        if record {
            ring.append(s)
            if let first = ring.first, s.time - first.time > Self.ringSeconds + 5 {
                let cut = ring.firstIndex { s.time - $0.time <= Self.ringSeconds } ?? 0
                ring.removeFirst(cut)
            }
            sense(s)
        }
        guard let tail else {
            reading = Reading(time: s.time, horizontal: currentHorizontal, long: nil, lat: nil, state: .waiting)
            return
        }
        guard s.time > (lastTime ?? -.infinity) else { return }
        let u = MotionAnalyzer.upVector(s)
        let d = lastTime.map { max(0, s.time - $0) } ?? 0
        lastTime = s.time
        lp = simd_normalize(lp + (u - lp) * (d / (MotionConstants.lowPassUpSeconds + d)))
        lp2 = simd_normalize(lp2 + (u - lp2) * (d / (MotionConstants.lowPassUpSeconds + d)))
        // A remount: the low-passed up left the reference by more than the analysis allows.
        if !tail.settling && angle(lp, tail.upReference) > MotionConstants.mountChangeDegrees && !moved {
            moved = true
            earlyRefreshAt = earlyRefreshAt ?? s.time + Self.minRefreshSeconds
            if eventAt == nil {
                eventAt = s.time
                excitedSince = 0
                eventWindowed = false
                eventTries = 0
            }
        }
        // Quiet (nobody looks): the gates above keep watching, the dot and the chart wait.
        guard !quiet else { return }
        #if DEBUG
        PerfCounters.add("est.notQuiet")
        #endif
        let (x, y) = MotionAnalyzer.basisComponents(s, e1: tail.e1, e2: tail.e2, from: tail.segmentUp, lowPassUp: lp2)
        push(s.time, x, y)
        publish(s.time)
    }

    /// Once per new sample: a hand at work (as the analysis: net rotation about a horizontal axis
    /// over 0.5 s above 10°) and the gyro heading for the swivel check.
    private mutating func sense(_ s: MotionSample) {
        let d = senseTime.map { s.time - $0 } ?? 0
        guard d >= 0 else { return }
        senseTime = s.time
        let dt = d > MotionConstants.sensorGapSeconds ? 0 : d
        let u = MotionAnalyzer.upVector(s)
        let w = SIMD3<Double>(s.rotationRate)
        let horizontal = (w - simd_dot(w, u) * u) * dt
        turns.append((s.time, horizontal))
        turnSum += horizontal
        while let first = turns.first, s.time - first.t > MotionConstants.handlingWindowSeconds {
            turnSum -= first.w
            turns.removeFirst()
        }
        if simd_length(turnSum) > MotionConstants.handlingDegrees * .pi / 180 {
            handlingUntil = s.time + MotionConstants.handlingPadSeconds
        }
        let a = -SIMD3<Double>(s.userAcceleration) * MotionConstants.g
        let ah = a - simd_dot(a, u) * u
        horizontals.append((s.time, ah))
        horizontalSum += ah
        while let first = horizontals.first, s.time - first.t > 1 / (2 * MotionConstants.eventLowPassHz) {
            horizontalSum -= first.a
            horizontals.removeFirst()
        }
        let yaw = simd_dot(w, u)
        yaws.append((s.time, yaw))
        yawSum += yaw
        while let first = yaws.first, s.time - first.t > Self.yawAverageSeconds {
            yawSum -= first.y
            yaws.removeFirst()
        }
        let yawAverage = yawSum / Double(yaws.count)
        // Only once the car has driven: a phone placed by hand before the drive is the segment the
        // first fit is made for. Not tied to a refresh, so the gates also watch while the panel is
        // closed and nothing is refreshed.
        if abs(yawAverage) > Self.maxCarYawRate && swivelAt == nil && drove {
            swivelAt = s.time
            swivelReason = "yaw"
            swivelConfirmed = false
        }
        heading += yaw * dt
        headings.append((s.time, heading))
        if let first = headings.first, s.time - first.t > Self.swivelWindowSeconds + 15 {
            headings.removeFirst(headings.firstIndex { s.time - $0.t <= Self.swivelWindowSeconds + 10 } ?? 0)
        }
    }

    private mutating func push(_ t: Double, _ x: Double, _ y: Double) {
        window.append((t, x, y))
        sumX += x
        sumY += y
        let half = 1 / (2 * MotionConstants.eventLowPassHz)
        while let first = window.first, t - first.t > half {
            sumX -= first.x
            sumY -= first.y
            window.removeFirst()
        }
    }

    private mutating func publish(_ t: Double) {
        #if DEBUG
        PerfCounters.add("est.publish")
        #endif
        guard let tail, !window.isEmpty else { return }
        let x = sumX / Double(window.count), y = sumY / Double(window.count)
        let current = state(tail, at: t)
        // Aligned: the magnitude of the same components the signed values come from.
        let horizontal = current == .aligned ? (x * x + y * y).squareRoot() : currentHorizontal
        var long: Double?, lat: Double?, longSize: Double?, latSize: Double?
        if current == .aligned, let fit = tail.fit {
            let (a, b) = MotionAnalyzer.rotate(x, y, fit.theta)
            let l = a, q = tail.yawSwapped ? -b : b
            // A misalignment the gates cannot see yet (up to `undetectedDegrees`) leaks up to
            // sin of it of one axis into the other: an axis smaller than that leak has no sure sign.
            let leak = sin(Self.undetectedDegrees * .pi / 180)
            long = abs(l) >= leak * abs(q) ? l : nil
            lat = abs(q) >= leak * abs(l) ? q : nil
            if long == nil { longSize = abs(l) }
            if lat == nil { latSize = abs(q) }
        }
        reading = Reading(time: t, horizontal: horizontal, long: long, lat: lat, state: current, longSize: longSize, latSize: latSize)
        if t - lastChartTime >= 0.1 {
            lastChartTime = t
            liveTime.append(t)
            liveLong.append(long.map(Float.init) ?? .nan)
            if let first = liveTime.first, t - first > Self.ringSeconds {
                let cut = liveTime.firstIndex { t - $0 <= Self.chartSeconds } ?? 0
                liveTime.removeFirst(cut)
                liveLong.removeFirst(cut)
            }
        }
    }

    /// A swivel: over the last `swivelWindowSeconds` of driving (GPS speed at least the analysis's
    /// swivel speed), the gyro heading and the GPS course disagree by more than the analysis's
    /// swivel threshold. GPS time is sensor time minus the lag.
    private mutating func checkSwivel() {
        guard drove, fixes.count >= 2 else { return }
        // Before a refresh determined the lag, none is assumed: a turn may then trip the window,
        // and the next straight point after it clears that again.
        let lag = tail?.lag ?? 0
        // Any window, also one that started before the last refresh (review L1). It ends at the
        // newest fix the gyro already covers: with a positive lag the newest fix's sensor time is
        // still ahead of the samples.
        guard let covered = headings.last?.t,
              let end = fixes.lastIndex(where: { $0.time + lag <= covered + 0.05 }), end >= 1 else { return }
        guard let c1 = fixes[end].course, (fixes[end].speed ?? 0) >= MotionConstants.swivelMinSpeed else { return }
        var k = end
        var course = c1
        var change = 0.0
        while k > 0 {
            let a = fixes[k - 1], b = fixes[k]
            guard let ca = a.course, (a.speed ?? 0) >= MotionConstants.swivelMinSpeed,
                  b.time - a.time <= MotionConstants.targetMaxGapSeconds else { break }
            change += MotionAnalyzer.wrap180(course - ca)
            course = ca
            k -= 1
            if fixes[end].time - a.time >= Self.swivelWindowSeconds { break }
        }
        guard k < end, let h0 = gyroHeading(at: fixes[k].time + lag), let h1 = gyroHeading(at: fixes[end].time + lag) else { return }
        // The gyro heading grows to the left (about up), the course to the right. In a turn a small
        // lag error grows with the turn (1.1 rad/s and 0.2 s are 12°): the tolerance grows with
        // the course change; a swivel inside a turn is left to the straight points after it.
        let residual = (h1.h - h0.h) * 180 / .pi + change
        // And with the course's own noise at both ends (two sigma each, in quadrature).
        let noise = 2 * (Self.courseSigma(fixes[k]) * Self.courseSigma(fixes[k]) + Self.courseSigma(fixes[end]) * Self.courseSigma(fixes[end])).squareRoot()
        if abs(residual) > MotionConstants.swivelDegrees + Self.turnTolerance * abs(change) + noise && swivelAt == nil {
            swivelAt = fixes[k].time + lag
            swivelReason = "window"
            swivelConfirmed = false
        }
    }

    /// At a straight point (five fixes at `straightMinSpeed` or more, every course within 3° of
    /// their median), the gyro heading plus that median course must still equal the reference,
    /// within the swivel threshold plus gyro bias since the reference. The reference follows only
    /// at the bias rate, so a slow swivel cannot walk it along (M3). Agreeing clears an unconfirmed
    /// swivel flagged before this point (a hard car turn); two disagreeing points in a row confirm
    /// a swivel or find a slow one no window saw (M1).
    private mutating func checkStraight() {
        let end = fixes.count - 1
        guard end >= 4 else { return }
        let k = end - 2
        guard let c0 = fixes[k].course else { return }
        var courses: [Double] = []
        for j in (k - 2)...(k + 2) {
            guard let cj = fixes[j].course, (fixes[j].speed ?? 0) >= Self.straightMinSpeed else { return }
            if j > k - 2 && fixes[j].time - fixes[j - 1].time > MotionConstants.targetMaxGapSeconds { return }
            courses.append(c0 + MotionAnalyzer.wrap180(cj - c0))
        }
        let median = courses.sorted()[2]
        guard courses.allSatisfy({ abs($0 - median) <= MotionConstants.straightDegrees }) else { return }
        let t = fixes[k].time + (tail?.lag ?? 0)
        guard let h = gyroHeading(at: t) else { return }
        // Gyro heading grows to the left, the course to the right: their sum stays constant.
        let residual = h.h * 180 / .pi + median
        guard let a = anchor else {
            if swivelAt == nil { anchor = (t, residual) }
            return
        }
        let dt = max(0, t - a.t)
        let drift = MotionAnalyzer.wrap180(residual - a.r)
        let bias = Self.biasDegreesPerSecond * dt
        // The shown fit may be off by `fitHoldsDegrees`, plus the median course's noise.
        let sigma = Self.courseSigma(fixes[k]) / Double(courses.count).squareRoot() * 1.25
        if abs(drift) <= Self.fitHoldsDegrees + 2 * sigma + bias {
            disagreements = 0
            if let at = swivelAt, !swivelConfirmed, t > at + Self.swivelWindowSeconds { swivelAt = nil }
            if swivelAt == nil { anchor = (t, a.r + max(-bias, min(bias, drift))) }
        } else {
            disagreements += 1
            guard disagreements >= Self.confirmPoints else { return }
            disagreements = 0
            if swivelAt == nil {
                swivelAt = a.t
                swivelReason = "straight"
            }
            swivelConfirmed = true
            earlyRefreshAt = earlyRefreshAt ?? t + Self.minRefreshSeconds
            if eventAt == nil {
                eventAt = swivelAt
                excitedSince = 0
                eventWindowed = false
                eventTries = 0
            }
            anchor = (t, residual)
        }
    }

    /// Counts and maxima of a segment refresh (M2): before the end of the last full refresh its
    /// events and stretches, after it the window's; maxima the extremes of both; alignment from the
    /// window, which describes now.
    static func merged(full: MotionAnalyzer.Output, fullEnd cut: Double, window w: MotionAnalyzer.Output) -> MotionAnalyzer.Output {
        var out = full
        let kept = full.details.events.filter { $0.peakTime < cut }
        // An event at the cut can be found by both, with peaks on either side of it: the window's
        // copy is dropped when it overlaps a kept one of the same kind (within the merge gap).
        let added = w.details.events.filter { e in
            e.peakTime >= cut && !kept.contains { k in
                k.kind == e.kind && e.start <= k.end + MotionConstants.eventMergeSeconds && k.start <= e.end + MotionConstants.eventMergeSeconds
            }
        }
        out.details.events = kept + added
        let newStretches = w.details.stretches.filter { $0.start >= cut }
        out.details.stretches = full.details.stretches.filter { $0.start < cut } + newStretches
        var m = full.summary
        func lo(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.min() }
        func hi(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.max() }
        m.maxBraking = lo(full.summary.maxBraking, w.summary.maxBraking)
        m.maxAcceleration = hi(full.summary.maxAcceleration, w.summary.maxAcceleration)
        m.maxLateralLeft = hi(full.summary.maxLateralLeft, w.summary.maxLateralLeft)
        m.maxLateralRight = lo(full.summary.maxLateralRight, w.summary.maxLateralRight)
        m.counts = MotionSummary.Counts()
        for e in out.details.events {
            switch e.kind {
            case .hardBraking:
                m.counts.hardBraking += 1
                if e.veryHard { m.counts.veryHardBraking += 1 }
            case .hardAcceleration: m.counts.hardAcceleration += 1
            case .lateralLeft: m.counts.lateralLeft += 1
            case .lateralRight: m.counts.lateralRight += 1
            case .bump: m.counts.bumps += 1
            }
        }
        for st in newStretches { m.roughnessMeters[st.roughness] += (st.speed ?? 0) * (st.end - st.start) }
        if w.summary.isAligned { m.alignedSegments = max(m.alignedSegments, 1) }
        out.summary = m
        return out
    }

    /// The GPS course's noise, degrees: Core Location's `courseAccuracy` when it gives one, else
    /// 30° over the speed (about 10° at 3 m/s, 3° at 10 m/s).
    static func courseSigma(_ f: Fix) -> Double {
        if let a = f.courseAccuracy, a > 0 { return a }
        return 30 / max(f.speed ?? 0, 3)
    }

    private var currentHorizontal: Double {
        horizontals.isEmpty ? 0 : simd_length(horizontalSum / Double(horizontals.count))
    }

    private func state(_ tail: MotionAnalyzer.LiveTail, at t: Double? = nil) -> State {
        if tail.fit == nil { return .aligning }
        if moved || swivelAt != nil || (t ?? lastTime ?? 0) < handlingUntil { return .moved }
        return .aligned
    }

    private func gyroHeading(at t: Double) -> (t: Double, h: Double)? {
        guard let first = headings.first, let last = headings.last, t >= first.t, t <= last.t + 0.05 else { return nil }
        var lo = 0, hi = headings.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if headings[mid].t <= t { lo = mid } else { hi = mid }
        }
        return headings[lo]
    }

    private func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
    }
}

/// The samples of a source from a time on, for the segment refresh (M2): the same analysis on a
/// shorter input.
nonisolated struct MotionSourceSlice<S: MotionSampleSource>: MotionSampleSource {
    let base: S
    let start: Int
    let count: Int

    init(_ base: S, from t: Double) {
        self.base = base
        var lo = 0, hi = base.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if base.time(mid) < t { lo = mid + 1 } else { hi = mid }
        }
        start = lo
        count = base.count - lo
    }

    func time(_ i: Int) -> Double { base.time(start + i) }
    func user(_ i: Int) -> SIMD3<Double> { base.user(start + i) }
    func gravity(_ i: Int) -> SIMD3<Double> { base.gravity(start + i) }
    func rotation(_ i: Int) -> SIMD3<Double> { base.rotation(start + i) }
    func sample(_ i: Int) -> MotionSample { base.sample(start + i) }
}
