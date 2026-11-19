import Foundation

/// Time (SPEC section 5).
nonisolated struct TimeStats: Codable, Sendable, Equatable {
    /// First fix to last fix, in seconds, gaps included.
    var totalDuration: Double
    /// Sum of intervals whose effective speed is at least 1 m/s.
    var movingTime: Double
    /// Sum of intervals whose effective speed is below 1 m/s.
    var stoppedTime: Double
    /// Sum of gap durations.
    var gapTime: Double

    /// Effective speed of an interval: the fix's reported speed, else the distance between two
    /// usable fixes divided by the time. Intervals with unknown speed count as neither.
    /// Intervals inside a pause (SPEC 18.9) count in neither driving nor stop time.
    static func compute(_ track: Track, pauses: [TripPause] = []) -> TimeStats {
        let spans = pauses.compactMap { p in p.end.map { (p.start.timeIntervalSince1970, $0.timeIntervalSince1970) } }
        let f = track.fixes
        guard let first = f.first, let last = f.last else {
            return TimeStats(totalDuration: 0, movingTime: 0, stoppedTime: 0, gapTime: 0)
        }
        var moving = 0.0, stopped = 0.0, gap = 0.0
        for i in 1..<max(1, f.count) {
            if track.crossesGap[i] {
                gap += f[i].time - f[i - 1].time
                continue
            }
            guard let v = track.intervalSpeed[i] else { continue }
            let mid = (f[i].time + f[i - 1].time) / 2
            if spans.contains(where: { mid >= $0.0 && mid < $0.1 }) { continue }
            if v >= StatsConstants.movingSpeed { moving += track.dt[i] } else { stopped += track.dt[i] }
        }
        return TimeStats(totalDuration: last.time - first.time, movingTime: moving, stoppedTime: stopped, gapTime: gap)
    }
}
