import Foundation

/// Point feature types of the parent (`FeatureType`).
nonisolated enum FeatureType: String, Codable, Sendable, CaseIterable, Hashable {
    case trafficSignals = "traffic_signals"
    case stop
    case giveWay = "give_way"
    case crossing
    case miniRoundabout = "mini_roundabout"
    case motorwayJunction = "motorway_junction"
    case levelCrossing = "level_crossing"
    case roundabout
    case junction
}

/// A tagged OSM node on the network, or a plain junction node of three or more segment ends
/// (parent `FeatureNode`).
nonisolated struct FeatureNode: Codable, Sendable, Equatable, Hashable {
    var nodeId: Int64
    var lat: Double
    var lon: Double
    var type: FeatureType
    /// Pairwise angles (0 to 180) between the approach bearings, for junctions.
    var approachAngles: [Double]?
    var skewed: Bool?

    var position: LatLon { LatLon(lat: lat, lon: lon) }
}

/// Feature extraction, ported exactly from the parent's `src/lib/osm/features.ts`, plus the
/// signal sites and the stop-sign direction rules of SPEC 14.3. Pure.
nonisolated enum RoadFeatures {
    /// Parent `taggedFeatureType`: a `highway` value wins over `railway`.
    static func taggedType(_ tags: [String: String]?) -> FeatureType? {
        if let highway = tags?["highway"], RoadRules.nodeHighwayValues.contains(highway) {
            return FeatureType(rawValue: highway)
        }
        return tags?["railway"] == "level_crossing" ? .levelCrossing : nil
    }

    /// Parent DECISIONS 9: at least three approaches; skewed when any pair meets below 70 degrees,
    /// or above 110 and below 150 degrees.
    static func isSkewed(_ angles: [Double]) -> Bool {
        guard angles.count >= 3 else { return false }
        return angles.contains {
            $0 < RoadConstants.skewMinDeg || ($0 > RoadConstants.skewMaxDeg && $0 < RoadConstants.straightThroughMinDeg)
        }
    }

    /// Bearing away from the node along one arm (parent `approachBearing`).
    static func approachBearing(_ coords: [LatLon], atStart: Bool) -> Double? {
        let n = coords.count
        guard n > 0 else { return nil }
        let origin = atStart ? coords[0] : coords[n - 1]
        var farthest: LatLon?
        var farthestM = 0.0
        if n > 1 {
            for k in 1..<n {
                let p = atStart ? coords[k] : coords[n - 1 - k]
                let d = OSMGeo.haversine(origin, p)
                if d >= RoadConstants.approachMinM { return OSMGeo.bearing(origin, p) }
                if d > farthestM {
                    farthestM = d
                    farthest = p
                }
            }
        }
        return farthest.map { OSMGeo.bearing(origin, $0) }
    }

    /// Pairwise angles between the arms' approach bearings (parent `anglesOf`).
    static func angles(_ arms: [(coords: [LatLon], atStart: Bool)]) -> [Double] {
        let bearings = arms.compactMap { approachBearing($0.coords, atStart: $0.atStart) }
        var out: [Double] = []
        for i in 0..<bearings.count {
            for j in (i + 1)..<bearings.count { out.append(OSMGeo.angleDiff(bearings[i], bearings[j])) }
        }
        return out
    }

    /// Parent `extractFeatures`: tagged nodes on a segment and junctions of three or more segment
    /// ends; a junction keeps its tag's type, is `roundabout` on a roundabout way, else `junction`.
    static func extract(segments: [RoadSegment], nodes: [Int64: OSMNode],
                        ends: [Int64: [(segment: Int, atStart: Bool)]]) -> [Int64: FeatureNode] {
        var onNetwork: [Int64: LatLon] = [:]
        var onRoundabout: Set<Int64> = []
        for s in segments {
            for (i, id) in s.nodeIds.enumerated() where onNetwork[id] == nil { onNetwork[id] = s.coords[i] }
            if s.tags["junction"] == "roundabout" {
                onRoundabout.insert(s.fromNode)
                onRoundabout.insert(s.toNode)
            }
        }
        var out: [Int64: FeatureNode] = [:]
        for id in onNetwork.keys.sorted() {
            let node = nodes[id]
            let tagged = taggedType(node?.tags)
            let nodeEnds = ends[id] ?? []
            let isJunction = nodeEnds.count >= 3
            guard tagged != nil || isJunction else { continue }
            let fallback = onNetwork[id]!
            var f = FeatureNode(nodeId: id, lat: node?.lat ?? fallback.lat, lon: node?.lon ?? fallback.lon,
                                type: tagged ?? (onRoundabout.contains(id) ? .roundabout : .junction))
            if isJunction {
                let a = angles(nodeEnds.map { (segments[$0.segment].coords, $0.atStart) })
                f.approachAngles = a
                f.skewed = isSkewed(a)
            }
            out[id] = f
        }
        return out
    }

    // MARK: Signal sites (SPEC 14.3)

    /// Signal nodes of one intersection (divided roads carry two to four) merged into one site:
    /// signal nodes within 30 m of each other, connected through kept ways within that distance
    /// (shortest path along the network, either direction). Returns the site id of every signal
    /// node: the smallest node id of its site.
    static func signalSites(_ net: RoadNetwork) -> [Int64: Int64] {
        let signals = net.features.values.filter { $0.type == .trafficSignals }.map(\.nodeId).sorted()
        var parent: [Int64: Int64] = [:]
        for s in signals { parent[s] = s }
        func find(_ x: Int64) -> Int64 {
            var r = x
            while parent[r]! != r { r = parent[r]! }
            return r
        }
        let signalSet = Set(signals)
        let neighbours = nodeGraph(net)
        for s in signals {
            for (other, _) in withinNetworkDistance(from: s, limit: RoadConstants.signalSiteRadiusM, graph: neighbours)
            where other != s && signalSet.contains(other) {
                let a = find(s), b = find(other)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var out: [Int64: Int64] = [:]
        for s in signals { out[s] = find(s) }
        return out
    }

    /// Undirected node graph along the segments: consecutive nodes with their distance.
    static func nodeGraph(_ net: RoadNetwork) -> [Int64: [(Int64, Double)]] {
        var g: [Int64: [(Int64, Double)]] = [:]
        for s in net.segments {
            for i in 1..<s.nodeIds.count {
                let d = s.cum[i] - s.cum[i - 1]
                g[s.nodeIds[i - 1], default: []].append((s.nodeIds[i], d))
                g[s.nodeIds[i], default: []].append((s.nodeIds[i - 1], d))
            }
        }
        return g
    }

    /// Nodes reachable within `limit` meters along the graph, with their distance.
    static func withinNetworkDistance(from start: Int64, limit: Double, graph: [Int64: [(Int64, Double)]]) -> [(Int64, Double)] {
        var dist: [Int64: Double] = [start: 0]
        var frontier: [(Int64, Double)] = [(start, 0)]
        while let (node, d) = frontier.min(by: { $0.1 < $1.1 }) {
            frontier.removeAll { $0.0 == node }
            guard d <= dist[node] ?? .infinity else { continue }
            for (next, w) in graph[node] ?? [] {
                let nd = d + w
                if nd <= limit && nd < (dist[next] ?? .infinity) {
                    dist[next] = nd
                    frontier.append((next, nd))
                }
            }
        }
        return dist.map { ($0.key, $0.value) }
    }

    // MARK: Direction of signs (SPEC 14.3)

    /// Whether a stop sign or signal at a node applies to a car traveling along a way in `travel`
    /// direction (relative to the way's node order). `direction=forward|backward` (for a stop also
    /// `stop:direction`, for a signal `traffic_signals:direction`) limits it to that direction;
    /// untagged, `both`, `all` or any other value means it applies.
    static func applies(tags: [String: String]?, type: FeatureType, travel: TravelDirection) -> Bool {
        let keys: [String]
        switch type {
        case .stop: keys = ["stop:direction", "direction"]
        case .trafficSignals: keys = ["traffic_signals:direction", "direction"]
        default: keys = ["direction"]
        }
        for key in keys {
            switch tags?[key] {
            case "forward": return travel == .forward
            case "backward": return travel == .backward
            default: continue
            }
        }
        return true
    }

    /// `applies` on the network: additionally, a `stop=minor` sign without a direction tag stands
    /// only for the minor road(s) of its junction, so it does not apply to a car arriving on the
    /// highest-ranked road there (unless every road there has the same rank: then it applies).
    /// `segment` is the segment on which the car arrives at the node.
    static func applies(net: RoadNetwork, node: Int64, type: FeatureType, segment: Int, travel: TravelDirection) -> Bool {
        let tags = net.nodeTags[node]
        guard applies(tags: tags, type: type, travel: travel) else { return false }
        guard type == .stop, tags?["stop"] == "minor", tags?["stop:direction"] == nil, tags?["direction"] == nil else { return true }
        let arriving = highwayRank(net.segments[segment].tags["highway"])
        let ranks = (net.ends[node] ?? []).map { highwayRank(net.segments[$0.segment].tags["highway"]) }
        guard let top = ranks.max(), let bottom = ranks.min(), top > bottom else { return true }
        return arriving < top
    }

    /// Rank of a road class, higher is more major; a `_link` ranks like its road.
    static func highwayRank(_ highway: String?) -> Int {
        guard var h = highway else { return 0 }
        if h.hasSuffix("_link") { h.removeLast(5) }
        switch h {
        case "motorway": return 9
        case "trunk": return 8
        case "primary": return 7
        case "secondary": return 6
        case "tertiary": return 5
        case "unclassified": return 4
        case "residential": return 3
        case "living_street": return 2
        case "service": return 1
        default: return 0
        }
    }

    /// `stop=all` marks an all-way stop.
    static func isAllWayStop(_ tags: [String: String]?) -> Bool { tags?["stop"] == "all" }
}
