import Foundation

/// The parent's HMM map matcher (`src/lib/matcher/*`: graph, prepare, route, viterbi), ported to
/// Swift because the light matcher missed the acceptance of SPEC 14.4. Newson
/// and Krumm (2009) with the parent's additions: slip on one segment is standing still, outlier
/// layers may be skipped, runs may break, GPS gaps up to 1000 m are bridged along connected
/// topology, a heading term above 3 m/s, a turn-consistency term and a speed-consistency term.
/// Pure and deterministic. The feature passes come from the decoded path by the containment rule.
///
/// Matching is the parent's, unchanged (candidate radius max(25, 2 x accuracy) m). One addition on
/// the counting side (`PathWalker`, `countingGuard`): a node on the matched path counts as passed
/// only when the fixes matched to the road pieces around it lie, by their median, within the
/// candidate radius of SPEC 14.4, clamp(2 x accuracy, 12, 30) m. Without it, parking-lot fixes 12
/// to 20 m beside a road are matched onto the road and pass its junctions (parent case 9;
/// measured against the alternatives).
nonisolated enum HMMTuning {
    // Parent `src/shared/constants.ts`.
    static let minCandidateRadiusM = 25.0
    static let sigmaMinM = 4.0
    static let sigmaMaxM = 20.0
    static let maxRouteSearchM = 2000.0
    static let headingMinSpeedMps = 3.0
    static let headingMaxDiffDeg = 45.0
    static let maxGapBridgeM = 1000.0
    static let maxCoverageAccuracyM = 30.0
    static let stationarySpeedMps = 1.0
    // Parent `src/lib/matcher/tuning.ts`.
    static let betaM = 5.0
    static let maxPlausibleSpeedMps = 70.0
    static let routeSlackM = 40.0
    static let untimedRouteFactor = 2.0
    static let slipSigmas = 3.0
    static let slipExtraM = 5.0
    static let uturnCostM = 200.0
    static let uturnLogP = -20.0
    static let headingSdDeg = 20.0
    static let headingMismatchLogP = -12.0
    static let headingMismatchPerDeg = 1.0 / 15
    static let turnToleranceDeg = 45.0
    static let turnScaleDeg = 20.0
    static let headingEstimateSigmas = 4.0
    static let speedDriftMps = 0.5
    static let speedTermExtraM = 3.0
    static let skipLogP = -8.0
    static let maxSkipLayers = 2
    static let breakLogP = -40.0
    static let gapMinS = 4.0
    static let maxGapBridgeS = 600.0
    static let offroadBreakFixes = 3
    static let defaultAccuracyM = 10.0
    static let maxCandidates = 32
    static let speedWindowMs = 2000.0
    static let minBearingLegM = 0.5
    static let cellDeg = 0.0005

    /// Which candidate radius the matcher uses.
    enum CandidateRadius: String, Sendable, CaseIterable {
        /// The parent's `max(MIN_CANDIDATE_RADIUS_M, 2 x accuracy)`, 25 m at least. Spur's default.
        case parent
        /// SPEC 14.4: clamp(2 x accuracy, 12, 30) m. Measured as an alternative, not used.
        case spur

        func radius(accuracy acc: Double) -> Double {
            switch self {
            case .spur: min(RoadConstants.candidateMaxM, max(RoadConstants.candidateMinM, 2 * acc))
            case .parent: max(HMMTuning.minCandidateRadiusM, 2 * acc)
            }
        }
    }
}

/// Parent `RoadGraph`: one directed edge per legal segment direction and a grid over the legs.
nonisolated struct HMMGraph: Sendable {
    let net: RoadNetwork
    let legBearing: [[Double]]
    let segLen: [Double]
    let edgeSeg: [Int]
    let edgeBackward: [Bool]
    let edgeStart: [Int]
    let edgeEnd: [Int]
    let edgeTwin: [Int]
    let edgeEntryBearing: [Double]
    let edgeExitBearing: [Double]
    let edgeInnerTurn: [Double]
    let segEdge: [Int]
    let nodeOut: [[Int]]
    let cellLat: Double
    let cellLon: Double
    let cells: [Int64: [Int]]

    init(_ net: RoadNetwork) {
        self.net = net
        let n = net.segments.count
        var legBearing: [[Double]] = []
        var segLen: [Double] = []
        var latSum = 0.0
        for s in net.segments {
            var b: [Double] = []
            for i in 1..<s.coords.count { b.append(OSMGeo.bearing(s.coords[i - 1], s.coords[i])) }
            legBearing.append(b)
            segLen.append(s.cum.last ?? 0)
            latSum += s.coords[0].lat
        }
        var nodeIndex: [Int64: Int] = [:]
        func nodeOf(_ id: Int64) -> Int {
            if let i = nodeIndex[id] { return i }
            let i = nodeIndex.count
            nodeIndex[id] = i
            return i
        }
        var eSeg: [Int] = [], eBack: [Bool] = [], eStart: [Int] = [], eEnd: [Int] = []
        var eIn: [Double] = [], eOut: [Double] = [], eTurn: [Double] = []
        var segEdge = [Int](repeating: -1, count: 2 * n)
        for (k, seg) in net.segments.enumerated() {
            let from = nodeOf(seg.fromNode)
            let to = nodeOf(seg.toNode)
            let shape = HMMGraph.shape(cum: seg.cum, bearings: legBearing[k])
            if seg.directions.contains(.forward) {
                segEdge[2 * k] = eSeg.count
                eSeg.append(k); eBack.append(false); eStart.append(from); eEnd.append(to)
                eIn.append(shape.entry); eOut.append(shape.exit); eTurn.append(shape.turn)
            }
            if seg.directions.contains(.backward) {
                segEdge[2 * k + 1] = eSeg.count
                eSeg.append(k); eBack.append(true); eStart.append(to); eEnd.append(from)
                eIn.append((shape.exit + 180).truncatingRemainder(dividingBy: 360))
                eOut.append((shape.entry + 180).truncatingRemainder(dividingBy: 360))
                eTurn.append(shape.turn)
            }
        }
        var twin = [Int](repeating: -1, count: eSeg.count)
        for k in 0..<n {
            let f = segEdge[2 * k], b = segEdge[2 * k + 1]
            if f >= 0 && b >= 0 {
                twin[f] = b
                twin[b] = f
            }
        }
        var out = [[Int]](repeating: [], count: nodeIndex.count)
        for e in 0..<eSeg.count { out[eStart[e]].append(e) }

        let refLat = n > 0 ? latSum / Double(n) : 0
        let c = max(0.17, cos(min(80, abs(refLat)) * .pi / 180))
        let cellLat = HMMTuning.cellDeg
        let cellLon = HMMTuning.cellDeg / c
        var cells: [Int64: [Int]] = [:]
        for (k, seg) in net.segments.enumerated() {
            for i in 1..<seg.coords.count {
                let a = seg.coords[i - 1], z = seg.coords[i]
                let x0 = Int(floor(min(a.lon, z.lon) / cellLon)), x1 = Int(floor(max(a.lon, z.lon) / cellLon))
                let y0 = Int(floor(min(a.lat, z.lat) / cellLat)), y1 = Int(floor(max(a.lat, z.lat) / cellLat))
                for ix in x0...x1 {
                    for iy in y0...y1 {
                        let key = HMMGraph.cellKey(ix, iy)
                        if cells[key]?.last != k { cells[key, default: []].append(k) }
                    }
                }
            }
        }
        self.legBearing = legBearing
        self.segLen = segLen
        edgeSeg = eSeg
        edgeBackward = eBack
        edgeStart = eStart
        edgeEnd = eEnd
        edgeTwin = twin
        edgeEntryBearing = eIn
        edgeExitBearing = eOut
        edgeInnerTurn = eTurn
        self.segEdge = segEdge
        nodeOut = out
        self.cellLat = cellLat
        self.cellLon = cellLon
        self.cells = cells
    }

    static func cellKey(_ ix: Int, _ iy: Int) -> Int64 { (Int64(ix) + (1 << 20)) * (1 << 21) + (Int64(iy) + (1 << 20)) }

    static func shape(cum: [Double], bearings: [Double]) -> (entry: Double, exit: Double, turn: Double) {
        var usable: [Double] = []
        for i in 0..<bearings.count where cum[i + 1] - cum[i] >= HMMTuning.minBearingLegM { usable.append(bearings[i]) }
        if usable.isEmpty { return (bearings.first ?? 0, bearings.last ?? 0, 0) }
        var turn = 0.0
        for i in 1..<usable.count { turn += OSMGeo.angleDiff(usable[i - 1], usable[i]) }
        return (usable[0], usable[usable.count - 1], turn)
    }

    func edgeLen(_ e: Int) -> Double { segLen[edgeSeg[e]] }
    func direction(_ e: Int) -> TravelDirection { edgeBackward[e] ? .backward : .forward }

    /// Parent `segmentsNear`: segments with a leg in a grid cell within the radius, ascending.
    func segmentsNear(lat: Double, lon: Double, radius: Double) -> [Int] {
        let mPerDeg = Double.pi / 180 * OSMGeo.R
        let dLat = radius / mPerDeg
        let dLon = radius / (mPerDeg * max(0.01, cos(lat * .pi / 180)))
        let x0 = Int(floor((lon - dLon) / cellLon)), x1 = Int(floor((lon + dLon) / cellLon))
        let y0 = Int(floor((lat - dLat) / cellLat)), y1 = Int(floor((lat + dLat) / cellLat))
        var seen: Set<Int> = []
        for ix in x0...x1 {
            for iy in y0...y1 {
                if let list = cells[HMMGraph.cellKey(ix, iy)] { seen.formUnion(list) }
            }
        }
        return seen.sorted()
    }

    /// Parent `projectOnSegment`: distance, offset from the from node (haversine basis) and leg.
    func project(_ s: Int, lat: Double, lon: Double) -> (dist: Double, offF: Double, leg: Int) {
        let coords = net.segments[s].coords
        let cum = net.segments[s].cum
        let mPerDeg = Double.pi / 180 * OSMGeo.R
        let kx = mPerDeg * cos(lat * .pi / 180)
        let ky = mPerDeg
        var best = Double.infinity, offF = 0.0, leg = 0
        for i in 1..<coords.count {
            let a = coords[i - 1], b = coords[i]
            let ax = (a.lon - lon) * kx, ay = (a.lat - lat) * ky
            let dx = (b.lon - lon) * kx - ax, dy = (b.lat - lat) * ky - ay
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
            let px = ax + t * dx, py = ay + t * dy
            let d = (px * px + py * py).squareRoot()
            if d < best {
                best = d
                offF = cum[i - 1] + t * (cum[i] - cum[i - 1])
                leg = i - 1
            }
        }
        return (best, offF, leg)
    }
}

/// Parent `prepare.ts`.
nonisolated struct HMMFixInfo {
    struct Candidate {
        var edge: Int
        var off: Double
        var dist: Double
        var logE: Double
    }

    var fix: MatchFix
    var tMs: Double
    var index: Int
    var usable: Bool
    var moving = false
    var sigma: Double
    var radius: Double
    var speed: Double?
    var speedReported: Bool
    var turnHeading: Double?
    var cands: [Candidate] = []

    static func headingLogP(_ heading: Double, _ bearing: Double) -> Double {
        let diff = OSMGeo.angleDiff(heading, bearing)
        if diff > HMMTuning.headingMaxDiffDeg {
            return HMMTuning.headingMismatchLogP - (diff - HMMTuning.headingMaxDiffDeg) * HMMTuning.headingMismatchPerDeg
        }
        return -0.5 * pow(diff / HMMTuning.headingSdDeg, 2)
    }

    static func windowAround(_ infos: [HMMFixInfo], _ k: Int) -> (Int, Int) {
        let here = infos[k]
        var a = k
        while a > 0 && infos[a - 1].usable && here.tMs - infos[a].tMs < HMMTuning.speedWindowMs { a -= 1 }
        var b = k
        while b < infos.count - 1 && infos[b + 1].usable && infos[b].tMs - here.tMs < HMMTuning.speedWindowMs { b += 1 }
        return (a, b)
    }

    static func estimateSpeed(_ infos: [HMMFixInfo], _ k: Int) -> Double? {
        let (a, b) = windowAround(infos, k)
        if a == b { return nil }
        let fa = infos[a], fb = infos[b]
        let dt = (fb.tMs - fa.tMs) / 1000
        guard dt > 0 else { return nil }
        return max(0, OSMGeo.haversine(fa.fix.point, fb.fix.point) - infos[k].sigma) / dt
    }

    static func estimateHeading(_ infos: [HMMFixInfo], _ k: Int) -> Double? {
        let (a, b) = windowAround(infos, k)
        if a == b { return nil }
        let fa = infos[a], fb = infos[b]
        let noise = (fa.sigma * fa.sigma + fb.sigma * fb.sigma).squareRoot()
        return OSMGeo.haversine(fa.fix.point, fb.fix.point) >= HMMTuning.headingEstimateSigmas * noise
            ? OSMGeo.bearing(fa.fix.point, fb.fix.point) : nil
    }

    /// Fix infos in time order with candidates for every usable moving fix.
    static func prepare(_ fixes: [MatchFix], order: [Int], g: HMMGraph,
                        radiusRule: HMMTuning.CandidateRadius = .parent) -> [HMMFixInfo] {
        var infos: [HMMFixInfo] = order.map { index in
            let f = fixes[index]
            let valid = f.lat.isFinite && f.lon.isFinite && f.time.isFinite && abs(f.lat) <= 90 && abs(f.lon) <= 180
            let accuracy = f.accuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let usable = valid && (accuracy == nil || accuracy! <= HMMTuning.maxCoverageAccuracyM)
            let acc = accuracy ?? HMMTuning.defaultAccuracyM
            let speed = f.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return HMMFixInfo(fix: f, tMs: (f.time * 1000).rounded(), index: index, usable: usable,
                              sigma: min(HMMTuning.sigmaMaxM, max(HMMTuning.sigmaMinM, acc)),
                              radius: radiusRule.radius(accuracy: acc), speed: speed, speedReported: speed != nil)
        }
        for k in 0..<infos.count {
            guard infos[k].usable else { continue }
            if infos[k].speed == nil { infos[k].speed = estimateSpeed(infos, k) }
            infos[k].moving = infos[k].speed == nil || infos[k].speed! >= HMMTuning.stationarySpeedMps
            guard infos[k].moving else { continue }
            let info = infos[k]
            let lat = info.fix.lat, lon = info.fix.lon
            let heading: Double? = {
                guard let h = info.fix.course, h.isFinite, let v = info.speed, v > HMMTuning.headingMinSpeedMps else { return nil }
                return h
            }()
            infos[k].turnHeading = heading ?? estimateHeading(infos, k)
            var cands: [Candidate] = []
            for s in g.segmentsNear(lat: lat, lon: lon, radius: info.radius) {
                let pr = g.project(s, lat: lat, lon: lon)
                guard pr.dist <= info.radius else { continue }
                let len = g.segLen[s]
                let emission = -0.5 * pow(pr.dist / info.sigma, 2)
                let legBearing = pr.leg < g.legBearing[s].count ? g.legBearing[s][pr.leg] : 0
                for backward in [false, true] {
                    let edge = g.segEdge[2 * s + (backward ? 1 : 0)]
                    guard edge >= 0 else { continue }
                    let off = backward ? len - pr.offF : pr.offF
                    let bearing = backward ? (legBearing + 180).truncatingRemainder(dividingBy: 360) : legBearing
                    let logE = emission + (heading.map { headingLogP($0, bearing) } ?? 0)
                    cands.append(Candidate(edge: edge, off: max(0, min(len, off)), dist: pr.dist, logE: logE))
                }
            }
            cands.sort { a, b in
                if a.logE != b.logE { return a.logE > b.logE }
                if a.dist != b.dist { return a.dist < b.dist }
                return a.edge < b.edge
            }
            infos[k].cands = Array(cands.prefix(HMMTuning.maxCandidates))
        }
        return infos
    }
}

/// Parent `route.ts`: bounded Dijkstra on the directed edges; a U-turn onto the twin costs extra.
nonisolated final class HMMRouteTree {
    let bound: Double
    var dist: [Int: Double] = [:]
    var cost: [Int: Double] = [:]
    var pred: [Int: Int] = [:]
    var uturns: [Int: Int] = [:]
    var turn: [Int: Double] = [:]

    init(bound: Double) { self.bound = bound }

    struct Item {
        var cost: Double
        var dist: Double
        var edge: Int
        var pred: Int
        var uturns: Int
        var turn: Double

        func before(_ b: Item) -> Bool {
            cost < b.cost || (cost == b.cost && (edge < b.edge || (edge == b.edge && pred < b.pred)))
        }
    }

    static func search(_ g: HMMGraph, source: Int, bound: Double) -> HMMRouteTree {
        let tree = HMMRouteTree(bound: bound)
        var heap: [Item] = []
        func push(_ it: Item) {
            heap.append(it)
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if !heap[i].before(heap[p]) { break }
                heap.swapAt(i, p)
                i = p
            }
        }
        func pop() -> Item? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && heap[l].before(heap[m]) { m = l }
                    if r < heap.count && heap[r].before(heap[m]) { m = r }
                    if m == i { break }
                    heap.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
        let start = g.edgeEnd[source]
        let twin = g.edgeTwin[source]
        let exit0 = g.edgeExitBearing[source]
        for f in g.nodeOut[start] {
            let u = f == twin ? 1 : 0
            push(Item(cost: Double(u) * HMMTuning.uturnCostM, dist: 0, edge: f, pred: -1, uturns: u,
                      turn: OSMGeo.angleDiff(exit0, g.edgeEntryBearing[f])))
        }
        while let it = pop() {
            if it.cost > bound { break }
            if tree.cost[it.edge] != nil { continue }
            tree.cost[it.edge] = it.cost
            tree.dist[it.edge] = it.dist
            tree.pred[it.edge] = it.pred
            tree.uturns[it.edge] = it.uturns
            tree.turn[it.edge] = it.turn
            let len = g.edgeLen(it.edge)
            let endCost = it.cost + len
            if endCost > bound { continue }
            let endDist = it.dist + len
            let t = g.edgeTwin[it.edge]
            let endTurn = it.turn + g.edgeInnerTurn[it.edge]
            let exit = g.edgeExitBearing[it.edge]
            for f in g.nodeOut[g.edgeEnd[it.edge]] where tree.cost[f] == nil {
                let u = f == t ? 1 : 0
                push(Item(cost: endCost + Double(u) * HMMTuning.uturnCostM, dist: endDist, edge: f, pred: it.edge,
                          uturns: it.uturns + u, turn: endTurn + OSMGeo.angleDiff(exit, g.edgeEntryBearing[f])))
            }
        }
        return tree
    }

    /// Edges strictly between the source and `target`, in travel order.
    func via(_ target: Int) -> [Int] {
        var out: [Int] = []
        var e = pred[target] ?? -1
        while e >= 0 {
            out.append(e)
            e = pred[e] ?? -1
        }
        return out.reversed()
    }
}

nonisolated enum HMMMatcher {
    struct Decoded {
        var fi: Int
        var edge: Int
        var eff: Double
        var off: Double
        var newRun: Bool
        var via: [Int]?
        var gap: Bool
    }

    private struct PairInfo {
        var allowed: Bool
        var gap: Bool
        var maxRoute: Double
        var gc: Double
        var slipSd: Double
        var slipMax: Double
        var headingChange: Double?
        var speedDist: Double?
        var speedSd: Double
    }

    private struct State {
        var score: Double
        var eff: Double
        var pl: Int
        var pc: Int
        var brk: Bool
        var via: [Int]?
        var gap: Bool
    }

    /// Matches fixes (any order) and returns positions per input fix, feature passes and pieces.
    static func match(_ fixes: [MatchFix], network: RoadNetwork, radius: HMMTuning.CandidateRadius = .parent,
                      countingGuard: Bool = true) -> MatchResult {
        let g = HMMGraph(network)
        return match(fixes, graph: g, radius: radius, countingGuard: countingGuard)
    }

    static func match(_ fixes: [MatchFix], graph g: HMMGraph, radius: HMMTuning.CandidateRadius = .parent,
                      countingGuard: Bool = true) -> MatchResult {
        let order = fixes.indices.sorted { a, b in
            let ta = fixes[a].time.isFinite ? fixes[a].time : .infinity
            let tb = fixes[b].time.isFinite ? fixes[b].time : .infinity
            return ta != tb ? ta < tb : a < b
        }
        let infos = HMMFixInfo.prepare(fixes, order: order, g: g, radiusRule: radius)
        let decoded = decode(infos, g)
        return PathWalker.result(decoded: decoded, infos: infos, graph: g, fixCount: fixes.count, countingGuard: countingGuard)
    }

    static func decode(_ infos: [HMMFixInfo], _ g: HMMGraph) -> [Decoded] {
        var layers: [Int] = []
        var offPrefix = [Int](repeating: 0, count: infos.count + 1)
        var usableGapMs = [Double](repeating: 0, count: infos.count)
        var lastUsableT: Double?
        for (i, info) in infos.enumerated() {
            let off = info.usable && info.moving && info.cands.isEmpty
            offPrefix[i + 1] = offPrefix[i] + (off ? 1 : 0)
            if info.usable {
                usableGapMs[i] = lastUsableT.map { info.tMs - $0 } ?? 0
                lastUsableT = info.tMs
                if info.moving && !info.cands.isEmpty { layers.append(i) }
            }
        }
        let L = layers.count
        if L == 0 { return [] }
        var trees: [Int: HMMRouteTree] = [:]
        func tree(from source: Int, bound: Double) -> HMMRouteTree {
            if let hit = trees[source], hit.bound >= bound { return hit }
            if trees.count >= 512 { trees.removeAll() }
            let t = HMMRouteTree.search(g, source: source, bound: max(bound, 250))
            trees[source] = t
            return t
        }

        func pairInfo(_ p: Int, _ k: Int) -> PairInfo {
            let a = layers[p], b = layers[k]
            let fa = infos[a], fb = infos[b]
            let offCount = offPrefix[b] - offPrefix[a + 1]
            var maxGap = 0.0
            var speedDist: Double? = fa.speedReported ? 0 : nil
            var prev = fa
            if a + 1 <= b {
                for i in (a + 1)...b {
                    let info = infos[i]
                    guard info.usable else { continue }
                    maxGap = max(maxGap, usableGapMs[i])
                    if let sd = speedDist {
                        speedDist = info.speedReported ? sd + (((prev.speed ?? 0) + (info.speed ?? 0)) / 2) * ((info.tMs - prev.tMs) / 1000) : nil
                    }
                    prev = info
                }
            }
            let gap = maxGap > HMMTuning.gapMinS * 1000
            let allowed = offCount < HMMTuning.offroadBreakFixes && maxGap <= HMMTuning.maxGapBridgeS * 1000
            let dt = max(0, (fb.tMs - fa.tMs) / 1000)
            let gc = OSMGeo.haversine(fa.fix.point, fb.fix.point)
            let slack = HMMTuning.routeSlackM + 4 * max(fa.sigma, fb.sigma)
            let timed = HMMTuning.maxPlausibleSpeedMps * dt
            let reach = gc > timed && !(fa.speedReported && fb.speedReported) ? max(timed, HMMTuning.untimedRouteFactor * gc) : timed
            let maxRoute = min(gap ? HMMTuning.maxGapBridgeM : HMMTuning.maxRouteSearchM, reach + slack)
            let sd = (fa.sigma * fa.sigma + fb.sigma * fb.sigma).squareRoot()
            let headingChange: Double? = {
                guard !gap, let ha = fa.turnHeading, let hb = fb.turnHeading else { return nil }
                return OSMGeo.angleDiff(ha, hb)
            }()
            let drift = HMMTuning.speedDriftMps * dt
            return PairInfo(allowed: allowed, gap: gap, maxRoute: maxRoute, gc: gc, slipSd: sd,
                            slipMax: HMMTuning.slipSigmas * sd + HMMTuning.slipExtraM, headingChange: headingChange,
                            speedDist: gap ? nil : speedDist,
                            speedSd: (fa.sigma * fa.sigma + fb.sigma * fb.sigma + drift * drift + HMMTuning.speedTermExtraM * HMMTuning.speedTermExtraM).squareRoot())
        }

        func speedTerm(_ route: Double, _ pair: PairInfo) -> Double {
            guard let d = pair.speedDist else { return 0 }
            return -0.5 * pow((route - d) / pair.speedSd, 2)
        }

        func step(_ si: State, _ ci: HMMFixInfo.Candidate, _ cj: HMMFixInfo.Candidate, _ pair: PairInfo) -> (logp: Double, eff: Double, tree: HMMRouteTree?)? {
            if ci.edge == cj.edge {
                if cj.off >= si.eff {
                    let route = cj.off - si.eff
                    return route <= pair.maxRoute ? (-abs(route - pair.gc) / HMMTuning.betaM + speedTerm(route, pair), cj.off, nil) : nil
                }
                let slip = si.eff - cj.off
                if slip <= pair.slipMax {
                    return (-pair.gc / HMMTuning.betaM - 0.5 * pow(slip / pair.slipSd, 2) + speedTerm(0, pair), si.eff, nil)
                }
            }
            let t = tree(from: ci.edge, bound: pair.maxRoute)
            guard let cost = t.cost[cj.edge], cost <= pair.maxRoute else { return nil }
            let route = g.edgeLen(ci.edge) - si.eff + (t.dist[cj.edge] ?? 0) + cj.off
            guard route <= pair.maxRoute else { return nil }
            let uturns = Double(t.uturns[cj.edge] ?? 0)
            var logp = -abs(route - pair.gc) / HMMTuning.betaM + uturns * HMMTuning.uturnLogP + speedTerm(route, pair)
            if let change = pair.headingChange {
                let excess = (t.turn[cj.edge] ?? 0) - change - HMMTuning.turnToleranceDeg
                if excess > 0 { logp -= excess / HMMTuning.turnScaleDeg }
            }
            return (logp, cj.off, t)
        }

        let lookback = HMMTuning.maxSkipLayers + 1
        var states: [[State]] = []
        var layerBest: [Double] = []
        var layerArg: [Int] = []
        for k in 0..<L {
            let cands = infos[layers[k]].cands
            var pairs: [PairInfo] = []
            var back = 1
            while back <= lookback && k - back >= 0 {
                pairs.append(pairInfo(k - back, k))
                back += 1
            }
            var restart = k < lookback ? Double(k) * HMMTuning.skipLogP : -Double.infinity
            var rl = -1, rc = -1
            back = 1
            while back <= lookback && k - back >= 0 {
                let p = k - back
                let s = layerBest[p] + Double(back - 1) * HMMTuning.skipLogP + HMMTuning.breakLogP
                if s > restart {
                    restart = s
                    rl = p
                    rc = layerArg[p]
                }
                back += 1
            }
            var row: [State] = []
            var bestScore = -Double.infinity
            var bestArg = 0
            for (j, cj) in cands.enumerated() {
                var best = restart
                var pl = rl, pc = rc
                var brk = true
                var eff = cj.off
                var bestTree: HMMRouteTree?
                var gap = false
                for b in 1...max(1, pairs.count) where b <= pairs.count {
                    let pair = pairs[b - 1]
                    guard pair.allowed else { continue }
                    let p = k - b
                    let prevCands = infos[layers[p]].cands
                    let prevStates = states[p]
                    let floor = layerBest[p] + HMMTuning.breakLogP
                    for (i, si) in prevStates.enumerated() where si.score >= floor {
                        guard let st = step(si, prevCands[i], cj, pair) else { continue }
                        let s = si.score + st.logp + Double(b - 1) * HMMTuning.skipLogP
                        if s > best {
                            best = s
                            pl = p
                            pc = i
                            brk = false
                            eff = st.eff
                            bestTree = st.tree
                            gap = pair.gap
                        }
                    }
                }
                let via: [Int]? = brk ? nil : bestTree?.via(cj.edge)
                let score = best + cj.logE
                row.append(State(score: score, eff: eff, pl: pl, pc: pc, brk: brk, via: via, gap: brk ? false : gap))
                if score > bestScore {
                    bestScore = score
                    bestArg = j
                }
            }
            states.append(row)
            layerBest.append(bestScore)
            layerArg.append(bestArg)
        }
        var endLayer = L - 1
        var endScore = -Double.infinity
        var back = 0
        while back < lookback && L - 1 - back >= 0 {
            let p = L - 1 - back
            let s = layerBest[p] + Double(back) * HMMTuning.skipLogP
            if s > endScore {
                endScore = s
                endLayer = p
            }
            back += 1
        }
        var out: [Decoded] = []
        var p = endLayer
        var c = layerArg[p]
        while p >= 0 {
            let st = states[p][c]
            let cand = infos[layers[p]].cands[c]
            out.append(Decoded(fi: layers[p], edge: cand.edge, eff: st.eff, off: cand.off, newRun: st.brk, via: st.via, gap: st.gap))
            p = st.pl
            c = st.pc
        }
        return out.reversed()
    }
}

/// Walks a decoded path and records the feature passes (containment rule) and driven pieces,
/// like the parent's `buildRunPasses`: a pass leaves its edge at the end, passes the route and
/// enters the next edge at its start; within one edge the offset never runs back.
nonisolated enum PathWalker {
    /// - Parameter countingGuard: count a node only when the fixes matched to the road around it
    ///   support it: the median of their distance to the road, each divided by its SPEC 14.4
    ///   candidate radius, is at most 1. "Around it" are the fixes of the pass (consecutive fixes of
    ///   one run on one edge) the car arrives on and of the pass it leaves on; for a node inside a
    ///   pass, that pass.
    static func result(decoded: [HMMMatcher.Decoded], infos: [HMMFixInfo], graph g: HMMGraph, fixCount: Int,
                       countingGuard: Bool = true) -> MatchResult {
        var r = MatchResult()
        /// Distance of a decoded fix to its road over the SPEC 14.4 radius (above 1: outside).
        func ratio(_ d: HMMMatcher.Decoded) -> Double {
            let info = infos[d.fi]
            guard let c = info.cands.first(where: { $0.edge == d.edge }) else { return .infinity }
            return c.dist / HMMTuning.CandidateRadius.spur.radius(accuracy: info.fix.accuracy ?? HMMTuning.defaultAccuracyM)
        }
        // Pass number of every decoded fix: a new pass starts with a run, an edge change or a route.
        var passOf: [Int] = []
        var passRatios: [[Double]] = []
        for (k, d) in decoded.enumerated() {
            let continues = k > 0 && !d.newRun && d.via == nil && d.edge == decoded[k - 1].edge
            if !continues { passRatios.append([]) }
            passOf.append(passRatios.count - 1)
            passRatios[passRatios.count - 1].append(ratio(d))
        }
        func supported(_ passes: [Int]) -> Bool {
            let values = passes.flatMap { passRatios[$0] }
            guard let m = Quantile.median(values) else { return false }
            return m <= 1
        }
        var counting = true
        r.positions = [MatchPosition?](repeating: nil, count: fixCount)
        var lastNode: Int64?
        var curEdge = -1
        var curExit = 0.0
        var prevTime = 0.0
        let net = g.net
        /// True while emitting the pieces of a step across a GPS gap (SPEC 15.1: route guessed,
        /// not observed).
        var bridging = false

        func emit(_ edge: Int, from lo: Double, to hi: Double, startM: Double, at: (Double) -> Double, fixIndex: Int) {
            let k = g.edgeSeg[edge]
            let d = g.direction(edge)
            let s = net.segments[k]
            let n = s.nodeIds.count
            for j in 0..<n {
                let i = d == .forward ? j : n - 1 - j
                let off = d == .forward ? s.cum[i] : s.length - s.cum[i]
                guard off > lo, off <= hi else { continue }
                let id = s.nodeIds[i]
                if id == lastNode { continue }
                lastNode = id
                if counting, net.features[id] != nil {
                    r.passes.append(FeaturePass(nodeId: id, time: at(startM + off - lo), segment: k, direction: d, fixIndex: fixIndex))
                }
            }
            if hi > lo {
                r.pieces.append(DrivenPiece(segment: k, direction: d, from: lo, to: hi, startTime: at(startM), endTime: at(startM + hi - lo),
                                            bridged: bridging))
            }
        }

        for (k, d) in decoded.enumerated() {
            let info = infos[d.fi]
            let t = info.fix.time
            r.positions[info.index] = MatchPosition(segment: g.edgeSeg[d.edge], direction: g.direction(d.edge), offset: d.eff)
            let pass = passOf[k]
            let previous = k > 0 ? passOf[k - 1] : pass
            counting = !countingGuard || supported(previous == pass ? [pass] : [previous, pass])
            if d.newRun || curEdge < 0 {
                r.runs += 1
                curEdge = d.edge
                curExit = d.eff
                prevTime = t
                lastNode = nil
                continue
            }
            if d.via == nil && d.edge == curEdge {
                let to = max(curExit, d.eff)
                let t0 = prevTime
                emit(curEdge, from: curExit, to: to, startM: 0, at: { m in to > curExit ? t0 + (t - t0) * min(1, m / (to - curExit)) : t }, fixIndex: info.index)
                curExit = to
                prevTime = t
                continue
            }
            let via = d.via ?? []
            // Across a real GPS gap the route in between is the matcher's guess: its pieces still
            // count for distance and features (parent parity), never for driven directions.
            bridging = d.gap
            defer { bridging = false }
            let lenCur = g.edgeLen(curEdge)
            var total = max(0, lenCur - curExit) + d.eff
            for e in via { total += g.edgeLen(e) }
            let t0 = prevTime
            let at: (Double) -> Double = { m in total > 0 ? t0 + (t - t0) * min(m, total) / total : t0 }
            var acc = 0.0
            emit(curEdge, from: curExit, to: lenCur, startM: acc, at: at, fixIndex: info.index)
            acc += max(0, lenCur - curExit)
            for e in via {
                emit(e, from: 0, to: g.edgeLen(e), startM: acc, at: at, fixIndex: info.index)
                acc += g.edgeLen(e)
            }
            emit(d.edge, from: 0, to: d.eff, startM: acc, at: at, fixIndex: info.index)
            curEdge = d.edge
            curExit = d.eff
            prevTime = t
        }
        return r
    }
}
