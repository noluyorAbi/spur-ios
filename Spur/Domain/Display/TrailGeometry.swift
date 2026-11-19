import Foundation

/// Display-only geometry. Raw data on disk is never touched by any of this.
nonisolated enum TrailGeometry {
    /// Picks at most `budget` points for drawing. The first and last point are always kept and
    /// the most recent `keepTail` points stay at full resolution (the part the driver looks at);
    /// the older part is thinned by a regular stride.
    static func decimate(_ points: [LatLon], budget: Int, keepTail: Int = 0) -> [LatLon] {
        let n = points.count
        guard budget >= 2, n > budget else { return points }
        let tail = min(max(0, keepTail), budget / 2)
        let headCount = n - tail
        var out = strided(Array(points[0..<headCount]), budget: budget - tail)
        out.append(contentsOf: points[headCount..<n])
        return out
    }

    /// Regular stride that keeps the first and last point and returns at most `budget` points.
    static func strided(_ points: [LatLon], budget: Int) -> [LatLon] {
        let n = points.count
        guard n > budget else { return points }
        if budget <= 1 { return [points[0]] }
        let stride = Int((Double(n - 1) / Double(budget - 1)).rounded(.up))
        var out: [LatLon] = []
        out.reserveCapacity(budget)
        var i = 0
        while i < n - 1 {
            out.append(points[i])
            i += stride
        }
        if out.count >= budget { out.removeLast() }
        out.append(points[n - 1])
        return out
    }

    /// Direction chevrons along the recent trail: walking back from the end, one every `spacing`
    /// meters over the last `lookback` meters, at most `maxCount`, each rotated to the local
    /// bearing (degrees). Returned oldest first.
    static func chevrons(
        _ points: [LatLon], spacing: Double = 250, lookback: Double = 3000, maxCount: Int = 15
    ) -> [(point: LatLon, bearing: Double)] {
        guard points.count >= 2, spacing > 0 else { return [] }
        var out: [(LatLon, Double)] = []
        var walked = 0.0
        var nextMark = spacing
        var i = points.count - 1
        while i > 0 && walked < lookback && out.count < maxCount {
            let a = points[i - 1], b = points[i]
            let seg = Geo.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
            if seg > 0 {
                while nextMark <= walked + seg && nextMark <= lookback && out.count < maxCount {
                    // Position at `nextMark` meters back from the end, inside segment a-b.
                    let fromB = nextMark - walked
                    let t = fromB / seg
                    let p = LatLon(lat: b.lat + (a.lat - b.lat) * t, lon: b.lon + (a.lon - b.lon) * t)
                    out.append((p, Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)))
                    nextMark += spacing
                }
            }
            walked += seg
            i -= 1
        }
        return out.reversed()
    }

    /// The point `distance` meters along a polyline (clamped to its ends) and the bearing of the
    /// piece it lies on, in degrees.
    static func point(along points: [LatLon], at distance: Double) -> (point: LatLon, bearing: Double)? {
        guard points.count >= 2 else { return nil }
        var walked = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let d = Geo.distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
            if d > 0 && (walked + d >= distance || i == points.count - 1) {
                let t = min(1, max(0, (distance - walked) / d))
                return (LatLon(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t),
                        Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon))
            }
            walked += d
        }
        let a = points[points.count - 2], b = points[points.count - 1]
        return (b, Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon))
    }

    /// Direction marks along a line in its point order (SPEC 15.2): one every `spacing` meters,
    /// the first half a spacing from the start, so marks stay where they are while a trail grows
    /// at its end. A line shorter than a spacing gets one mark at its middle when it is at least
    /// `minLength` long (default 40 % of a spacing). The bearing is the chord from `chord / 2`
    /// before to `chord / 2` after the mark (clamped to the line), so a mark on a corner points
    /// along the road; with `chord` 0, the bearing of the piece it lies on.
    static func marks(along points: [LatLon], spacing: Double, minLength: Double? = nil,
                      chord: Double = 0) -> [(LatLon, Double)] {
        guard points.count >= 2, spacing > 0 else { return [] }
        var cum: [Double] = [0]
        cum.reserveCapacity(points.count)
        for i in 1..<points.count {
            cum.append(cum[i - 1] + Geo.distance(lat1: points[i - 1].lat, lon1: points[i - 1].lon, lat2: points[i].lat, lon2: points[i].lon))
        }
        let total = cum[cum.count - 1]
        guard total > 0 else { return [] }
        func at(_ d: Double) -> (LatLon, Int) {
            let x = min(max(0, d), total)
            var lo = 0, hi = cum.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if cum[mid] <= x { lo = mid } else { hi = mid }
            }
            let seg = cum[lo + 1] - cum[lo]
            let t = seg > 0 ? (x - cum[lo]) / seg : 0
            let a = points[lo], b = points[lo + 1]
            return (LatLon(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t), lo)
        }
        func mark(_ d: Double) -> (LatLon, Double) {
            let (p, leg) = at(d)
            if chord > 0 {
                let (a, _) = at(d - chord / 2), (b, _) = at(d + chord / 2)
                if a != b { return (p, Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)) }
            }
            var k = leg
            while k < points.count - 1 && points[k] == points[k + 1] { k += 1 }
            let a = points[min(k, points.count - 2)], b = points[min(k + 1, points.count - 1)]
            return (p, Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon))
        }
        if total < spacing {
            guard total >= (minLength ?? 0.4 * spacing) else { return [] }
            return [mark(total / 2)]
        }
        var out: [(LatLon, Double)] = []
        var d = spacing / 2
        while d <= total {
            out.append(mark(d))
            d += spacing
        }
        return out
    }

    /// Marks along a growing line, computed incrementally (SPEC 15.2): only appended points are
    /// walked, and a mark is placed once the line reaches half a chord beyond it, so marks never
    /// move. Same positions as `marks(along:spacing:minLength:chord:)` for a line long enough.
    struct Marker: Sendable {
        let spacing: Double
        let chord: Double
        private(set) var points: [LatLon] = []
        private var cum: [Double] = []
        private var next: Double
        private(set) var marks: [(point: LatLon, bearing: Double)] = []

        init(spacing: Double, chord: Double) {
            self.spacing = spacing
            self.chord = chord
            next = spacing / 2
        }

        var length: Double { cum.last ?? 0 }

        mutating func extend(_ new: some Sequence<LatLon>) {
            for p in new {
                if let last = points.last {
                    cum.append(cum[cum.count - 1] + Geo.distance(lat1: last.lat, lon1: last.lon, lat2: p.lat, lon2: p.lon))
                } else {
                    cum.append(0)
                }
                points.append(p)
            }
            while points.count >= 2, next + chord / 2 <= length {
                let p = at(next)
                let a = at(next - chord / 2), b = at(next + chord / 2)
                marks.append((p, a != b ? Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon) : bearing(near: next)))
                next += spacing
            }
        }

        private func index(_ d: Double) -> Int {
            var lo = 0, hi = cum.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if cum[mid] <= d { lo = mid } else { hi = mid }
            }
            return lo
        }

        private func at(_ d: Double) -> LatLon {
            let x = min(max(0, d), length)
            let i = index(x)
            let seg = cum[i + 1] - cum[i]
            let t = seg > 0 ? (x - cum[i]) / seg : 0
            let a = points[i], b = points[i + 1]
            return LatLon(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        }

        private func bearing(near d: Double) -> Double {
            let i = index(min(max(0, d), length))
            let a = points[i], b = points[i + 1]
            return Geo.bearing(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
        }
    }

    /// Display runs built incrementally: the same runs as `displayRuns` (the run in progress
    /// included once it has two points), feeding only the fixes added since the last call.
    struct RunBuilder: Sendable {
        private(set) var runs: [[Int]] = []
        private var current: [Int] = []
        private var previous: Fix?
        private(set) var consumed = 0

        mutating func extend(_ fixes: [Fix], config: StatsConfig) {
            guard consumed <= fixes.count else {
                self = RunBuilder()
                extend(fixes, config: config)
                return
            }
            for i in consumed..<fixes.count {
                let f = fixes[i]
                guard Track.isUsable(f, config) else { continue }
                if let p = previous {
                    let dt = f.time - p.time
                    let d = Geo.distance(p, f)
                    let jump = dt > 0 ? d / dt > maxDisplaySpeed : d > 100
                    if dt > StatsConstants.gapThreshold || jump {
                        if current.count >= 2 { runs.append(current) }
                        current = []
                    }
                }
                current.append(i)
                previous = f
            }
            consumed = fixes.count
        }

        /// Finished runs plus the one in progress.
        var all: [[Int]] { current.count >= 2 ? runs + [current] : runs }
    }

    /// Above this implied speed (m/s) two fixes are a jump, never driven road.
    static let maxDisplaySpeed: Double = 70

    /// Index runs of usable fixes to draw as separate lines. A new run starts after a gap (more
    /// than 5 s between usable fixes) or a jump no car can drive (implied speed above 70 m/s, or
    /// more than 100 m at the same instant), so no straight connector ever looks like road.
    /// Runs with fewer than two points are dropped. Display only.
    static func displayRuns(_ fixes: [Fix], config: StatsConfig) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        var previous: Fix?
        for (i, f) in fixes.enumerated() where Track.isUsable(f, config) {
            if let p = previous {
                let dt = f.time - p.time
                let d = Geo.distance(p, f)
                let jump = dt > 0 ? d / dt > maxDisplaySpeed : d > 100
                if dt > StatsConstants.gapThreshold || jump {
                    if current.count >= 2 { runs.append(current) }
                    current = []
                }
            }
            current.append(i)
            previous = f
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// The cached overview line of a trip: one polyline per display run, at most `budget`
    /// points in total. Display only.
    static func preview(_ fixes: [Fix], config: StatsConfig, budget: Int = 400) -> [[LatLon]] {
        let runs = displayRuns(fixes, config: config)
        let total = max(1, runs.reduce(0) { $0 + $1.count })
        return runs.map { run in
            let pts = run.map { LatLon(lat: fixes[$0].latitude, lon: fixes[$0].longitude) }
            return decimate(pts, budget: max(2, budget * run.count / total))
        }
    }

    /// Heading for the position puck: the fix course when valid, else the bearing between the
    /// last two points that are at least `minDistance` apart.
    static func heading(course: Double?, recent: [LatLon], minDistance: Double = 3) -> Double? {
        if let course { return course }
        guard let last = recent.last else { return nil }
        for p in recent.dropLast().reversed() {
            if Geo.distance(lat1: p.lat, lon1: p.lon, lat2: last.lat, lon2: last.lon) >= minDistance {
                return Geo.bearing(lat1: p.lat, lon1: p.lon, lat2: last.lat, lon2: last.lon)
            }
        }
        return nil
    }
}
