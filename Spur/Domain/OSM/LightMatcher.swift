import Foundation

/// One position for the matcher.
nonisolated struct MatchFix: Sendable, Equatable {
    /// Seconds since 1970.
    var time: Double
    var lat: Double
    var lon: Double
    var accuracy: Double?
    var speed: Double?
    var course: Double?

    init(time: Double, lat: Double, lon: Double, accuracy: Double?, speed: Double?, course: Double?) {
        self.time = time
        self.lat = lat
        self.lon = lon
        self.accuracy = accuracy
        self.speed = speed
        self.course = course
    }

    init(_ f: Fix) {
        self.init(time: f.time, lat: f.latitude, lon: f.longitude, accuracy: f.horizontalAccuracy, speed: f.speed, course: f.course)
    }

    var point: LatLon { LatLon(lat: lat, lon: lon) }
}

/// Where a fix is matched: a segment, the travel direction on it and the meters from its entry end.
nonisolated struct MatchPosition: Sendable, Equatable, Hashable {
    var segment: Int
    var direction: TravelDirection
    var offset: Double
}

/// A feature node on the matched path (containment rule, SPEC 14.4).
nonisolated struct FeaturePass: Sendable, Equatable {
    var nodeId: Int64
    /// Seconds since 1970, interpolated along the route between the two fixes around it.
    var time: Double
    /// The segment and direction on which the car arrives at the node.
    var segment: Int
    var direction: TravelDirection
    /// Index of the fix after which the node was passed.
    var fixIndex: Int
}

/// A piece of a segment driven between two matched fixes.
nonisolated struct DrivenPiece: Sendable, Equatable {
    var segment: Int
    var direction: TravelDirection
    var from: Double
    var to: Double
    var startTime: Double
    var endTime: Double
    /// On the route guessed across a GPS gap (more than 4 s without a usable fix), not observed.
    var bridged = false

    var length: Double { max(0, to - from) }
}

nonisolated struct MatchResult: Sendable {
    /// One entry per input fix: where it is matched, nil when it is not.
    var positions: [MatchPosition?] = []
    var passes: [FeaturePass] = []
    var pieces: [DrivenPiece] = []
    /// Runs of connected matching; a new run starts after a switch to an unconnected way or after
    /// the car left the network.
    var runs = 0
}

/// The light matcher of SPEC 14.4. Pure, sequential and incremental (the live counters feed it
/// fix by fix; a finished trip runs it over all fixes).
///
/// - Candidates: legal segment directions within clamp(2 x horizontal accuracy, 12, 30) m. At
///   3 m/s or more with a valid course, a candidate whose travel bearing differs from the course
///   by more than 40 degrees is rejected (one-way and roundabout ways only exist in their legal
///   direction).
/// - Score: perpendicular distance, plus a quarter of the difference between the route length and
///   the straight distance for a candidate joined to the current position, or a 20 m penalty for
///   one that is not. "Joined" means reachable from the current position through shared nodes in
///   the legal direction within max(60 m, 2 x straight + 40 m), and at most 1000 m and what 70 m/s
///   allow in the elapsed time (so a short GPS gap such as a tunnel is bridged along the road).
/// - Switching to an unjoined way needs 3 consecutive fixes that prefer it; until then the best
///   joined candidate is used, or the match holds. The first match of a run also needs 3
///   consecutive fixes that prefer the same way.
/// - Fixes above 30 m accuracy (or without one) or slower than 1 m/s keep the current match.
/// - Three moving fixes in a row without any candidate end the run (the car left the network).
/// - Containment: a node counts only when it lies on the matched path, between the matched
///   positions on one segment or on the route between two of them. Proximity alone never counts.
nonisolated struct LightMatcher {
    struct Candidate: Equatable {
        var position: MatchPosition
        var distance: Double
        var way: Int64
    }

    let net: RoadNetwork
    private(set) var result = MatchResult()

    private var current: MatchPosition?
    /// Furthest offset reached on the current segment pass (white noise never moves the car back).
    private var progress = 0.0
    private var lastFix: MatchFix?
    private var lastNode: Int64?
    private var pending: (way: Int64, count: Int, candidates: [(Int, MatchFix, Candidate)])?
    private var noCandidateStreak = 0
    private var index = 0

    init(network: RoadNetwork) {
        net = network
    }

    static func match(_ fixes: [MatchFix], network: RoadNetwork) -> MatchResult {
        var m = LightMatcher(network: network)
        for f in fixes { m.add(f) }
        return m.result
    }

    var currentPosition: MatchPosition? { current }

    // MARK: Per fix

    mutating func add(_ f: MatchFix) {
        defer {
            result.positions.append(current)
            index += 1
        }
        guard let acc = f.accuracy, acc <= RoadConstants.matchMaxAccuracyM else { return }
        if let v = f.speed, v < RoadConstants.stationarySpeed { return }

        let cands = candidates(f, accuracy: acc)
        if cands.isEmpty {
            pending = nil
            noCandidateStreak += 1
            if noCandidateStreak >= 3 { endRun() }
            return
        }
        noCandidateStreak = 0

        guard let cur = current, let prev = lastFix else {
            acquire(f, cands)
            return
        }

        let straight = OSMGeo.haversine(prev.point, f.point)
        let dt = max(0, f.time - prev.time)
        let limit = min(1000, max(60, 2 * straight + 40), 70 * dt + 40)
        let reach = Router(net: net).reachable(from: cur, limit: limit)

        var bestJoined: (Candidate, Double, [Hop], Double)?   // candidate, score, route, length
        var bestAny: (Candidate, Double, Bool)?
        for c in cands {
            if let (length, route) = joined(cur, c, reach: reach, accuracy: acc, limit: limit) {
                let score = c.distance + abs(length - straight) / 4
                if bestJoined == nil || score < bestJoined!.1 { bestJoined = (c, score, route, length) }
                if bestAny == nil || score < bestAny!.1 { bestAny = (c, score, true) }
            } else {
                let score = c.distance + RoadConstants.unconnectedPenaltyM
                if bestAny == nil || score < bestAny!.1 { bestAny = (c, score, false) }
            }
        }
        guard let best = bestAny else { return }
        if best.2 {
            pending = nil
            let j = bestJoined!
            advance(to: j.0.position, route: j.2, length: j.3, from: prev, to: f)
            lastFix = f
            return
        }
        // The best candidate is on an unjoined way.
        if pending?.way == best.0.way {
            pending!.count += 1
        } else {
            pending = (best.0.way, 1, [])
        }
        if pending!.count >= RoadConstants.switchFixes {
            pending = nil
            endRun()
            startRun(at: best.0.position, fix: f)
            return
        }
        if let j = bestJoined {
            advance(to: j.0.position, route: j.2, length: j.3, from: prev, to: f)
            lastFix = f
        }
    }

    // MARK: Candidates

    func candidates(_ f: MatchFix, accuracy: Double) -> [Candidate] {
        let radius = min(RoadConstants.candidateMaxM, max(RoadConstants.candidateMinM, 2 * accuracy))
        let p = f.point
        var out: [Candidate] = []
        let checkHeading = (f.speed ?? 0) >= RoadConstants.headingMinSpeed && f.course != nil
        for k in net.segmentsNear(p, radius: radius) {
            let s = net.segments[k]
            let pr = OSMGeo.project(p, onto: s.coords)
            guard pr.distance <= radius else { continue }
            let along = min(s.length, s.cum[pr.leg] + OSMGeo.haversine(s.coords[pr.leg], pr.point))
            for d in s.directions {
                let bearing = d == .forward ? pr.bearing : (pr.bearing + 180).truncatingRemainder(dividingBy: 360)
                if checkHeading, OSMGeo.angleDiff(bearing, f.course!) > RoadConstants.headingMaxDiffDeg { continue }
                out.append(Candidate(position: MatchPosition(segment: k, direction: d, offset: d == .forward ? along : s.length - along),
                                     distance: pr.distance, way: s.wayId))
            }
        }
        return out
    }

    /// Route length and the full segments in between when `c` is joined to `cur`, else nil.
    private func joined(_ cur: MatchPosition, _ c: Candidate, reach: Router.Reach, accuracy: Double, limit: Double) -> (Double, [Hop])? {
        let p = c.position
        if p.segment == cur.segment {
            guard p.direction == cur.direction else { return nil } // no U-turn on one segment
            // Backward slip within the noise of two fixes is standing still.
            let slip = 3 * accuracy * 2.0.squareRoot() + 5
            if p.offset >= progress - slip { return (max(0, p.offset - progress), []) }
            return nil
        }
        let s = net.segments[p.segment]
        guard let (d, route) = reach.route(to: s.entryNode(p.direction)) else { return nil }
        let length = d + p.offset
        guard length <= limit else { return nil }
        return (length, route)
    }

    // MARK: Runs

    private mutating func acquire(_ f: MatchFix, _ cands: [Candidate]) {
        let best = cands.min { $0.distance < $1.distance }!
        if pending?.way == best.way {
            pending!.count += 1
            pending!.candidates.append((index, f, best))
        } else {
            pending = (best.way, 1, [(index, f, best)])
        }
        guard pending!.count >= RoadConstants.switchFixes else { return }
        let steps = pending!.candidates
        pending = nil
        startRun(at: steps[0].2.position, fix: steps[0].1)
        // Walk through the other fixes of the acquisition on the same way.
        for (_, fx, c) in steps.dropFirst() {
            guard let cur = current, let prev = lastFix else { break }
            let straight = OSMGeo.haversine(prev.point, fx.point)
            let dt = max(0, fx.time - prev.time)
            let limit = min(1000, max(60, 2 * straight + 40), 70 * dt + 40)
            let reach = Router(net: net).reachable(from: cur, limit: limit)
            if let (length, route) = joined(cur, c, reach: reach, accuracy: fx.accuracy ?? 10, limit: limit) {
                advance(to: c.position, route: route, length: length, from: prev, to: fx)
                lastFix = fx
            }
        }
    }

    private mutating func startRun(at p: MatchPosition, fix: MatchFix) {
        current = p
        progress = p.offset
        lastFix = fix
        lastNode = nil
        result.runs += 1
    }

    private mutating func endRun() {
        current = nil
        lastFix = nil
        lastNode = nil
    }

    // MARK: Moving along the path

    private mutating func advance(to target: MatchPosition, route: [Hop], length: Double, from a: MatchFix, to b: MatchFix) {
        guard let cur = current else { return }
        let t0 = a.time, t1 = b.time
        var walked = 0.0
        let time: (Double) -> Double = { m in length > 0 ? t0 + (t1 - t0) * min(1, m / length) : t1 }
        if target.segment == cur.segment && target.direction == cur.direction {
            if target.offset > progress {
                emit(segment: cur.segment, direction: cur.direction, from: progress, to: target.offset, startM: 0, time: time)
                result.pieces.append(DrivenPiece(segment: cur.segment, direction: cur.direction, from: progress, to: target.offset,
                                                 startTime: t0, endTime: t1))
                progress = target.offset
            }
            current = MatchPosition(segment: cur.segment, direction: cur.direction, offset: progress)
            return
        }
        // Rest of the current segment, the full segments in between, the start of the target.
        let curLen = net.segments[cur.segment].length
        var legs: [(Int, TravelDirection, Double, Double)] = [(cur.segment, cur.direction, progress, curLen)]
        for hop in route { legs.append((hop.segment, hop.direction, 0, net.segments[hop.segment].length)) }
        legs.append((target.segment, target.direction, 0, target.offset))
        for (seg, dir, lo, hi) in legs {
            let start = walked
            emit(segment: seg, direction: dir, from: lo, to: hi, startM: start, time: time)
            if hi > lo {
                result.pieces.append(DrivenPiece(segment: seg, direction: dir, from: lo, to: hi,
                                                 startTime: time(start), endTime: time(start + hi - lo)))
            }
            walked += max(0, hi - lo)
        }
        current = target
        progress = target.offset
    }

    /// Records the nodes of a segment strictly after `from` and up to `to` (travel offsets).
    private mutating func emit(segment k: Int, direction d: TravelDirection, from lo: Double, to hi: Double,
                               startM: Double, time: (Double) -> Double) {
        let s = net.segments[k]
        let n = s.nodeIds.count
        for j in 0..<n {
            let i = d == .forward ? j : n - 1 - j
            let off = d == .forward ? s.cum[i] : s.length - s.cum[i]
            guard off > lo || (off == 0 && lo == 0 && j == 0 && lastNode != nil), off <= hi else { continue }
            let id = s.nodeIds[i]
            if id == lastNode { continue }
            lastNode = id
            if net.features[id] != nil {
                result.passes.append(FeaturePass(nodeId: id, time: time(startM + max(0, off - lo)), segment: k, direction: d, fixIndex: index))
            }
        }
    }
}

/// One full segment direction of a route.
nonisolated struct Hop: Sendable, Equatable {
    var segment: Int
    var direction: TravelDirection
}

/// Bounded Dijkstra over the legal directions of the segments (parent: connected topology only,
/// so stacked roads that merely overlap in 2D are never joined).
nonisolated struct Router {
    let net: RoadNetwork

    struct Reach {
        var dist: [Int64: Double]
        var prev: [Int64: (Int64, Hop)]
        var startNode: Int64
        var base: Double

        /// Distance from the start position to a node, and the full segments driven before it.
        func route(to node: Int64) -> (Double, [Hop])? {
            guard let d = dist[node] else { return nil }
            var hops: [Hop] = []
            var n = node
            while n != startNode, let (p, hop) = prev[n] {
                hops.append(hop)
                n = p
            }
            return (d, hops.reversed())
        }
    }

    /// Every node reachable from a matched position within `limit` meters, leaving its segment at
    /// the exit node. Turning back onto the same segment is not allowed.
    func reachable(from cur: MatchPosition, limit: Double) -> Reach {
        let s = net.segments[cur.segment]
        let start = s.exitNode(cur.direction)
        let base = max(0, s.length - cur.offset)
        var dist: [Int64: Double] = [start: base]
        var prev: [Int64: (Int64, Hop)] = [:]
        var heap = MinHeap()
        heap.push(base, start)
        while let (d, node) = heap.pop() {
            guard d <= dist[node] ?? .infinity, d <= limit else { continue }
            for end in net.ends[node] ?? [] {
                let seg = net.segments[end.segment]
                let dir: TravelDirection = end.atStart ? .forward : .backward
                guard seg.allows(dir) else { continue }
                if end.segment == cur.segment && node == start { continue }
                let next = seg.exitNode(dir)
                let nd = d + seg.length
                if nd <= limit && nd < dist[next] ?? .infinity {
                    dist[next] = nd
                    prev[next] = (node, Hop(segment: end.segment, direction: dir))
                    heap.push(nd, next)
                }
            }
        }
        return Reach(dist: dist, prev: prev, startNode: start, base: base)
    }
}

/// A small binary heap for the router.
nonisolated struct MinHeap {
    private var items: [(Double, Int64)] = []

    mutating func push(_ key: Double, _ value: Int64) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].0 <= items[i].0 { break }
            items.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (Double, Int64)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
