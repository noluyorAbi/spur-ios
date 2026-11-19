import Foundation

/// Places and streets (SPEC section 5), derived from reverse geocoding samples.
nonisolated struct PlacesSummary: Codable, Sendable, Equatable {
    struct Street: Codable, Sendable, Equatable, Hashable {
        var name: String
        /// Approximate distance driven on it (meters).
        var distance: Double
    }

    var startPlace: String?
    var endPlace: String?
    /// Localities in driving order, consecutive repeats removed.
    var localities: [String]
    /// Streets in order of first appearance. The distance driven from one sample to the next is
    /// credited to the street of the earlier sample.
    var streets: [Street]

    static let empty = PlacesSummary(startPlace: nil, endPlace: nil, localities: [], streets: [])

    static func compute(samples: [PlaceSample], track: Track) -> PlacesSummary {
        let s = samples.sorted { $0.timestampMs < $1.timestampMs }
        guard !s.isEmpty else { return .empty }
        let start = s.first(where: { $0.kind == .start })?.locality ?? s.first?.locality
        let end = s.last(where: { $0.kind == .end })?.locality

        var localities: [String] = []
        for sample in s {
            guard let l = sample.locality, !l.isEmpty else { continue }
            if localities.last != l { localities.append(l) }
        }

        var order: [String] = []
        var distance: [String: Double] = [:]
        let endTime = track.fixes.last?.time ?? 0
        for (k, sample) in s.enumerated() {
            guard let name = sample.street, !name.isEmpty else { continue }
            let from = Double(sample.timestampMs) / 1000
            let to = k + 1 < s.count ? Double(s[k + 1].timestampMs) / 1000 : endTime
            // A sample with no driving after it (the end sample) credits nothing and adds no street.
            guard to > from else { continue }
            let d = max(0, distanceAt(track, time: to) - distanceAt(track, time: from))
            if distance[name] == nil { order.append(name) }
            distance[name, default: 0] += d
        }
        return PlacesSummary(
            startPlace: start, endPlace: end, localities: localities,
            streets: order.map { Street(name: $0, distance: distance[$0] ?? 0) }
        )
    }

    /// Cumulative distance at the last fix at or before `time`.
    static func distanceAt(_ track: Track, time: Double) -> Double {
        let f = track.fixes
        var lo = 0, hi = f.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if f[mid].time <= time {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best >= 0 ? track.cumulativeDistance[best] : 0
    }
}

/// When to take a reverse geocoding sample while moving (SPEC section 5).
nonisolated enum GeocodeSampler {
    /// True when a moving sample is due: the fix moves (at least 1 m/s), and the last sample is at
    /// least 60 s and 1 km away. Without any previous sample, true.
    static func shouldSample(fix: Fix, last: PlaceSample?) -> Bool {
        guard let v = fix.speed, v >= StatsConstants.movingSpeed else { return false }
        guard let last else { return true }
        let elapsed = fix.time - Double(last.timestampMs) / 1000
        guard elapsed >= StatsConstants.geocodeMinInterval else { return false }
        let d = Geo.distance(lat1: last.latitude, lon1: last.longitude, lat2: fix.latitude, lon2: fix.longitude)
        return d >= StatsConstants.geocodeMinDistance
    }
}
