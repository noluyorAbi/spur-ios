import Foundation

/// Distance (SPEC section 5).
///
/// Haversine sum between consecutive usable fixes within a segment (never across a gap).
/// When a fix reports a valid speed below 1 m/s, the position does not advance: the fix adds
/// nothing and the next distance is measured from the last position that did advance. So
/// stationary jitter adds nothing, while slow creeping is still counted once it is moving again.
nonisolated enum DistanceStats {
    /// Distance added at each fix index, in meters.
    static func increments(fixes: [Fix], segments: [Range<Int>], config: StatsConfig) -> [Double] {
        var out = [Double](repeating: 0, count: fixes.count)
        for segment in segments {
            var anchor: Int?
            for j in segment where Track.isUsable(fixes[j], config) {
                guard let a = anchor else {
                    anchor = j
                    continue
                }
                if let v = fixes[j].speed, v < StatsConstants.movingSpeed {
                    continue
                }
                out[j] = Geo.distance(fixes[a], fixes[j])
                anchor = j
            }
        }
        return out
    }

    static func total(_ fixes: [Fix], config: StatsConfig = .default) -> Double {
        Track(fixes: fixes, config: config).totalDistance
    }
}
