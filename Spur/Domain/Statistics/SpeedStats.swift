import Foundation

/// Speed (SPEC section 5). All speeds in m/s.
nonisolated struct SpeedStats: Codable, Sendable, Equatable {
    struct Bin: Codable, Sendable, Equatable, Hashable {
        /// Lower bound of the bin in km/h; the bin is [lower, lower + 10).
        var lowerKmh: Double
        /// Moving seconds spent in this bin.
        var seconds: Double
    }

    /// Distance divided by total duration.
    var average: Double?
    /// Distance divided by moving time.
    var movingAverage: Double?
    /// Highest reported speed among fixes whose speed accuracy is at most 2 m/s when known.
    var max: Double?
    /// 85th percentile (nearest rank) of the reported speeds of moving fixes, same filter as max.
    var p85: Double?
    /// Moving time per 10 km/h speed bin, by effective interval speed.
    var histogram: [Bin]

    /// Moving seconds per speed bin in a display unit: the speed in m/s times `unitsPerMps`
    /// (3.6 for km/h) falls into bin k when it lies in [k, k+1) times `binWidth`.
    /// Returns (bin index, seconds) for every bin from 0 to the highest one.
    static func histogram(_ track: Track, unitsPerMps: Double, binWidth: Double) -> [(index: Int, seconds: Double)] {
        var bins: [Int: Double] = [:]
        for i in 1..<Swift.max(1, track.fixes.count) {
            guard let v = track.intervalSpeed[i], v >= StatsConstants.movingSpeed else { continue }
            bins[Int((v * unitsPerMps / binWidth).rounded(.down)), default: 0] += track.dt[i]
        }
        guard let top = bins.keys.max() else { return [] }
        return (0...top).map { ($0, bins[$0] ?? 0) }
    }

    static func compute(_ track: Track, time: TimeStats) -> SpeedStats {
        let distance = track.totalDistance
        let average = time.totalDuration > 0 ? distance / time.totalDuration : nil
        let movingAverage = time.movingTime > 0 ? distance / time.movingTime : nil

        let eligible = track.fixes.compactMap { fix -> Double? in
            guard let v = fix.speed else { return nil }
            if let acc = fix.speedAccuracy, acc > StatsConstants.maxSpeedAccuracy { return nil }
            return v
        }
        let maxSpeed = eligible.max()
        let p85 = Quantile.nearestRank(eligible.filter { $0 >= StatsConstants.movingSpeed }, 0.85)

        let histogram = Self.histogram(track, unitsPerMps: 3.6, binWidth: StatsConstants.histogramBinKmh).map {
            Bin(lowerKmh: Double($0.index) * StatsConstants.histogramBinKmh, seconds: $0.seconds)
        }
        return SpeedStats(average: average, movingAverage: movingAverage, max: maxSpeed, p85: p85, histogram: histogram)
    }
}
