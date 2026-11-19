import Foundation

/// GPS quality (SPEC section 5).
nonisolated struct GPSQualityStats: Codable, Sendable, Equatable {
    var fixCount: Int
    /// Fixes per second while recording: intervals outside gaps divided by their summed length.
    var meanRateHz: Double?
    /// Of fixes with a known horizontal accuracy.
    var medianAccuracy: Double?
    var p95Accuracy: Double?
    /// Percent (0 to 100) of fixes with known accuracy that are at most 5 m.
    var percentPrecise: Double?
    /// Percent (0 to 100) of fixes with known accuracy that are at most 10 m (added in 1.1, nil in
    /// trips saved by 1.0 until they are re-analyzed).
    var percentWithin10: Double?
    /// Percent (0 to 100) of fixes with known accuracy that are above 30 m.
    var percentAbove30: Double?
    /// Fixes without a valid horizontal accuracy.
    var unknownAccuracyCount: Int
    var gapCount: Int
    var gapTotal: Double
    var simulatedCount: Int
    var accessoryCount: Int

    /// Share (0 to 1) of all fixes that came from an external receiver (an MFi GNSS accessory feeds
    /// Core Location directly and marks its fixes `isProducedByAccessory`).
    var accessoryShare: Double? { fixCount > 0 ? Double(accessoryCount) / Double(fixCount) : nil }

    static func compute(_ track: Track, gaps: [Gap]) -> GPSQualityStats {
        let f = track.fixes
        let accuracies = f.compactMap(\.horizontalAccuracy)
        var intervals = 0
        var recorded = 0.0
        for i in 1..<max(1, f.count) where !track.crossesGap[i] {
            intervals += 1
            recorded += track.dt[i]
        }
        let known = Double(accuracies.count)
        return GPSQualityStats(
            fixCount: f.count,
            meanRateHz: recorded > 0 ? Double(intervals) / recorded : nil,
            medianAccuracy: Quantile.median(accuracies),
            p95Accuracy: Quantile.nearestRank(accuracies, 0.95),
            percentPrecise: known > 0
                ? 100 * Double(accuracies.filter { $0 <= StatsConstants.preciseAccuracy }.count) / known : nil,
            percentWithin10: known > 0
                ? 100 * Double(accuracies.filter { $0 <= StatsConstants.goodAccuracy }.count) / known : nil,
            percentAbove30: known > 0 ? 100 * Double(accuracies.filter { $0 > 30 }.count) / known : nil,
            unknownAccuracyCount: f.count - accuracies.count,
            gapCount: gaps.count,
            gapTotal: gaps.reduce(0) { $0 + $1.duration },
            simulatedCount: f.filter { $0.isSimulatedBySoftware == true }.count,
            accessoryCount: f.filter { $0.isProducedByAccessory == true }.count
        )
    }
}
