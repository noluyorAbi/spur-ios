import Foundation

/// Shared, precomputed view of a fix array that every statistic reads.
///
/// Interval `i` (for `i >= 1`) spans `fixes[i - 1]` to `fixes[i]`. Intervals longer than the
/// gap threshold cross a gap and are excluded from every time and distance sum.
nonisolated struct Track: Sendable {
    let fixes: [Fix]
    let config: StatsConfig
    /// Half-open index ranges of gap-separated segments, in order.
    let segments: [Range<Int>]
    /// Segment number per fix.
    let segmentOf: [Int]
    /// Interval length in seconds per fix index (0 for index 0 and for gap intervals).
    let dt: [Double]
    /// True when the interval ending at this fix crosses a gap.
    let crossesGap: [Bool]
    /// Effective speed of the interval ending at this fix (m/s), nil when unknown or a gap.
    let intervalSpeed: [Double?]
    /// Distance added at this fix (meters), see `DistanceStats`.
    let distanceIncrement: [Double]
    /// Running sum of `distanceIncrement`.
    let cumulativeDistance: [Double]

    init(fixes: [Fix], config: StatsConfig = .default) {
        self.fixes = fixes
        self.config = config
        let n = fixes.count
        var segments: [Range<Int>] = []
        var segmentOf = [Int](repeating: 0, count: n)
        var dt = [Double](repeating: 0, count: n)
        var crossesGap = [Bool](repeating: false, count: n)
        var start = 0
        for i in 0..<n {
            if i > 0 {
                let d = fixes[i].time - fixes[i - 1].time
                if d > StatsConstants.gapThreshold {
                    crossesGap[i] = true
                    segments.append(start..<i)
                    start = i
                } else {
                    dt[i] = max(0, d)
                }
            }
            segmentOf[i] = segments.count
        }
        if n > 0 { segments.append(start..<n) }
        self.segments = segments
        self.segmentOf = segmentOf
        self.dt = dt
        self.crossesGap = crossesGap

        var speed = [Double?](repeating: nil, count: n)
        for i in 1..<max(1, n) where !crossesGap[i] {
            if let v = fixes[i].speed {
                speed[i] = v
            } else if dt[i] > 0, Track.isUsable(fixes[i], config), Track.isUsable(fixes[i - 1], config) {
                speed[i] = Geo.distance(fixes[i - 1], fixes[i]) / dt[i]
            }
        }
        self.intervalSpeed = speed

        let increments = DistanceStats.increments(fixes: fixes, segments: segments, config: config)
        self.distanceIncrement = increments
        var cumulative = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            sum += increments[i]
            cumulative[i] = sum
        }
        self.cumulativeDistance = cumulative
    }

    /// Horizontal accuracy known and at most the configured limit.
    static func isUsable(_ fix: Fix, _ config: StatsConfig) -> Bool {
        guard let acc = fix.horizontalAccuracy else { return false }
        return acc <= config.usableAccuracy
    }

    func isUsable(_ i: Int) -> Bool { Track.isUsable(fixes[i], config) }

    var totalDistance: Double { cumulativeDistance.last ?? 0 }

    /// Gaps derived from the fixes; reasons come from the live-recorded gaps where they match.
    func gaps(recorded: [Gap]) -> [Gap] {
        var out: [Gap] = []
        for i in 1..<max(1, fixes.count) where crossesGap[i] {
            let s = fixes[i - 1].timestampMs
            let e = fixes[i].timestampMs
            // A recorded gap matches when it overlaps the derived one.
            let reason = recorded.first(where: { $0.startMs <= e && $0.endMs >= s })?.reason ?? .signal
            out.append(Gap(startMs: s, endMs: e, reason: reason))
        }
        return out
    }
}

/// Order statistics helpers.
nonisolated enum Quantile {
    /// Median, averaging the two middle values for an even count. nil for empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Nearest-rank percentile, `p` in (0, 1]. nil for empty input.
    static func nearestRank(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}
