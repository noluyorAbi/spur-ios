import Foundation

/// Incremental distance and moving time for the live HUD: constant work per fix.
/// Follows exactly the batch definitions in `DistanceStats` and `TimeStats`.
nonisolated struct LiveAccumulator: Sendable {
    var config: StatsConfig
    private(set) var distance: Double = 0
    private(set) var movingTime: Double = 0
    private(set) var fixCount = 0
    private(set) var lastFix: Fix?
    private var anchor: Fix?

    init(config: StatsConfig = .default) {
        self.config = config
    }

    /// Adds the next fix. Returns true when it follows a gap (more than 5 s after the last one).
    @discardableResult
    mutating func add(_ f: Fix) -> Bool {
        var gap = false
        let usable = Track.isUsable(f, config)
        if let last = lastFix {
            let dt = f.time - last.time
            if dt > StatsConstants.gapThreshold {
                gap = true
                anchor = nil
            } else {
                var v = f.speed
                if v == nil, dt > 0, usable, Track.isUsable(last, config) {
                    v = Geo.distance(last, f) / dt
                }
                if let v, v >= StatsConstants.movingSpeed { movingTime += max(0, dt) }
            }
        }
        if usable {
            if let a = anchor {
                if !(f.speed.map { $0 < StatsConstants.movingSpeed } ?? false) {
                    distance += Geo.distance(a, f)
                    anchor = f
                }
            } else {
                anchor = f
            }
        }
        lastFix = f
        fixCount += 1
        return gap
    }
}
