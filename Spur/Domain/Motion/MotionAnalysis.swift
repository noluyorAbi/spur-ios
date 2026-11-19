import Foundation
import simd

/// The result of the motion analysis stored in `trip.json` (additive, SPEC 16.3.2 step 9).
nonisolated struct MotionSummary: Codable, Sendable, Equatable {
    static let currentVersion = 5

    struct Counts: Codable, Sendable, Equatable {
        var hardBraking = 0
        /// Of those, peak at or below -5 m/s².
        var veryHardBraking = 0
        var hardAcceleration = 0
        var lateralLeft = 0
        var lateralRight = 0
        var bumps = 0
    }

    var version = MotionSummary.currentVersion
    var analyzedAt: Date
    var sampleCount = 0
    /// Median sample rate, Hz.
    var rateHz: Double?
    /// Share of the trip time covered by samples (gaps above 0.5 s excluded).
    var coverage: Double?
    var sensorGaps = 0
    /// Mount segments (the phone moved in its mount in between).
    var segments = 0
    var alignedSegments = 0
    /// "Ausrichtung gut": r_long at least 0.7 in the aligned time.
    var alignmentGood = false
    var rLong: Double?
    var rLat: Double?
    /// Sensor time minus GPS time that fit best, seconds.
    var lagSeconds: Double?
    /// A reflection fit clearly better than a rotation (an odd axis convention): flagged, used.
    var reflected = false
    /// Share of the trip time inside handling windows (phone touched or moved).
    var handlingShare: Double?
    /// m/s², vehicle frame, low-passed at about 2 Hz; braking is negative, left is positive.
    var maxBraking: Double?
    var maxAcceleration: Double?
    var maxLateralLeft: Double?
    var maxLateralRight: Double?
    var counts = Counts()
    /// Meters driven per roughness class (glatt, normal, uneben, sehr uneben).
    var roughnessMeters: [Double] = [0, 0, 0, 0]

    // Version 2 (review of the motion sensor). Optional, so a version 1 summary still decodes.
    /// Share of the covered sample time that lies in aligned segments.
    var alignedShare: Double?
    /// The sensor's scale per aligned segment with turns, from the lateral axis (its gyro target
    /// is not smoothed by Core Location): 1 when it matches.
    var gains: [Double]?
    /// The same from the longitudinal axis, information only (Core Location smooths GPS speed).
    var gainsLong: [Double]?
    /// The correlation the alignment is judged by: stacked longitudinal and lateral when the speed
    /// changes beyond the GPS noise, else the lateral alone (version 3).
    var rFit: Double?
    /// True when `rFit` is the lateral alone (constant speed, a motorway).
    var rFitLateralOnly: Bool?
    /// Correlation of the gyro's yaw rate with the GPS course rate at 3 m/s or more, a sign check
    /// that needs no ground truth (a left turn turns the gyro positive about up).
    var rYaw: Double?
    /// r_yaw was clearly negative (a gravity or gyro sign problem): left and right were swapped.
    var yawSwapped: Bool?
    /// The best lag sat on the edge of the searched range: the GPS latency may be larger.
    var lagAtBoundary: Bool?
    /// Size of the analyzed `motion.bin`; an unchanged file at the same version is not re-run.
    var fileBytes: Int?
    /// Records skipped on reading (outside the trip, or not later than the record before).
    var rejectedRecords: Int?
    /// The vertical RMS while standing with the engine running (m/s², version 3), taken off the
    /// roughness.
    var vibrationRMS: Double?

    var gainsOK: Bool { (gains ?? []).allSatisfy { MotionConstants.gainRange.contains($0) } }
    var hasEnoughSamples: Bool { sampleCount >= MotionConstants.minSamples }
    /// Long and lat values exist (at least one segment aligned).
    var isAligned: Bool { alignedSegments > 0 }
}

/// One event of the motion analysis (SPEC 16.3.2 step 7).
nonisolated struct MotionEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case hardBraking, hardAcceleration, lateralLeft, lateralRight, bump
    }

    var kind: Kind
    var start: Double
    var end: Double
    /// m/s², signed as in the vehicle frame (braking negative, left positive, bump as |vert|).
    var peak: Double
    var peakTime: Double
    var latitude: Double?
    var longitude: Double?
    /// m/s at the peak, from the fixes.
    var speed: Double?
    var street: String?
    /// Version 4: the event continues across a short hand-at-work gap (a phone turned mid-brake).
    var acrossHandling: Bool?
    var veryHard: Bool { kind == .hardBraking && peak <= MotionConstants.veryHardBraking }
}

/// A 100 m stretch of the roughness analysis.
nonisolated struct MotionStretch: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    /// RMS of the high-passed vertical acceleration, m/s².
    var rms: Double
    /// 0 glatt, 1 normal, 2 uneben, 3 sehr uneben.
    var roughness: Int
    /// Mean speed over the stretch, m/s (version 2; `rms` is then normalised to 50 km/h).
    var speed: Double?
    var latitude: Double?
    var longitude: Double?
    var street: String?
}

/// The full analysis kept next to `motion.bin` (`motion-analysis.json`).
nonisolated struct MotionDetails: Codable, Sendable, Equatable {
    var version = MotionSummary.currentVersion
    var events: [MotionEvent] = []
    var stretches: [MotionStretch] = []
    /// Longitudinal acceleration for the chart: per 0.5 s, min and max (m/s²) and the time.
    var seriesTime: [Double] = []
    var seriesMin: [Double] = []
    var seriesMax: [Double] = []
    /// Width of one chart bucket in seconds (version 2; at most about 600 buckets per trip).
    var seriesStep: Double?
}

/// Thresholds of the motion analysis, in one place. The roughness classes are a first guess, to
/// be calibrated on the first real drive.
nonisolated enum MotionConstants {
    static let g = 9.80665
    static let minSamples = 100
    static let lowPassUpSeconds = 1.0
    static let mountChangeDegrees = 10.0
    static let mountChangeSeconds = 1.0
    /// A hand is at work when the phone turns by more than 10° about a horizontal axis within
    /// 0.5 s (net rotation, so mount vibration does not count; review item 1).
    static let handlingDegrees = 10.0
    static let handlingWindowSeconds = 0.5
    /// At standstill also a turn about the vertical: more than about 0.3 rad/s over 0.5 s.
    static let standstillYawRadians = 0.15
    static let standstillSpeed = 1.0
    static let handlingPadSeconds = 1.0
    /// An up change is a remount only with a hand at work within this time before it (grade and
    /// pitch change up slowly and without one); without a hand only beyond 25° from the settled
    /// up. Within a segment the basis follows the low-passed up (a slow tilt of the mount).
    static let remountHandlingSeconds = 2.0
    static let remountWithoutHandDegrees = 25.0
    /// A swivel marks as handling only where gyro and GPS yaw rate differ by more than this, padded
    /// by 0.25 s (second motion review, item 3).
    static let swivelRate = 0.2
    static let swivelPadSeconds = 0.25
    /// Standstill turns count as handling only when GPS shows no speed within -1 to +3.5 s (the lag
    /// range) and the horizontal acceleration stays below this (a moving car turning has it).
    static let standstillMaxHorizontal = 1.0
    /// A persistent heading step between gyro and GPS course on straight driving above this is a
    /// swivel of the mount about the vertical (review item 3).
    static let swivelDegrees = 10.0
    static let swivelMinSpeed = 3.0
    static let straightDegrees = 3.0
    static let targetMaxGapSeconds = 2.0
    static let targetMinSpeed = 3.0
    static let excitationTarget = 0.5
    /// The longitudinal targets count for the fit only when their variance exceeds this many times
    /// the variance the GPS speed noise alone would give.
    static let longInformativeFactor = 2.0
    /// r_yaw needs a GPS course rate of at least this somewhere (lane changes reach it).
    static let yawCheckMinRate = 0.03
    static let excitationCount = 20
    /// A target above this is not a car's acceleration (a GPS course or speed jump): not fitted.
    static let maxTarget = 8.0
    static let goodRLong = 0.7
    /// A segment's fitted gain outside this range is flagged (review item 6).
    static let gainRange = 0.85...1.15
    /// "Ausrichtung gut" also needs this share of the time aligned.
    static let goodAlignedShare = 0.9
    /// r_yaw below this means the gyro's turn sign disagrees with GPS (review item 7).
    static let yawFlipR = -0.5
    /// GPS speed lags the sensor by up to about 3 s on some phones (review item 17).
    static let lagRange = -3.0...1.0
    static let lagStep = 0.1
    static let eventLowPassHz = 2.0
    static let hardBraking = -3.0
    static let hardBrakingSeconds = 0.3
    static let veryHardBraking = -5.0
    static let hardAcceleration = 2.5
    static let hardAccelerationSeconds = 0.5
    static let lateral = 3.0
    static let lateralSeconds = 0.5
    /// Events end only 0.5 m/s² inside their threshold, and runs closer than 0.75 s are one
    /// (review item 2).
    static let eventHysteresis = 0.5
    static let eventMergeSeconds = 0.75
    static let bump = 4.0
    static let bumpMinSpeed = 3.0
    static let bumpMergeSeconds = 1.0
    /// A jolt sample must also stand out: at least 2.5 times the vertical's RMS over the centred
    /// second around it (engine vibration and a rough road do not; third motion review, item 1).
    static let bumpOverLocalRMS = 2.5
    /// An event interrupted by a hand at work for up to this long stays one event (item 4); the
    /// marked turn plus its 0.25 s pads.
    static let eventHandlingMergeSeconds = 1.0
    /// A swivel build-up longer than this is gyro drift unless fast turning carries half of it.
    static let swivelDriftSeconds = 15.0
    static let roughnessStretchM = 100.0
    static let roughnessMinSpeed = 5.0
    /// Roughness: vertical low-passed at 20 Hz (50 and 100 Hz files agree) and normalised to
    /// 50 km/h with the square root of the speed ratio (review item 18). First guess.
    static let roughnessLowPassHz = 20.0
    static let roughnessReferenceSpeed = 50 / 3.6
    static let roughnessSpeedExponent = 0.5
    /// Upper RMS bounds (m/s²) of glatt, normal, uneben; above: sehr uneben.
    static let roughnessBounds = [0.5, 1.0, 2.0]
    static let sensorGapSeconds = 0.5
    /// The chart keeps at most this many buckets per trip (review item 5).
    static let chartColumns = 600
}

/// The motion analysis (SPEC 16.3.2, revised after the review of the motion sensor). Pure; the
/// phone's mount angle is unknown, so the vehicle frame is derived per trip from the data:
/// vertical from gravity, the horizontal rotation fitted per mount segment against GPS
/// (longitudinal) and gyro times GPS speed (lateral). Physical acceleration is
/// `-userAcceleration * g` (CoreMotion reports minus the specific force). Per-sample data is kept
/// compact (Float, no copied samples), so an 8 hour trip stays in a bounded footprint.
nonisolated enum MotionAnalyzer {
    struct Output: Sendable {
        var summary: MotionSummary
        var details: MotionDetails
    }

    struct Fit: Sendable, Equatable {
        var theta: Double
        var reflected: Bool
        var sse: Double
        var pairs: Int
        var excited: Int
        /// The sensor's scale against GPS and gyro: 1 when it reads the same, 0.7 when it reads 70 %
        /// (the inverse of the least-squares scale of the targets on the measurement).
        var gain: Double
    }

    /// Per sample: the horizontal acceleration in its mount segment's basis, the vertical, the
    /// yaw rate about up, the segment, and whether a hand is at work.
    struct Frame {
        var time: [Double] = []
        var mx: [Float] = []
        var my: [Float] = []
        var vert: [Float] = []
        var wUp: [Float] = []
        var segment: [Int32] = []
        var rawHandling: [Bool] = []
        var handling: [Bool] = []
        /// Per segment (before swivels split it): the settled up and the horizontal basis built
        /// from it. Kept for the live estimator, which carries the last one forward.
        var refs: [SIMD3<Double>] = []
        var bases: [(SIMD3<Double>, SIMD3<Double>)] = []
        /// At the last sample: the 1 s low-passed up of the first pass, the reference it is held
        /// against (it follows grade), whether the segment is still settling, and the low-passed up
        /// the basis is carried to.
        var upLowPass = SIMD3<Double>(0, 0, 1)
        var upReference = SIMD3<Double>(0, 0, 1)
        var settling = true
        var basisUp = SIMD3<Double>(0, 0, 1)
    }

    /// Per sample in the vehicle frame, for the sensor CSV.
    struct VehicleFrame: Sendable {
        /// m/s², NaN where the mount segment is not aligned.
        var long: [Float]
        var lat: [Float]
        /// m/s², + up, gravity removed.
        var vert: [Float]
        var handling: [Bool]
    }

    static func analyze(samples: [MotionSample], fixes: [Fix], now: Date = Date(),
                        street: (Double) -> String? = { _ in nil }) -> Output {
        analyze(source: samples, fixes: fixes, now: now, street: street)
    }

    static func analyze<S: MotionSampleSource>(source s: S, fixes: [Fix], now: Date = Date(),
                                               street: (Double) -> String? = { _ in nil }) -> Output {
        analyze(s, fixes: fixes, now: now, street: street, solved: nil)
    }

    /// The analysis, from a solution already computed for these samples and fixes (the live
    /// estimator solves once and also reads the solution's tail), or solving here.
    private static func analyze<S: MotionSampleSource>(_ s: S, fixes: [Fix], now: Date, street: (Double) -> String?,
                                                       solved provided: Solution?) -> Output {
        var summary = MotionSummary(analyzedAt: now)
        var details = MotionDetails()
        let n = s.count
        summary.sampleCount = n
        guard n >= MotionConstants.minSamples else { return Output(summary: summary, details: details) }

        // Rate (median interval from a 10 µs histogram, no copy), coverage, gaps.
        var histogram = [Int32](repeating: 0, count: 50_001)
        var binSum = [Double](repeating: 0, count: 50_001)
        var covered = 0.0, intervals = 0
        var previous = s.time(0)
        for i in 1..<n {
            let t = s.time(i)
            let dt = t - previous
            previous = t
            if dt > MotionConstants.sensorGapSeconds {
                summary.sensorGaps += 1
            } else if dt > 0 {
                covered += dt
                let k = min(50_000, Int(dt * 100_000))
                histogram[k] += 1
                binSum[k] += dt
                intervals += 1
            }
        }
        var seen = 0
        for k in histogram.indices where histogram[k] > 0 {
            seen += Int(histogram[k])
            if seen * 2 >= intervals {
                summary.rateHz = Double(histogram[k]) / binSum[k]
                break
            }
        }
        if let first = fixes.first, let last = fixes.last, last.time > first.time {
            summary.coverage = min(1, covered / (last.time - first.time))
        } else {
            let span = s.time(n - 1) - s.time(0)
            summary.coverage = span > 0 ? min(1, covered / span) : nil
        }

        let solved = provided ?? solve(s, fixes)
        let f = solved.frame
        summary.segments = Int(f.segment[n - 1]) + 1
        var handlingTime = 0.0, alignedTime = 0.0
        for i in 1..<n {
            let dt = f.time[i] - f.time[i - 1]
            guard dt > 0, dt <= MotionConstants.sensorGapSeconds else { continue }
            if f.handling[i] { handlingTime += dt }
            if solved.aligned[f.segment[i]] != nil { alignedTime += dt }
        }
        let span = f.time[n - 1] - f.time[0]
        summary.handlingShare = span > 0 ? handlingTime / span : nil
        summary.alignedSegments = solved.aligned.count
        summary.alignedShare = covered > 0 ? min(1, alignedTime / covered) : nil
        summary.reflected = solved.reflectedAny
        // With only lateral excitation (a motorway) the lag is undetermined: gyro and speed share
        // the sensor clock, and the speed hardly changes. It is then not reported.
        if let lag = solved.lag, !solved.rFitLateralOnly {
            summary.lagSeconds = (lag * 10).rounded() / 10
            if abs(lag - MotionConstants.lagRange.lowerBound) < 1e-6 || abs(lag - MotionConstants.lagRange.upperBound) < 1e-6 {
                summary.lagAtBoundary = true
            }
        }
        func rounded(_ g: [Int32: Double]) -> [Double]? {
            let v = g.keys.sorted().compactMap { g[$0] }.map { ($0 * 1000).rounded() / 1000 }
            return v.isEmpty ? nil : v
        }
        summary.gains = rounded(solved.gains)
        summary.gainsLong = rounded(solved.gainsLong)
        summary.rLong = solved.rLong
        summary.rLat = solved.rLat
        summary.rFit = solved.rFit
        if solved.rFitLateralOnly { summary.rFitLateralOnly = true }
        summary.rYaw = solved.rYaw
        if solved.yawSwapped { summary.yawSwapped = true }
        // Judged by the gate's r (longitudinal and lateral stacked, or the lateral alone at a
        // constant speed). Good also needs most of the time aligned, lateral gains near 1 and the
        // turn sign confirmed.
        summary.alignmentGood = summary.isAligned
            && (solved.rFit ?? 0) >= MotionConstants.goodRLong
            && (summary.alignedShare ?? 0) >= MotionConstants.goodAlignedShare
            && summary.gainsOK && !solved.yawSwapped

        // Speed and position at a sensor time (GPS time = sensor time - lag).
        let shift = summary.lagSeconds ?? 0
        let track = Track1D(fixes)
        func speed(_ t: Double) -> Double? { track.speed(at: t - shift) }

        // Low-passed vehicle frame (about 2 Hz), NaN outside aligned segments.
        let lpLong = smooth((0..<n).map { Float(solved.long($0)) }, time: f.time)
        let lpLat = smooth((0..<n).map { Float(solved.lat($0)) }, time: f.time)
        let vertHP = highPass(f.vert, time: f.time)
        // The vertical low-passed at 20 Hz: engine vibration (30 Hz and up) neither makes jolts nor
        // roughness, and 50 and 100 Hz files agree.
        var vertLP = vertHP
        var lp20 = Biquad.lowPass(cutoff: MotionConstants.roughnessLowPassHz, rate: summary.rateHz ?? 100)
        for i in 0..<n {
            if i > 0 && f.time[i] - f.time[i - 1] > MotionConstants.sensorGapSeconds { lp20?.reset() }
            if var filter = lp20 {
                vertLP[i] = Float(filter.step(Double(vertHP[i])))
                lp20 = filter
            }
        }

        // Maxima and events.
        var events: [MotionEvent] = []
        func event(_ kind: MotionEvent.Kind, _ a: Int, _ b: Int, peakIndex k: Int, peak: Double) {
            let pos = track.position(at: f.time[k] - shift)
            events.append(MotionEvent(kind: kind, start: f.time[a], end: f.time[b], peak: peak, peakTime: f.time[k],
                                      latitude: pos?.lat, longitude: pos?.lon, speed: speed(f.time[k]), street: street(f.time[k] - shift)))
        }
        if summary.isAligned {
            for i in 0..<n where !f.handling[i] && !lpLong[i].isNaN {
                summary.maxBraking = min(summary.maxBraking ?? 0, Double(lpLong[i]))
                summary.maxAcceleration = max(summary.maxAcceleration ?? 0, Double(lpLong[i]))
                summary.maxLateralLeft = max(summary.maxLateralLeft ?? 0, Double(lpLat[i]))
                summary.maxLateralRight = min(summary.maxLateralRight ?? 0, Double(lpLat[i]))
            }
        }
        func usable(_ x: [Float], _ i: Int, _ sign: Double) -> Double {
            f.handling[i] || x[i].isNaN ? .nan : sign * Double(x[i])
        }
        let h = MotionConstants.eventHysteresis, merge = MotionConstants.eventMergeSeconds
        let kinds: [(MotionEvent.Kind, [Float], Double, Double, Double)] = [
            (.hardBraking, lpLong, -1, -MotionConstants.hardBraking, MotionConstants.hardBrakingSeconds),
            (.hardAcceleration, lpLong, 1, MotionConstants.hardAcceleration, MotionConstants.hardAccelerationSeconds),
            (.lateralLeft, lpLat, 1, MotionConstants.lateral, MotionConstants.lateralSeconds),
            (.lateralRight, lpLat, -1, MotionConstants.lateral, MotionConstants.lateralSeconds),
        ]
        for (kind, x, sign, enter, minSeconds) in kinds {
            for run in hysteresisRuns(f.time, enter: enter, exit: enter - h, minSeconds: minSeconds, merge: merge,
                                      handlingMerge: MotionConstants.eventHandlingMergeSeconds, isHandling: { f.handling[$0] },
                                      value: { usable(x, $0, sign) }) {
                let k = (run.a...run.b).max { usable(x, $0, sign).nanLowest < usable(x, $1, sign).nanLowest }!
                event(kind, run.a, run.b, peakIndex: k, peak: Double(x[k]))
                if run.acrossHandling { events[events.count - 1].acrossHandling = true }
            }
        }
        // Jolts: also in unaligned segments, never while handling, at 3 m/s or more, on the 20 Hz
        // low-passed vertical and at least 20 ms beyond the threshold (engine vibration is neither).
        // A sample counts when it stands out of the vertical's RMS over the centred second (a running
        // window, called in order), so short jolts count and steady vibration does not.
        var local = SlidingRMS(time: f.time, values: vertLP, half: 0.5)
        let bumpValue: (Int) -> Double = { i in
            let v = f.handling[i] || (speed(f.time[i]) ?? 0) < MotionConstants.bumpMinSpeed ? .nan : abs(Double(vertLP[i]))
            let rms = local.at(i)
            return v.isNaN || v >= MotionConstants.bumpOverLocalRMS * rms ? v : 0
        }
        for run in hysteresisRuns(f.time, enter: MotionConstants.bump, exit: MotionConstants.bump - h, minSeconds: 0,
                                  merge: MotionConstants.bumpMergeSeconds, value: bumpValue) {
            let k = (run.a...run.b).max { abs(vertLP[$0]) < abs(vertLP[$1]) }!
            event(.bump, run.a, run.b, peakIndex: k, peak: abs(Double(vertLP[k])))
        }
        events.sort { $0.peakTime < $1.peakTime }
        for e in events {
            switch e.kind {
            case .hardBraking:
                summary.counts.hardBraking += 1
                if e.veryHard { summary.counts.veryHardBraking += 1 }
            case .hardAcceleration: summary.counts.hardAcceleration += 1
            case .lateralLeft: summary.counts.lateralLeft += 1
            case .lateralRight: summary.counts.lateralRight += 1
            case .bump: summary.counts.bumps += 1
            }
        }
        details.events = events

        // Roughness per 100 m driven at 5 m/s or more, outside handling: RMS of the high-passed,
        // 20 Hz low-passed vertical less the vibration floor, normalised to 50 km/h. The floor is
        // the RMS while standing with the engine running, scaled by how much of that vibration is
        // still there while driving: above 20 Hz a road adds almost nothing, so the ratio of that
        // band's energy while driving to its energy at idle tells (1 for sensor noise or an engine
        // that shakes all the time, small for one that shakes only at idle). Without an idle
        // measurement (start-stop, an EV) there is no floor (third motion review, item 6).
        var idleSum = 0.0, idleCount = 0, idleHigh = 0.0, driveHigh = 0.0, driveCount = 0
        for i in 0..<n where !f.handling[i] {
            guard let v = speed(f.time[i]) else { continue }
            let high = Double(vertHP[i]) - Double(vertLP[i])
            if v < 0.5 {
                idleSum += Double(vertLP[i]) * Double(vertLP[i])
                idleHigh += high * high
                idleCount += 1
            } else if v >= MotionConstants.roughnessMinSpeed {
                driveHigh += high * high
                driveCount += 1
            }
        }
        var raws: [RawStretch] = []
        var meters = 0.0, sum = 0.0, count = 0, startIndex = 0, speedSum = 0.0
        for i in 1..<n {
            let dt = f.time[i] - f.time[i - 1]
            let y = Double(vertLP[i])
            guard dt > 0, dt <= MotionConstants.sensorGapSeconds, let v = speed(f.time[i]), v >= MotionConstants.roughnessMinSpeed,
                  !f.handling[i] else { continue }
            if count == 0 { startIndex = i }
            meters += v * dt
            sum += y * y
            speedSum += v
            count += 1
            if meters >= MotionConstants.roughnessStretchM {
                raws.append(RawStretch(start: startIndex, end: i, ms: sum / Double(count), speed: speedSum / Double(count), meters: meters))
                meters = 0
                sum = 0
                speedSum = 0
                count = 0
            }
        }
        var floor2 = 0.0
        if idleCount >= 100 {
            let idle = idleSum / Double(idleCount)
            let persists = driveCount >= 100 && idleHigh > 0 ? min(1, (driveHigh / Double(driveCount)) / (idleHigh / Double(idleCount))) : 1
            floor2 = idle * persists
            summary.vibrationRMS = (floor2.squareRoot() * 1000).rounded() / 1000
        }
        for r in raws {
            // The floor may take up to the stretch's whole power: on a smooth road the stretch IS the
            // vibration (a cap at a quarter of the power let 87 % of engine vibration read as
            // roughness; final physics review, R1). The persistence ratio above already keeps an
            // idle-only shake from eating a rough road.
            let rms = (r.ms - min(floor2, r.ms)).squareRoot()
                * pow(MotionConstants.roughnessReferenceSpeed / r.speed, MotionConstants.roughnessSpeedExponent)
            let cls = MotionConstants.roughnessBounds.firstIndex { rms < $0 } ?? 3
            let mid = (f.time[r.start] + f.time[r.end]) / 2
            let pos = track.position(at: mid - shift)
            details.stretches.append(MotionStretch(start: f.time[r.start], end: f.time[r.end], rms: rms, roughness: cls,
                                                   speed: r.speed, latitude: pos?.lat, longitude: pos?.lon, street: street(mid - shift)))
            summary.roughnessMeters[cls] += r.meters
        }

        // Chart: min and max of the longitudinal acceleration per bucket, at most about 600 per trip.
        if summary.isAligned {
            let width = max(0.5, span / Double(MotionConstants.chartColumns))
            details.seriesStep = width
            var bucket = 0
            var lo = Float.infinity, hi = -Float.infinity
            func flush() {
                if lo.isFinite {
                    details.seriesTime.append(f.time[0] + Double(bucket) * width)
                    details.seriesMin.append(Double(lo))
                    details.seriesMax.append(Double(hi))
                }
                lo = .infinity
                hi = -.infinity
            }
            for i in 0..<n {
                let k = Int((f.time[i] - f.time[0]) / width)
                if k != bucket {
                    flush()
                    bucket = k
                }
                if !lpLong[i].isNaN && !f.handling[i] {
                    lo = min(lo, lpLong[i])
                    hi = max(hi, lpLong[i])
                }
            }
            flush()
        }
        return Output(summary: summary, details: details)
    }

    /// The vehicle frame of every sample, from the same solution as the analysis (sensor CSV).
    static func vehicleFrame(samples: [MotionSample], fixes: [Fix]) -> VehicleFrame {
        vehicleFrame(source: samples, fixes: fixes)
    }

    static func vehicleFrame<S: MotionSampleSource>(source s: S, fixes: [Fix]) -> VehicleFrame {
        let n = s.count
        guard n >= MotionConstants.minSamples else {
            // Too short to fit (as in the analysis): vertical and handling only.
            var f = frame(s)
            f.handling = pad(f.rawHandling, time: f.time)
            return VehicleFrame(long: [Float](repeating: .nan, count: n), lat: [Float](repeating: .nan, count: n), vert: f.vert, handling: f.handling)
        }
        let solved = solve(s, fixes)
        return VehicleFrame(long: (0..<n).map { Float(solved.long($0)) }, lat: (0..<n).map { Float(solved.lat($0)) },
                            vert: solved.frame.vert, handling: solved.frame.handling)
    }

    // MARK: Live (SPEC 17.3)

    /// What the live estimator carries forward from a solution: the last sample's basis and
    /// filter states, and the fit of its segment.
    struct LiveTail: Sendable {
        var time: Double
        var upLowPass: SIMD3<Double>
        var upReference: SIMD3<Double>
        var settling: Bool
        var basisUp: SIMD3<Double>
        /// The settled up the basis was built from, and the basis itself (before the tilt).
        var segmentUp: SIMD3<Double>
        var e1: SIMD3<Double>
        var e2: SIMD3<Double>
        /// The last segment's fit when that segment is aligned (never a reflection), else nil.
        var fit: Fit?
        var yawSwapped: Bool
        var handling: Bool
        /// The trip's lag (sensor time minus GPS time), nil when not determined.
        var lag: Double?
        /// Time of the first sample of the last segment (after swivel splits).
        var segmentStart: Double
    }

    struct LiveSolution: Sendable {
        var output: Output
        var tail: LiveTail?
        /// The 2 Hz longitudinal acceleration of the last `recentSeconds`, NaN where unaligned or
        /// handling, the same signal as the trip chart and the maxima.
        var recentTime: [Double] = []
        var recentLong: [Float] = []
        /// With `checkFrom`: the last segment's fit on the pairs after that time.
        var recent: RecentFit?
    }

    /// The analysis of the samples and fixes so far, solved once, plus what the live estimator
    /// needs to continue from its last sample. `output` is exactly `analyze(source:fixes:now:)`.
    static func live<S: MotionSampleSource>(source s: S, fixes: [Fix], now: Date, recentSeconds: Double = 60,
                                            checkFrom: Double? = nil) -> LiveSolution {
        let n = s.count
        guard n >= MotionConstants.minSamples else {
            return LiveSolution(output: analyze(s, fixes: fixes, now: now, street: { _ in nil }, solved: nil))
        }
        let solved = solve(s, fixes, recentFrom: checkFrom)
        let output = analyze(s, fixes: fixes, now: now, street: { _ in nil }, solved: solved)
        let f = solved.frame
        let seg = max(0, min(Int(solved.baseSegmentLast), f.bases.count - 1))
        var first = n - 1
        while first > 0 && f.segment[first - 1] == f.segment[n - 1] { first -= 1 }
        let tail = LiveTail(time: f.time[n - 1], upLowPass: f.upLowPass, upReference: f.upReference, settling: f.settling,
                            basisUp: f.basisUp, segmentUp: f.refs[seg], e1: f.bases[seg].0, e2: f.bases[seg].1,
                            fit: solved.aligned[f.segment[n - 1]], yawSwapped: solved.yawSwapped, handling: f.handling[n - 1],
                            lag: solved.lag, segmentStart: f.time[first])
        let end = f.time[n - 1]
        var a = n - 1
        while a > 0 && f.time[a - 1] >= end - recentSeconds - 0.5 { a -= 1 }
        let time = Array(f.time[a..<n])
        let raw = (a..<n).map { f.handling[$0] ? Float.nan : Float(solved.long($0)) }
        let smoothed = smooth(raw, time: time)
        var out = LiveSolution(output: output, tail: tail)
        out.recent = solved.recent
        for (k, t) in time.enumerated() where t >= end - recentSeconds {
            out.recentTime.append(t)
            out.recentLong.append(smoothed[k])
        }
        return out
    }

    /// The horizontal acceleration in a basis carried by the minimal rotation from `from` to
    /// `lowPassUp`, as `frame` computes `mx`, `my`.
    static func basisComponents(_ sample: MotionSample, e1: SIMD3<Double>, e2: SIMD3<Double>, from: SIMD3<Double>,
                                lowPassUp: SIMD3<Double>) -> (Double, Double) {
        let u = up(SIMD3<Double>(sample.gravity))
        let a = -SIMD3<Double>(sample.userAcceleration) * MotionConstants.g
        let ah = a - simd_dot(a, u) * u
        var (b1, b2) = (e1, e2)
        let axis = simd_cross(from, lowPassUp), sn = simd_length(axis)
        if sn > 1e-9 {
            let q = simd_quatd(angle: atan2(sn, simd_dot(from, lowPassUp)), axis: axis / sn)
            b1 = q.act(b1)
            b2 = q.act(b2)
        }
        return (simd_dot(ah, b1), simd_dot(ah, b2))
    }

    /// Up from gravity, as the analysis uses it.
    static func upVector(_ sample: MotionSample) -> SIMD3<Double> { up(SIMD3<Double>(sample.gravity)) }

    // MARK: Solution

    private struct Solution {
        var frame: Frame
        /// The trip's lag, nil when no segment has enough excitation.
        var lag: Double?
        /// The segments used: enough excitation, a rotation (not a reflection), r at least 0.7.
        var aligned: [Int32: Fit]
        var reflectedAny: Bool
        var rLong: Double?
        var rLat: Double?
        var rFit: Double?
        var rFitLateralOnly: Bool
        /// Per aligned segment: the lateral gain (nil without turns) and the longitudinal one.
        var gains: [Int32: Double]
        var gainsLong: [Int32: Double]
        var rYaw: Double?
        var yawSwapped: Bool
        /// The last sample's segment before swivels split segments (the basis `mx`/`my` use).
        var baseSegmentLast: Int32 = 0
        /// The live estimator's check of the last segment's fit on the pairs after a time.
        var recent: RecentFit?

        func long(_ i: Int) -> Double {
            guard let fit = aligned[frame.segment[i]] else { return .nan }
            return MotionAnalyzer.rotate(Double(frame.mx[i]), Double(frame.my[i]), fit.theta).0
        }

        func lat(_ i: Int) -> Double {
            guard let fit = aligned[frame.segment[i]] else { return .nan }
            let y = MotionAnalyzer.rotate(Double(frame.mx[i]), Double(frame.my[i]), fit.theta).1
            return yawSwapped ? -y : y
        }
    }

    /// Mount segments (an up change with a hand at work, or a heading step against GPS), handling
    /// windows, the fit per segment with one lag for the trip, the quality and the yaw check.
    /// Shared by the analysis and the sensor CSV, so both use the same numbers.
    private static func solve<S: MotionSampleSource>(_ s: S, _ fixes: [Fix], recentFrom: Double? = nil) -> Solution {
        var f = frame(s)
        let baseSegmentLast = f.segment.last ?? 0
        let track = Track1D(fixes)
        standstillHandling(&f, track: track)
        f.handling = pad(f.rawHandling, time: f.time)
        // A swivel starts a new segment; only the samples that actually turn count as handling,
        // padded by 0.25 s (a short turn must not blank a brake around it).
        var marks = [Bool](repeating: false, count: f.time.count)
        for swivel in swivels(f, fixes) {
            for i in swivel.start..<f.segment.count { f.segment[i] += 1 }
            for i in swivel.marked { marks[i] = true }
        }
        let marked = pad(marks, time: f.time, seconds: MotionConstants.swivelPadSeconds)
        for i in marked.indices where marked[i] { f.handling[i] = true }
        let bins = Bins(f)
        let targets = Self.targets(fixes)

        var best: (lag: Double, fits: [Int32: Fit], sse: Double, count: Int)?
        var lag = MotionConstants.lagRange.lowerBound
        while lag <= MotionConstants.lagRange.upperBound + 1e-9 {
            let fits = Self.fits(targets, bins: bins, lag: lag)
            let excited = fits.values.filter { $0.excited >= MotionConstants.excitationCount }
            let sse = excited.reduce(0) { $0 + $1.sse / Double(max(1, $1.pairs)) }
            if !excited.isEmpty, best == nil || excited.count > best!.count || (excited.count == best!.count && sse < best!.sse) {
                best = (lag, fits, sse, excited.count)
            }
            lag += MotionConstants.lagStep
        }
        guard let best else {
            return Solution(frame: f, lag: nil, aligned: [:], reflectedAny: false, rLong: nil, rLat: nil, rFit: nil,
                            rFitLateralOnly: false, gains: [:], gainsLong: [:], rYaw: yawCorrelation(fixes, bins: bins, lag: 0),
                            yawSwapped: false, baseSegmentLast: baseSegmentLast)
        }
        // Each segment on its own quality; a reflection can only mean bad data or a sign bug.
        var pairs: [Int32: Pairs] = [:]
        for t in targets {
            guard let m = bins.average(t.t0 + best.lag, t.t1 + best.lag), let fit = best.fits[m.segment],
                  (t.long * t.long + t.speed * m.w * t.speed * m.w).squareRoot() <= MotionConstants.maxTarget else { continue }
            let (x, y) = rotate(m.mx, fit.reflected ? -m.my : m.my, fit.theta)
            pairs[m.segment, default: Pairs()].append(x, t.long, y, t.speed * m.w)
        }
        let noise = longNoiseVariance(fixes)
        var aligned: [Int32: Fit] = [:]
        var gains: [Int32: Double] = [:], gainsLong: [Int32: Double] = [:]
        var all = Pairs()
        for (segment, fit) in best.fits where fit.excited >= MotionConstants.excitationCount && !fit.reflected {
            guard let p = pairs[segment], (p.r(noise: noise).r ?? 0) >= MotionConstants.goodRLong else { continue }
            aligned[segment] = fit
            gains[segment] = p.gain(\.fa, \.ta)
            gainsLong[segment] = p.gain(\.fl, \.tl)
            all.fl += p.fl
            all.tl += p.tl
            all.fa += p.fa
            all.ta += p.ta
        }
        let overall = all.r(noise: noise)
        // r_yaw at the lag where |r| peaks: on a lateral-only trip the fit's lag is undetermined,
        // and the sign check must not depend on it (third motion review, item 3).
        var rYaw: Double?
        var yawLag = MotionConstants.lagRange.lowerBound
        while yawLag <= MotionConstants.lagRange.upperBound + 1e-9 {
            if let r = yawCorrelation(fixes, bins: bins, lag: yawLag), abs(r) > abs(rYaw ?? 0) { rYaw = r }
            yawLag += MotionConstants.lagStep
        }
        var recent: RecentFit?
        if let from = recentFrom, let lastSegment = f.segment.last, let fit = aligned[lastSegment] {
            recent = recentFit(targets.filter { $0.t0 + best.lag >= from }, bins: bins, lag: best.lag, segment: lastSegment,
                               fit: fit, noise: noise)
        }
        var solution = Solution(frame: f, lag: best.lag, aligned: aligned,
                        reflectedAny: best.fits.values.contains { $0.excited >= MotionConstants.excitationCount && $0.reflected },
                        rLong: aligned.isEmpty ? nil : pearson(all.fl, all.tl), rLat: aligned.isEmpty ? nil : pearson(all.fa, all.ta),
                        rFit: aligned.isEmpty ? nil : overall.r, rFitLateralOnly: !aligned.isEmpty && overall.lateralOnly,
                        gains: gains, gainsLong: gainsLong, rYaw: rYaw, yawSwapped: (rYaw ?? 0) < MotionConstants.yawFlipR,
                        baseSegmentLast: baseSegmentLast)
        solution.recent = recent
        return solution
    }

    /// How the last segment's fit does on the pairs after a time: the same pairs and the same r
    /// as the gate, with the segment's rotation, and a refit of the rotation on those pairs alone.
    struct RecentFit: Sendable, Equatable {
        /// r of the recent pairs in the segment's rotation (stacked, as the gate).
        var r: Double?
        /// The rotation fitted on the recent pairs alone, minus the segment's, radians.
        var thetaChange: Double
        var reflected: Bool
        /// Recent pairs with at least 0.5 m/s² of target.
        var excited: Int
    }

    private static func recentFit(_ targets: [Target], bins: Bins, lag: Double, segment: Int32, fit: Fit, noise: Double) -> RecentFit? {
        guard let refit = fits(targets, bins: bins, lag: lag)[segment] else { return nil }
        var pairs = Pairs()
        for t in targets {
            guard let m = bins.average(t.t0 + lag, t.t1 + lag), m.segment == segment,
                  (t.long * t.long + t.speed * m.w * t.speed * m.w).squareRoot() <= MotionConstants.maxTarget else { continue }
            let (x, y) = rotate(m.mx, m.my, fit.theta)
            pairs.append(x, t.long, y, t.speed * m.w)
        }
        return RecentFit(r: pairs.r(noise: noise).r, thetaChange: wrapPi(refit.theta - fit.theta), reflected: refit.reflected,
                         excited: refit.excited)
    }

    /// Fitted against target, per axis.
    private struct Pairs {
        var fl: [Double] = [], tl: [Double] = [], fa: [Double] = [], ta: [Double] = []

        mutating func append(_ x: Double, _ long: Double, _ y: Double, _ lat: Double) {
            fl.append(x)
            tl.append(long)
            fa.append(y)
            ta.append(lat)
        }

        /// The correlation that judges a fit: longitudinal and lateral stacked. When the speed
        /// changes no more than GPS noise alone could explain (a motorway, where the longitudinal
        /// target is noise), the lateral alone may stand in if it is better; it never vetoes a fit
        /// the stacked one accepts (Core Location's speed accuracy overstates the noise of
        /// consecutive, filtered speeds).
        func r(noise: Double) -> (r: Double?, lateralOnly: Bool) {
            let stacked = MotionAnalyzer.pearson(fl + fa, tl + ta)
            guard MotionAnalyzer.variance(tl) <= MotionConstants.longInformativeFactor * noise,
                  let lateral = MotionAnalyzer.pearson(fa, ta), lateral > (stacked ?? -1) else { return (stacked, false) }
            return (lateral, true)
        }

        /// The sensor's scale on one axis (measured over target, least squares), from pairs with
        /// at least 0.5 m/s² of target; nil with fewer than 10 of them.
        func gain(_ measured: KeyPath<Pairs, [Double]>, _ target: KeyPath<Pairs, [Double]>) -> Double? {
            let m = self[keyPath: measured], t = self[keyPath: target]
            var mt = 0.0, tt = 0.0, count = 0
            for (a, b) in zip(m, t) where abs(b) >= MotionConstants.excitationTarget {
                mt += a * b
                tt += b * b
                count += 1
            }
            return count >= 10 && tt > 0 ? mt / tt : nil
        }
    }

    static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count - 1)
    }

    /// The variance of a 1 s speed difference from GPS noise alone: 2 σ², with σ the larger of
    /// the median speed accuracy Core Location states (0.3 m/s when it states none) and the noise
    /// measured from the data: the robust spread of the second difference of consecutive 1 s
    /// speeds (white noise gives 6 σ², while real acceleration changes slowly and barely
    /// contributes; third motion review, item 5).
    private static func longNoiseVariance(_ fixes: [Fix]) -> Double {
        let accuracies = fixes.compactMap { $0.speedAccuracy }.filter { $0 >= 0 }.sorted()
        let reported = accuracies.isEmpty ? 0.3 : accuracies[accuracies.count / 2]
        var second: [Double] = []
        if fixes.count >= 3 {
            for k in 1..<(fixes.count - 1) {
                let a = fixes[k - 1], b = fixes[k], c = fixes[k + 1]
                guard let va = a.speed, let vb = b.speed, let vc = c.speed, va >= 3, vb >= 3, vc >= 3,
                      abs(b.time - a.time - 1) < 0.25, abs(c.time - b.time - 1) < 0.25 else { continue }
                second.append(abs(va - 2 * vb + vc))
            }
        }
        var measured = 0.0
        if second.count >= 20 {
            second.sort()
            measured = 1.4826 * second[second.count / 2] / 6.0.squareRoot()
        }
        let sigma = max(reported, measured)
        return 2 * sigma * sigma
    }

    static func rotate(_ x: Double, _ y: Double, _ theta: Double) -> (Double, Double) {
        let c = cos(theta), s = sin(theta)
        return (x * c - y * s, x * s + y * c)
    }

    @inline(__always) private static func up(_ g: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(g)
        return l > 1e-6 ? -g / l : SIMD3<Double>(0, 0, 1)
    }

    @inline(__always) private static func dt<S: MotionSampleSource>(_ s: S, _ i: Int) -> Double {
        i == 0 ? 0 : min(MotionConstants.handlingWindowSeconds, max(0, s.time(i) - s.time(i - 1)))
    }

    /// Steps 1 to 3: vertical, mount segments, each segment's horizontal basis from its settled
    /// up, and the hand-at-work samples. A segment starts when the low-passed up leaves the
    /// reference by more than 10° for 1 s and a hand was at work around it; without one (grade,
    /// pitch) the reference follows. A hand is at work when the phone turns by more than 10°
    /// about a horizontal axis within 0.5 s.
    private static func frame<S: MotionSampleSource>(_ s: S) -> Frame {
        var f = Frame()
        let n = s.count
        f.time = [Double](repeating: 0, count: n)
        f.vert = [Float](repeating: 0, count: n)
        f.wUp = [Float](repeating: 0, count: n)
        f.segment = [Int32](repeating: 0, count: n)
        f.rawHandling = [Bool](repeating: false, count: n)
        var lp = SIMD3<Double>(0, 0, 1)
        var ref = SIMD3<Double>(0, 0, 1)
        var refs: [SIMD3<Double>] = []
        var segment: Int32 = 0
        var exceedSince: Double?
        var settling = true
        var settleRef = SIMD3<Double>(0, 0, 1)
        var settleSince = 0.0
        var lastHandling = -Double.infinity
        var window = SIMD3<Double>.zero
        var lo = 0
        let limit = MotionConstants.handlingDegrees * .pi / 180
        func horizontalRate(_ j: Int) -> SIMD3<Double> {
            let u = up(s.gravity(j)), w = s.rotation(j)
            return w - simd_dot(w, u) * u
        }
        func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
        }
        for i in 0..<n {
            let t = s.time(i)
            let u = up(s.gravity(i))
            let a = -s.user(i) * MotionConstants.g
            let w = s.rotation(i)
            f.time[i] = t
            // Net horizontal rotation over the last 0.5 s.
            window += (w - simd_dot(w, u) * u) * dt(s, i)
            while lo < i && t - f.time[lo] > MotionConstants.handlingWindowSeconds {
                window -= horizontalRate(lo) * dt(s, lo)
                lo += 1
            }
            if simd_length(window) > limit {
                f.rawHandling[i] = true
                lastHandling = t
            }
            if i == 0 {
                lp = u
                settleRef = u
                settleSince = t
            } else {
                let d = max(0, t - f.time[i - 1])
                lp = simd_normalize(lp + (u - lp) * (d / (MotionConstants.lowPassUpSeconds + d)))
            }
            if settling {
                if angle(lp, settleRef) > 1 {
                    settleRef = lp
                    settleSince = t
                } else if t - settleSince >= MotionConstants.mountChangeSeconds {
                    ref = simd_normalize(lp)
                    refs.append(ref)
                    settling = false
                    exceedSince = nil
                }
            } else if angle(lp, ref) > MotionConstants.mountChangeDegrees {
                let since = exceedSince ?? t
                exceedSince = since
                if t - since >= MotionConstants.mountChangeSeconds {
                    if lastHandling >= since - MotionConstants.remountHandlingSeconds
                        || angle(lp, refs.last ?? ref) > MotionConstants.remountWithoutHandDegrees {
                        segment += 1
                        settling = true
                        settleRef = lp
                        settleSince = t
                        // The samples since the change started belong to the new mount.
                        var k = i
                        while k > 0 && f.time[k - 1] >= since {
                            k -= 1
                            f.segment[k] = segment
                        }
                    } else {
                        // No hand: grade or pitch. The reference follows, the basis stays.
                        ref = simd_normalize(lp)
                        exceedSince = nil
                    }
                }
            } else {
                exceedSince = nil
            }
            f.vert[i] = Float(simd_dot(a, u))
            f.wUp[i] = Float(simd_dot(w, u))
            f.segment[i] = segment
        }
        while refs.count <= Int(segment) { refs.append(simd_normalize(lp)) }
        f.upLowPass = lp
        f.upReference = ref
        f.settling = settling
        // Second pass: each segment's horizontal basis from its settled up.
        let bases = refs.map { u -> (SIMD3<Double>, SIMD3<Double>) in
            var x = SIMD3<Double>(1, 0, 0) - u.x * u
            if simd_length(x) < 0.3 { x = SIMD3<Double>(0, 1, 0) - u.y * u }
            x = simd_normalize(x)
            return (x, simd_cross(u, x))
        }
        f.mx = [Float](repeating: 0, count: n)
        f.my = [Float](repeating: 0, count: n)
        // The basis follows a slow tilt of the mount: carried from the segment's settled up to the
        // low-passed up (replayed here, the same filter as in the first pass) by the minimal
        // rotation, so a tilt never shrinks the longitudinal by cos(tilt).
        var lp2 = SIMD3<Double>(0, 0, 1)
        for i in 0..<n {
            let u = up(s.gravity(i))
            if i == 0 {
                lp2 = u
            } else {
                let d = max(0, f.time[i] - f.time[i - 1])
                lp2 = simd_normalize(lp2 + (u - lp2) * (d / (MotionConstants.lowPassUpSeconds + d)))
            }
            let a = -s.user(i) * MotionConstants.g
            let ah = a - simd_dot(a, u) * u
            let seg = min(Int(f.segment[i]), bases.count - 1)
            var (e1, e2) = bases[seg]
            let from = refs[seg]
            let axis = simd_cross(from, lp2), sn = simd_length(axis)
            if sn > 1e-9 {
                let q = simd_quatd(angle: atan2(sn, simd_dot(from, lp2)), axis: axis / sn)
                e1 = q.act(e1)
                e2 = q.act(e2)
            }
            f.mx[i] = Float(simd_dot(ah, e1))
            f.my[i] = Float(simd_dot(ah, e2))
        }
        f.refs = refs
        f.bases = bases
        f.basisUp = lp2
        return f
    }

    /// At standstill a turn about the vertical is a hand too (the phone turned in its tray). Only
    /// when GPS shows no speed anywhere in the lag range (-1 to +3.5 s, so a lagging GPS never
    /// calls a pull-away into a turn a standstill) and the horizontal acceleration stays low (a
    /// turning car has centripetal acceleration, a hand does not).
    private static func standstillHandling(_ f: inout Frame, track: Track1D) {
        let n = f.time.count
        var sum = 0.0, sx = 0.0, sy = 0.0, count = 0, lo = 0
        func d(_ j: Int) -> Double { j == 0 ? 0 : min(MotionConstants.handlingWindowSeconds, max(0, f.time[j] - f.time[j - 1])) }
        for i in 0..<n {
            sum += Double(f.wUp[i]) * d(i)
            sx += Double(f.mx[i])
            sy += Double(f.my[i])
            count += 1
            while lo < i && f.time[i] - f.time[lo] > MotionConstants.handlingWindowSeconds {
                sum -= Double(f.wUp[lo]) * d(lo)
                sx -= Double(f.mx[lo])
                sy -= Double(f.my[lo])
                count -= 1
                lo += 1
            }
            guard abs(sum) > MotionConstants.standstillYawRadians,
                  (sx * sx + sy * sy).squareRoot() / Double(count) < MotionConstants.standstillMaxHorizontal,
                  track.speed(at: f.time[i]) != nil else { continue }
            let moving = stride(from: -1.0, through: 3.5, by: 0.5).contains { (track.speed(at: f.time[i] + $0) ?? 0) >= MotionConstants.standstillSpeed }
            if !moving { f.rawHandling[i] = true }
        }
    }

    /// Handling windows: `seconds` (1 s) around every hand-at-work sample.
    static func pad(_ raw: [Bool], time: [Double], seconds: Double = MotionConstants.handlingPadSeconds) -> [Bool] {
        let n = raw.count
        var out = [Bool](repeating: false, count: n)
        var last = -Double.infinity
        for i in 0..<n {
            if raw[i] { last = time[i] }
            if time[i] - last <= seconds { out[i] = true }
        }
        var next = Double.infinity
        for i in stride(from: n - 1, through: 0, by: -1) {
            if raw[i] { next = time[i] }
            if next - time[i] <= seconds { out[i] = true }
        }
        return out
    }

    struct Swivel {
        /// The new segment starts here.
        var start: Int
        /// The samples that turn (gyro and GPS yaw rate apart by more than 0.2 rad/s, or by more
        /// than 0.05 rad/s for a slow swivel), counted as handling.
        var marked: [Int]
    }

    /// A swivel of the mount about the vertical: on straight driving at 3 m/s or more, the heading
    /// from the gyro minus the GPS heading follows a line within a mount (an offset plus a slow
    /// gyro drift); a step above 10° away from that line that holds over the next straight fixes
    /// is a new mount, however slowly it was turned.
    private static func swivels(_ f: Frame, _ fixes: [Fix]) -> [Swivel] {
        let n = f.time.count
        guard n > 1, fixes.count > 4 else { return [] }
        var unwrapped = [Double?](repeating: nil, count: fixes.count)
        for k in fixes.indices {
            guard let c = fixes[k].course, (fixes[k].speed ?? 0) >= MotionConstants.swivelMinSpeed else { continue }
            if k > 0, let p = unwrapped[k - 1], fixes[k].time - fixes[k - 1].time <= MotionConstants.targetMaxGapSeconds {
                unwrapped[k] = p + wrap180(c - (fixes[k - 1].course ?? c))
            } else {
                unwrapped[k] = c
            }
        }
        func straight(_ k: Int) -> Bool {
            guard let c = unwrapped[k], k >= 2, k + 2 < fixes.count else { return false }
            for j in (k - 2)...(k + 2) {
                guard let cj = unwrapped[j], abs(cj - c) <= MotionConstants.straightDegrees else { return false }
            }
            return true
        }
        struct Point { var time: Double; var residual: Double; var segment: Int32; var index: Int; var gapsBefore: Int }
        var points: [Point] = []
        var i = 0, heading = 0.0, gaps = 0
        for k in fixes.indices where straight(k) {
            let t = fixes[k].time
            while i + 1 < n && f.time[i + 1] <= t {
                i += 1
                let d = f.time[i] - f.time[i - 1]
                if d > MotionConstants.sensorGapSeconds { gaps += 1 } else { heading += Double(f.wUp[i]) * d }
            }
            guard abs(f.time[i] - t) < 0.2, !f.handling[i], let c = unwrapped[k] else { continue }
            points.append(Point(time: t, residual: heading + c * .pi / 180, segment: f.segment[i], index: i, gapsBefore: gaps))
        }
        // The gyro's own heading walk: white rate noise of σ (rad/s) at the sample interval dt walks
        // σ·sqrt(dt) per sqrt(s). A step must stand out three times above the walk since the last
        // accepted point (at least 10 s of it), never below 10°; real phone gyros keep it at 10°.
        let smoothed = smooth(f.wUp, time: f.time)
        let highs = stride(from: 0, to: n, by: 10).map { abs(Double(f.wUp[$0]) - Double(smoothed[$0])) }.sorted()
        let sigma = highs.isEmpty ? 0 : highs[highs.count / 2] * 1.4826
        let dt = n > 1 ? max(1e-3, (f.time[n - 1] - f.time[0]) / Double(n - 1)) : 0.01
        let walk = sigma * dt.squareRoot()
        func limit(since: Double) -> Double {
            max(MotionConstants.swivelDegrees * .pi / 180, 3 * walk * max(10, since).squareRoot())
        }
        var out: [Swivel] = []
        // The current mount's points (time, residual brought within ±π of the line) for the line fit.
        var line: [(t: Double, r: Double)] = []
        var lastAccepted: Point?
        func predict(_ t: Double) -> Double? {
            let recent = line.filter { t - $0.t <= 90 }
            guard let last = recent.last ?? line.last else { return nil }
            guard recent.count >= 3 else { return last.r }
            let mt = recent.map(\.t).reduce(0, +) / Double(recent.count), mr = recent.map(\.r).reduce(0, +) / Double(recent.count)
            var stt = 0.0, str = 0.0
            for p in recent {
                stt += (p.t - mt) * (p.t - mt)
                str += (p.t - mt) * (p.r - mr)
            }
            let slope = stt > 0 ? str / stt : 0
            return mr + slope * (t - mt)
        }
        func near(_ r: Double, _ to: Double) -> Double { to + wrapPi(r - to) }
        var k = 0
        while k < points.count {
            let p = points[k]
            guard let last = lastAccepted, last.segment == p.segment, last.gapsBefore == p.gapsBefore, let expected = predict(p.time) else {
                line = [(p.time, p.residual)]
                lastAccepted = p
                k += 1
                continue
            }
            let r = near(p.residual, expected)
            let limit = limit(since: p.time - last.time)
            if abs(r - expected) <= limit {
                line.append((p.time, r))
                lastAccepted = p
                k += 1
                continue
            }
            let next = Array(points.dropFirst(k + 1).prefix(2))
            let holds = next.count == 2 && next.allSatisfy { q in
                guard q.segment == p.segment, q.gapsBefore == p.gapsBefore, let e = predict(q.time) else { return false }
                let rq = near(q.residual, e)
                return abs(rq - e) > limit && abs((rq - e) - (r - expected)) < limit / 2
            }
            if holds, let swivel = locateSwivel(f, fixes, from: last.index, to: p.index) {
                // A slow build-up without fast turning is gyro drift: re-anchor the line, no split.
                if swivel.start >= 0 { out.append(swivel) }
                line = [(p.time, p.residual)]
                lastAccepted = p
            }
            k += 1
        }
        return out
    }

    /// Where between two samples the mount turned: the span over which the turn that the GPS
    /// course does not explain builds up (from 10 % to 90 % of it), and in it the samples whose
    /// rates differ.
    private static func locateSwivel(_ f: Frame, _ fixes: [Fix], from a: Int, to b: Int) -> Swivel? {
        guard b > a + 1 else { return nil }
        var fix = 0
        func gpsYaw(_ t: Double) -> Double {
            while fix + 1 < fixes.count && fixes[fix + 1].time <= t { fix += 1 }
            guard fix + 1 < fixes.count, let c0 = fixes[fix].course, let c1 = fixes[fix + 1].course else { return 0 }
            let d = fixes[fix + 1].time - fixes[fix].time
            return d > 0 && d <= MotionConstants.targetMaxGapSeconds ? -wrap180(c1 - c0) * .pi / 180 / d : 0
        }
        var raw = [Float](repeating: 0, count: b - a + 1)
        var cumulative = [Double](repeating: 0, count: b - a + 1)
        for i in (a + 1)...b {
            let d = min(MotionConstants.sensorGapSeconds, f.time[i] - f.time[i - 1])
            raw[i - a] = Float(Double(f.wUp[i]) - gpsYaw(f.time[i]))
            cumulative[i - a] = cumulative[i - a - 1] + Double(raw[i - a]) * d
        }
        // Marked on the smoothed rate (0.25 s), so gyro vibration does not mark half the span.
        let rate = smooth(raw, time: Array(f.time[a...b])).map(Double.init)
        let step = cumulative[cumulative.count - 1]
        guard abs(step) > 0 else { return nil }
        let lo = cumulative.firstIndex { abs($0) >= 0.1 * abs(step) } ?? 0
        let hi = cumulative.lastIndex { abs($0) <= 0.9 * abs(step) } ?? (cumulative.count - 1)
        if f.time[a + max(lo, hi)] - f.time[a + lo] > MotionConstants.swivelDriftSeconds {
            // A long build-up is gyro drift unless a burst of fast unexplained turning carries most
            // of it (start -1: no swivel).
            var fast = 0.0
            for j in max(1, lo)...max(lo, hi) where abs(rate[j]) > MotionConstants.swivelRate { fast += cumulative[j] - cumulative[j - 1] }
            if abs(fast) < 0.5 * abs(step) { return Swivel(start: -1, marked: []) }
            let marked = (max(1, lo)...max(lo, hi)).filter { abs(rate[$0]) > MotionConstants.swivelRate }.map { a + $0 }
            return Swivel(start: marked.first ?? (a + lo), marked: marked)
        }
        let span = lo...max(lo, hi)
        let peak = span.map { abs(rate[$0]) }.max() ?? 0
        let threshold = min(MotionConstants.swivelRate, max(0.05, 0.5 * peak))
        let marked = span.filter { abs(rate[$0]) > threshold }.map { a + $0 }
        return Swivel(start: a + (marked.first.map { $0 - a } ?? lo), marked: marked)
    }

    static func wrap180(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    static func wrapPi(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    /// 0.1 s bins of the horizontal acceleration and the yaw rate, for interval averages (a few MB
    /// for 8 hours instead of prefix sums over every sample).
    private struct Bins {
        static let width = 0.1
        let t0: Double
        var mx: [Double]
        var my: [Double]
        var w: [Double]
        var count: [Int32]
        /// -1 empty, -2 more than one segment.
        var segment: [Int32]
        var handling: [Bool]

        init(_ f: Frame) {
            t0 = f.time.first ?? 0
            let m = Int(((f.time.last ?? t0) - t0) / Bins.width) + 1
            mx = [Double](repeating: 0, count: m)
            my = mx
            w = mx
            count = [Int32](repeating: 0, count: m)
            segment = [Int32](repeating: -1, count: m)
            handling = [Bool](repeating: false, count: m)
            for i in f.time.indices {
                let k = min(m - 1, Int((f.time[i] - t0) / Bins.width))
                if f.handling[i] { handling[k] = true }
                mx[k] += Double(f.mx[i])
                my[k] += Double(f.my[i])
                w[k] += Double(f.wUp[i])
                count[k] += 1
                segment[k] = segment[k] == -1 ? f.segment[i] : (segment[k] == f.segment[i] ? segment[k] : -2)
            }
        }

        /// Averages over the bins in [a, b), when all of them hold samples of one segment and no
        /// hand was at work.
        func average(_ a: Double, _ b: Double) -> (mx: Double, my: Double, w: Double, segment: Int32)? {
            let ka = Int(((a - t0) / Bins.width).rounded()), kb = Int(((b - t0) / Bins.width).rounded())
            guard ka >= 0, kb <= count.count, kb > ka else { return nil }
            let seg = segment[ka]
            guard seg >= 0 else { return nil }
            var sx = 0.0, sy = 0.0, sw = 0.0, c = 0
            for k in ka..<kb {
                guard count[k] > 0, !handling[k], segment[k] == seg else { return nil }
                sx += mx[k]
                sy += my[k]
                sw += w[k]
                c += Int(count[k])
            }
            guard c >= 10 else { return nil }
            let d = Double(c)
            return (sx / d, sy / d, sw / d, seg)
        }
    }

    /// Step 4: consecutive valid fixes at most 2 s apart, both at 3 m/s or more.
    private struct Target {
        var t0: Double
        var t1: Double
        var long: Double
        var speed: Double
    }

    private static func targets(_ fixes: [Fix]) -> [Target] {
        var out: [Target] = []
        var prev: Fix?
        for f in fixes {
            guard let v = f.speed, v >= 0 else { prev = nil; continue }
            if let p = prev, let pv = p.speed {
                let dt = f.time - p.time
                if dt > 0, dt <= MotionConstants.targetMaxGapSeconds, pv >= MotionConstants.targetMinSpeed, v >= MotionConstants.targetMinSpeed {
                    out.append(Target(t0: p.time, t1: f.time, long: (v - pv) / dt, speed: (v + pv) / 2))
                }
            }
            prev = f
        }
        return out
    }

    /// Step 5: the closed-form rotation (and reflection) per segment at one lag, with its gain.
    private static func fits(_ targets: [Target], bins: Bins, lag: Double) -> [Int32: Fit] {
        struct Acc {
            var a = 0.0, b = 0.0, ar = 0.0, br = 0.0, tt = 0.0, mm = 0.0
            var pairs = 0, excited = 0
        }
        var acc: [Int32: Acc] = [:]
        for t in targets {
            guard let m = bins.average(t.t0 + lag, t.t1 + lag) else { continue }
            let tx = t.long, ty = t.speed * m.w
            guard (tx * tx + ty * ty).squareRoot() <= MotionConstants.maxTarget else { continue }
            var s = acc[m.segment] ?? Acc()
            s.a += m.mx * tx + m.my * ty
            s.b += m.mx * ty - m.my * tx
            // Reflection: m' = (mx, -my).
            s.ar += m.mx * tx - m.my * ty
            s.br += m.mx * ty + m.my * tx
            s.tt += tx * tx + ty * ty
            s.mm += m.mx * m.mx + m.my * m.my
            s.pairs += 1
            if (tx * tx + ty * ty).squareRoot() >= MotionConstants.excitationTarget { s.excited += 1 }
            acc[m.segment] = s
        }
        return acc.mapValues { s in
            let rot = s.tt + s.mm - 2 * (s.a * s.a + s.b * s.b).squareRoot()
            let ref = s.tt + s.mm - 2 * (s.ar * s.ar + s.br * s.br).squareRoot()
            let mm = max(s.mm, 1e-12)
            if ref < 0.8 * rot {
                return Fit(theta: atan2(s.br, s.ar), reflected: true, sse: ref, pairs: s.pairs, excited: s.excited,
                           gain: mm / max((s.ar * s.ar + s.br * s.br).squareRoot(), 1e-12))
            }
            return Fit(theta: atan2(s.b, s.a), reflected: false, sse: rot, pairs: s.pairs, excited: s.excited,
                       gain: mm / max((s.a * s.a + s.b * s.b).squareRoot(), 1e-12))
        }
    }

    /// Correlation of the gyro's yaw rate (over each fix interval, at the lag) with the GPS course
    /// rate (course is clockwise, so a left turn is a falling course), at 3 m/s or more. Nil
    /// without enough turning to say anything.
    private static func yawCorrelation(_ fixes: [Fix], bins: Bins, lag: Double) -> Double? {
        var gyro: [Double] = [], gps: [Double] = []
        for k in fixes.indices.dropFirst() {
            let p = fixes[k - 1], q = fixes[k]
            guard let c0 = p.course, let c1 = q.course, (p.speed ?? 0) >= MotionConstants.swivelMinSpeed,
                  (q.speed ?? 0) >= MotionConstants.swivelMinSpeed else { continue }
            let d = q.time - p.time
            guard d > 0, d <= MotionConstants.targetMaxGapSeconds, let m = bins.average(p.time + lag, q.time + lag) else { continue }
            gyro.append(m.w)
            gps.append(-wrap180(c1 - c0) * .pi / 180 / d)
        }
        guard gyro.count >= 10, (gps.map(abs).max() ?? 0) >= MotionConstants.yawCheckMinRate else { return nil }
        return pearson(gyro, gps)
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count >= 3, x.count == y.count else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// About `MotionConstants.eventLowPassHz`: a centred moving average over 1 / (2 f) seconds
    /// (0.25 s at 2 Hz), no delay; a NaN bounds the window. A first-order filter at 2 Hz left the
    /// 0.05 g sensor noise at about ±0.5 m/s² in the peaks.
    static func smooth(_ x: [Float], time: [Double]) -> [Float] {
        let half = 1 / (4 * MotionConstants.eventLowPassHz)
        let n = x.count
        var out = x
        var a = 0
        while a < n {
            if x[a].isNaN {
                a += 1
                continue
            }
            var b = a
            while b + 1 < n && !x[b + 1].isNaN { b += 1 }
            var lo = a, hi = a - 1, sum = 0.0
            for i in a...b {
                while hi + 1 <= b && time[hi + 1] - time[i] <= half {
                    hi += 1
                    sum += Double(x[hi])
                }
                while lo < i && time[i] - time[lo] > half {
                    sum -= Double(x[lo])
                    lo += 1
                }
                out[i] = Float(sum / Double(hi - lo + 1))
            }
            a = b + 1
        }
        return out
    }

    /// The signal minus its centred 1 s moving average.
    static func highPass(_ x: [Float], time: [Double]) -> [Float] {
        let n = x.count
        var out = x
        var lo = 0, hi = -1, sum = 0.0
        for i in 0..<n {
            while hi + 1 < n && time[hi + 1] - time[i] <= 0.5 {
                hi += 1
                sum += Double(x[hi])
            }
            while lo < i && time[i] - time[lo] > 0.5 {
                sum -= Double(x[lo])
                lo += 1
            }
            out[i] = Float(Double(x[i]) - sum / Double(hi - lo + 1))
        }
        return out
    }

    /// A 100 m stretch before the vibration floor comes off.
    struct RawStretch {
        var start: Int
        var end: Int
        var ms: Double
        var speed: Double
        var meters: Double
    }

    struct Run {
        var a: Int
        var b: Int
        /// Joined across a hand-at-work gap.
        var acrossHandling = false
    }

    /// Runs where `value` (NaN: unusable) reaches `enter`, each lasting until it falls below
    /// `exit` (hysteresis). A sensor gap above 0.5 s or an unusable sample ends a run; runs less
    /// than `merge` seconds apart are one, never across a sensor gap or unaligned data, but across
    /// a hand-at-work gap of up to `handlingMerge` seconds (flagged). A run counts when its time
    /// at or beyond `enter` adds up to `minSeconds`.
    static func hysteresisRuns(_ time: [Double], enter: Double, exit: Double, minSeconds: Double, merge: Double,
                               handlingMerge: Double = 0, isHandling: (Int) -> Bool = { _ in false },
                               value: (Int) -> Double) -> [Run] {
        struct Open {
            var a: Int
            var b: Int
            var beyond = 0.0
            var hardEnd = false
            var handlingEnd = false
            var acrossHandling = false
        }
        var runs: [Open] = []
        var current: Open?
        for i in time.indices {
            let v = value(i)
            let gap = i > 0 && time[i] - time[i - 1] > MotionConstants.sensorGapSeconds
            let hand = v.isNaN && isHandling(i)
            if var c = current, gap || v.isNaN || v < exit {
                c.hardEnd = gap || (v.isNaN && !hand)
                c.handlingEnd = !gap && hand
                runs.append(c)
                current = nil
            } else if current == nil, gap || v.isNaN, !runs.isEmpty {
                if gap || !hand { runs[runs.count - 1].hardEnd = true }
            }
            guard v.isFinite else { continue }
            if current == nil {
                guard v >= enter else { continue }
                current = Open(a: i, b: i)
            } else {
                current!.b = i
                if v >= enter { current!.beyond += min(time[i] - time[i - 1], MotionConstants.sensorGapSeconds) }
            }
        }
        if let c = current { runs.append(c) }
        var merged: [Open] = []
        for r in runs {
            if var last = merged.last, !last.hardEnd,
               time[r.a] - time[last.b] <= (last.handlingEnd ? max(merge, handlingMerge) : merge) {
                last.acrossHandling = last.acrossHandling || last.handlingEnd
                last.b = r.b
                last.beyond += r.beyond
                last.hardEnd = r.hardEnd
                last.handlingEnd = r.handlingEnd
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged.filter { $0.beyond >= minSeconds - 1e-9 }.map { Run(a: $0.a, b: $0.b, acrossHandling: $0.acrossHandling) }
    }

    /// The RMS over a centred window, for indices asked in increasing order.
    struct SlidingRMS {
        let time: [Double]
        let values: [Float]
        let half: Double
        private var lo = 0, hi = -1, sum = 0.0

        init(time: [Double], values: [Float], half: Double) {
            self.time = time
            self.values = values
            self.half = half
        }

        mutating func at(_ i: Int) -> Double {
            while hi + 1 < values.count && time[hi + 1] - time[i] <= half {
                hi += 1
                sum += Double(values[hi]) * Double(values[hi])
            }
            while lo < i && time[i] - time[lo] > half {
                sum -= Double(values[lo]) * Double(values[lo])
                lo += 1
            }
            return (max(0, sum) / Double(max(1, hi - lo + 1))).squareRoot()
        }
    }

    /// A second-order Butterworth low-pass (bilinear transform).
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        /// Nil when the cutoff is too close to the Nyquist frequency to mean anything.
        static func lowPass(cutoff: Double, rate: Double) -> Biquad? {
            guard rate > 0, cutoff < 0.45 * rate else { return nil }
            let w0 = 2 * Double.pi * cutoff / rate
            let alpha = sin(w0) / (2 * 0.5.squareRoot())
            let c = cos(w0), a0 = 1 + alpha
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        mutating func step(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }

        mutating func reset() {
            x1 = 0
            x2 = 0
            y1 = 0
            y2 = 0
        }
    }

    /// Speed and position from the fixes, interpolated in time.
    struct Track1D {
        let times: [Double]
        let speeds: [Double?]
        let points: [LatLon]

        init(_ fixes: [Fix]) {
            times = fixes.map(\.time)
            speeds = fixes.map { $0.speed.flatMap { $0 >= 0 ? $0 : nil } }
            points = fixes.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
        }

        private func bracket(_ t: Double) -> (Int, Int, Double)? {
            guard let first = times.first, let last = times.last, t >= first - 1, t <= last + 1 else { return nil }
            var lo = 0, hi = times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid } else { hi = mid }
            }
            guard times[hi] - times[lo] <= 5 || times.count == 1 else { return nil }
            let span = times[hi] - times[lo]
            return (lo, hi, span > 0 ? min(1, max(0, (t - times[lo]) / span)) : 0)
        }

        func speed(at t: Double) -> Double? {
            guard let (a, b, u) = bracket(t), let va = speeds[a], let vb = speeds[b] else { return nil }
            return va + (vb - va) * u
        }

        func position(at t: Double) -> LatLon? {
            guard let (a, b, u) = bracket(t) else { return nil }
            return LatLon(lat: points[a].lat + (points[b].lat - points[a].lat) * u, lon: points[a].lon + (points[b].lon - points[a].lon) * u)
        }
    }
}

nonisolated private extension Double {
    /// For a maximum over values that may be NaN: NaN never wins.
    var nanLowest: Double { isNaN ? -.infinity : self }
}
