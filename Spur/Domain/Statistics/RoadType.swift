import Foundation

/// Estimated road class (SPEC section 5, "Streckenart (geschätzt)").
nonisolated enum RoadClass: String, Codable, Sendable, CaseIterable, Identifiable {
    case stadt, land, autobahn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stadt: "Stadt"
        case .land: "Land"
        case .autobahn: "Autobahn"
        }
    }
}

/// Distance and time per estimated road class.
nonisolated struct RoadTypeStats: Codable, Sendable, Equatable {
    struct Share: Codable, Sendable, Equatable {
        var distance: Double = 0
        var time: Double = 0
    }

    var stadt = Share()
    var land = Share()
    var autobahn = Share()

    subscript(_ c: RoadClass) -> Share {
        get {
            switch c {
            case .stadt: stadt
            case .land: land
            case .autobahn: autobahn
            }
        }
        set {
            switch c {
            case .stadt: stadt = newValue
            case .land: land = newValue
            case .autobahn: autobahn = newValue
            }
        }
    }

    var classifiedDistance: Double { stadt.distance + land.distance + autobahn.distance }

    /// Share of classified distance, 0 to 1.
    func distanceShare(_ c: RoadClass) -> Double {
        let total = classifiedDistance
        return total > 0 ? self[c].distance / total : 0
    }
}

/// Offline road type estimate from the speed and stop profile.
///
/// For every usable fix, a rolling window holds the usable fixes of the last 60 s in the same
/// segment. Candidate class: `Stadt` when the window has more than 2 stops per km (only judged
/// once the window covers at least 250 m), else by the median speed of its moving fixes:
/// at least 85 km/h `Autobahn`, 50 to 85 km/h `Land`, below 50 km/h `Stadt`. A window without
/// moving fixes gives no candidate. Hysteresis: a candidate must persist for 30 s within one
/// segment before it replaces the current class; a gap, more than 5 s without a usable fix, or a
/// window without a candidate restarts that count (a single unusable fix does not). Unusable
/// fixes keep the current class.
nonisolated enum RoadTypeClassifier {
    /// Minimum window distance (meters) before the stops-per-km rule is applied.
    static let minWindowDistanceForStopRate: Double = 250

    static func classify(_ track: Track, stops: [StopStats.Stop]) -> [RoadClass?] {
        let f = track.fixes
        var out = [RoadClass?](repeating: nil, count: f.count)
        let stopStarts = stops.map { f[$0.startIndex].time }.sorted()
        var current: RoadClass?
        var pending: RoadClass?
        var pendingSince = 0.0

        for segment in track.segments {
            var lo = segment.lowerBound
            pending = nil
            var lastUsableTime: Double?
            for i in segment {
                guard track.isUsable(i) else {
                    out[i] = current
                    continue
                }
                let t = f[i].time
                while lo < i && f[lo].time <= t - StatsConstants.roadWindow { lo += 1 }

                var speeds: [Double] = []
                for k in lo...i where track.isUsable(k) {
                    if let v = f[k].speed ?? track.intervalSpeed[k], v >= StatsConstants.movingSpeed {
                        speeds.append(v)
                    }
                }
                let windowDistance = track.cumulativeDistance[i] - track.cumulativeDistance[lo]
                let windowStops = countStops(stopStarts, from: t - StatsConstants.roadWindow, to: t)
                let candidate = candidateClass(
                    medianSpeed: Quantile.median(speeds), stopsInWindow: windowStops, windowDistance: windowDistance
                )

                if candidate == nil { pending = nil }
                // A long unusable stretch restarts the hold, a single bad fix does not.
                if let lu = lastUsableTime, t - lu > StatsConstants.gapThreshold { pending = nil }
                lastUsableTime = t
                if let c = candidate {
                    if current == nil {
                        current = c
                    } else if c == current {
                        pending = nil
                    } else {
                        if pending != c {
                            pending = c
                            pendingSince = t
                        }
                        if t - pendingSince >= StatsConstants.roadHysteresis {
                            current = c
                            pending = nil
                        }
                    }
                }
                out[i] = current
            }
        }
        return out
    }

    /// The class a single window suggests, before hysteresis.
    static func candidateClass(medianSpeed: Double?, stopsInWindow: Int, windowDistance: Double) -> RoadClass? {
        if windowDistance >= minWindowDistanceForStopRate,
           Double(stopsInWindow) / (windowDistance / 1000) > StatsConstants.stadtStopsPerKm {
            return .stadt
        }
        guard let v = medianSpeed else { return nil }
        let kmh = v * 3.6
        if kmh >= StatsConstants.autobahnMinKmh { return .autobahn }
        if kmh >= StatsConstants.landMinKmh { return .land }
        return .stadt
    }

    /// Stops starting in (from, to].
    private static func countStops(_ sortedStarts: [Double], from: Double, to: Double) -> Int {
        var n = 0
        for s in sortedStarts where s > from && s <= to { n += 1 }
        return n
    }

    static func stats(_ track: Track, classes: [RoadClass?]) -> RoadTypeStats {
        var stats = RoadTypeStats()
        for i in 1..<max(1, track.fixes.count) where !track.crossesGap[i] {
            guard let c = classes[i] else { continue }
            stats[c].distance += track.distanceIncrement[i]
            stats[c].time += track.dt[i]
        }
        return stats
    }
}
