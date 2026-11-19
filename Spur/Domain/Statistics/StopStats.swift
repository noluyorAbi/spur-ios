import Foundation

/// Stops (SPEC section 5): effective speed below 1.0 m/s for at least 3 s.
nonisolated struct StopStats: Codable, Sendable, Equatable {
    struct Stop: Codable, Sendable, Equatable, Hashable {
        /// Fix index where the stop begins (the fix before the first slow interval).
        var startIndex: Int
        /// Fix index where the stop ends (the last slow interval's end fix).
        var endIndex: Int
        var startMs: Int64
        var duration: Double
        /// True when moving resumed right after the stop (a start-stop event).
        var followedByMoving: Bool
    }

    var count: Int
    var totalTime: Double
    var longest: Double
    /// Stops followed by moving.
    var startStopEvents: Int
    /// Start-stop events per km of distance, nil below 100 m driven.
    var startStopPerKm: Double?

    /// Every stop: maximal runs of consecutive slow intervals within one segment lasting at least 3 s.
    static func stops(_ track: Track) -> [Stop] {
        let f = track.fixes
        var out: [Stop] = []
        var runStart: Int?
        var runTime = 0.0
        func close(at end: Int, followedByMoving: Bool) {
            if let s = runStart, runTime >= StatsConstants.stopMinDuration {
                out.append(Stop(startIndex: s, endIndex: end, startMs: f[s].timestampMs, duration: runTime,
                                followedByMoving: followedByMoving))
            }
            runStart = nil
            runTime = 0
        }
        for i in 1..<max(1, f.count) {
            if track.crossesGap[i] {
                close(at: i - 1, followedByMoving: false)
                continue
            }
            guard let v = track.intervalSpeed[i] else { continue }
            if v < StatsConstants.movingSpeed {
                if runStart == nil { runStart = i - 1 }
                runTime += track.dt[i]
            } else {
                close(at: i - 1, followedByMoving: true)
            }
        }
        if !f.isEmpty { close(at: f.count - 1, followedByMoving: false) }
        return out
    }

    static func compute(_ track: Track, stops: [Stop]) -> StopStats {
        let events = stops.filter(\.followedByMoving).count
        let km = track.totalDistance / 1000
        return StopStats(
            count: stops.count,
            totalTime: stops.reduce(0) { $0 + $1.duration },
            longest: stops.map(\.duration).max() ?? 0,
            startStopEvents: events,
            startStopPerKm: track.totalDistance >= 100 ? Double(events) / km : nil
        )
    }
}
