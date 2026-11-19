import Foundation

/// Every threshold of the road analysis (SPEC 14.3 to 14.5), in one place.
nonisolated enum RoadConstants {
    // Parent `src/shared/constants.ts` and DECISIONS 9 of the parent.
    /// A junction approach pair below this angle is skewed.
    static let skewMinDeg = 70.0
    /// ... or above this and below `straightThroughMinDeg`.
    static let skewMaxDeg = 110.0
    /// Pairs at or above this angle are the straight continuation of one road.
    static let straightThroughMinDeg = 150.0
    /// The approach bearing points to the first arm node at least this far away (meters).
    static let approachMinM = 15.0
    /// A stop within this distance (meters) of a signal or stop node of the matched path is classified so.
    static let stopFeatureRadiusM = 30.0
    /// Parent `DEFAULT_SIGNALS_PER_KM`: "viele Ampeln" (and "viele Stoppschilder") above this many per km.
    static let manyPerKm = 3.0
    /// A street needs at least this much driven distance (meters) to be judged "viele ...".
    static let streetMinDrivenM = 300.0
    /// Signal nodes within this distance (meters), connected through kept ways, are one signal site.
    static let signalSiteRadiusM = 30.0
    /// Speeding: more than this above the posted limit (5 mph, in m/s).
    static let speedingToleranceMps = 5 * 0.44704
    /// A signal site passed again within this many seconds is the same crossing (its other nodes).
    static let sameSiteSeconds = 60.0

    // Light matcher (SPEC 14.4).
    /// Candidate radius: clamp(2 x horizontal accuracy, 12, 30) meters.
    static let candidateMinM = 12.0
    static let candidateMaxM = 30.0
    /// Above this speed (m/s) with a valid course, candidates whose bearing differs from the
    /// course by more than `headingMaxDiffDeg` are rejected.
    static let headingMinSpeed = 3.0
    static let headingMaxDiffDeg = 40.0
    /// Fixes less accurate than this, or slower than `stationarySpeed`, keep the current match.
    static let matchMaxAccuracyM = 30.0
    static let stationarySpeed = 1.0
    /// Consecutive fixes that must prefer an unconnected way before the match switches to it.
    static let switchFixes = 3
    /// Score penalty (meters) for leaving the current way for one that shares no node with it.
    static let unconnectedPenaltyM = 20.0
}

nonisolated enum TravelDirection: String, Codable, Sendable, Hashable {
    case forward, backward

    var reversed: TravelDirection { self == .forward ? .backward : .forward }
}

/// Road categories of the parent (`src/lib/osm/categories.ts`, parent SPEC 5.3).
nonisolated enum RoadCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case interstate, freeway, tollway, highway, expressway, ramp, frontage, arterial, local
}

/// A way cut at every node it shares with another kept way (parent `Segment`).
nonisolated struct RoadSegment: Sendable, Equatable {
    /// `wayId:fromNode:toNode`.
    var id: String
    var wayId: Int64
    var fromNode: Int64
    var toNode: Int64
    var nodeIds: [Int64]
    var coords: [LatLon]
    /// Cumulative haversine length at every node, from the from node.
    var cum: [Double]
    var length: Double
    /// The parent's kept tags of the way.
    var tags: [String: String]
    var categories: [RoadCategory]
    var directions: [TravelDirection]
    /// The way's limit also depends on direction, time, lane or a variable sign (`maxspeed:forward`
    /// and the like): the plain `maxspeed` is not the whole story (SPEC 16.2).
    var qualifiedMaxspeed = false

    func entryNode(_ d: TravelDirection) -> Int64 { d == .forward ? fromNode : toNode }
    func exitNode(_ d: TravelDirection) -> Int64 { d == .forward ? toNode : fromNode }
    func allows(_ d: TravelDirection) -> Bool { directions.contains(d) }

    /// The street name of the way: `name`, else `ref`, else the way id (SPEC 14.3).
    var streetName: String { tags["name"] ?? tags["ref"] ?? "Weg \(wayId)" }
}

/// The parent's tag rules (`src/lib/osm/tags.ts`, `segment.ts`, `categories.ts`, `maxspeed.ts`). Pure.
nonisolated enum RoadRules {
    static let linkedClasses = ["motorway", "trunk", "primary", "secondary", "tertiary"]
    static let plainClasses = ["unclassified", "residential", "living_street"]
    static let roadClasses: Set<String> = Set(linkedClasses + plainClasses + linkedClasses.map { "\($0)_link" })
    static let excludedService: Set<String> = ["parking_aisle", "driveway", "drive-through"]
    static let nodeHighwayValues: Set<String> = ["traffic_signals", "stop", "give_way", "crossing", "mini_roundabout", "motorway_junction"]
    static let keptTags = [
        "highway", "ref", "name", "oneway", "toll", "maxspeed", "lanes", "junction", "layer",
        "bridge", "tunnel", "hov", "access", "frontage_road", "lane_markings", "lit", "surface",
    ]

    /// Parent `isKeptRoad`.
    static func isKeptRoad(_ tags: [String: String]?) -> Bool {
        guard let highway = tags?["highway"] else { return false }
        if roadClasses.contains(highway) { return true }
        guard highway == "service" else { return false }
        guard let service = tags?["service"] else { return true }
        return !excludedService.contains(service)
    }

    /// Parent `directionsFor`: `oneway=-1` wins over the forward-only rule of a roundabout;
    /// every other value, `reversible` included, means both directions.
    static func directions(_ tags: [String: String]) -> [TravelDirection] {
        let oneway = tags["oneway"]
        if oneway == "-1" { return [.backward] }
        if oneway == "yes" || oneway == "true" || oneway == "1" || tags["junction"] == "roundabout" { return [.forward] }
        return [.forward, .backward]
    }

    static func keptTags(_ tags: [String: String]?) -> [String: String] {
        guard let tags else { return [:] }
        var out: [String: String] = [:]
        for k in keptTags { if let v = tags[k] { out[k] = v } }
        return out
    }

    private static let interstateRef = try! NSRegularExpression(pattern: "^I[ -]?\\d")
    private static let highwayRef = try! NSRegularExpression(pattern: "US|TX|SH|FM|Loop|Spur|State Highway")
    private static let frontageName = try! NSRegularExpression(pattern: "Frontage|Service R(oa)?d")

    private static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Parent `categoriesFor`, in the parent's order.
    static func categories(_ tags: [String: String]) -> [RoadCategory] {
        guard isKeptRoad(tags) else { return [] }
        let highway = tags["highway"] ?? ""
        let ref = tags["ref"] ?? ""
        let name = tags["name"] ?? ""
        let interstate = highway == "motorway" && test(interstateRef, ref)
        let freeway = highway == "motorway"
        let tollway = tags["toll"] == "yes"
        let highwayRoute = (highway == "trunk" || highway == "primary") && test(highwayRef, ref)
        let expressway = highway == "trunk"
        let ramp = highway.hasSuffix("_link")
        let frontage = tags["frontage_road"] == "yes" || test(frontageName, name)
        let coveredAbove = interstate || freeway || tollway || highwayRoute || expressway || ramp || frontage
        let arterial = ["primary", "secondary", "tertiary"].contains(highway) && !coveredAbove
        let local = ["residential", "unclassified", "living_street", "service"].contains(highway)
        var out: [RoadCategory] = []
        if interstate { out.append(.interstate) }
        if freeway { out.append(.freeway) }
        if tollway { out.append(.tollway) }
        if highwayRoute { out.append(.highway) }
        if expressway { out.append(.expressway) }
        if ramp { out.append(.ramp) }
        if frontage { out.append(.frontage) }
        if arterial { out.append(.arterial) }
        if local { out.append(.local) }
        return out
    }

    private static let maxspeedValue = try! NSRegularExpression(pattern: "^(\\d+(?:\\.\\d+)?)\\s*(mph|km/h|kmh|kph|knots)?$")

    /// Parent `parseMaxspeedMph`: "65 mph" is 65, a bare number is km/h, a list gives its lowest
    /// limit, anything unreadable gives nil.
    static func maxspeedMph(_ tag: String?) -> Double? {
        guard let tag else { return nil }
        var lowest: Double?
        for part in tag.split(separator: ";", omittingEmptySubsequences: false) {
            let raw = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let m = maxspeedValue.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let numRange = Range(m.range(at: 1), in: raw), let n = Double(raw[numRange]), n.isFinite, n > 0 else { return nil }
            let unit = Range(m.range(at: 2), in: raw).map { String(raw[$0]) }
            let mph: Double
            switch unit {
            case "mph": mph = n
            case "knots": mph = n * 1852 / 1609.344
            default: mph = n * 1000 / 1609.344
            }
            if lowest == nil || mph < lowest! { lowest = mph }
        }
        return lowest
    }
}

/// The road graph of a set of OSM elements: segments (parent `segmentWays`), node positions and
/// tags, the feature nodes (parent `extractFeatures`) and a spatial index. Pure and immutable.
nonisolated struct RoadNetwork: Sendable {
    let segments: [RoadSegment]
    /// Position of every node any element gave a position for (first one wins).
    let positions: [Int64: LatLon]
    /// Node tags; a tagged copy of a node wins over an untagged one.
    let nodeTags: [Int64: [String: String]]
    let features: [Int64: FeatureNode]
    /// Segment ends at each node: (segment index, the node is its from node).
    let ends: [Int64: [(segment: Int, atStart: Bool)]]
    /// Segment indexes per way, in OSM order.
    let byWay: [Int64: [Int]]
    private let grid: [GridKey: [Int]]
    private static let cellDeg = 0.002

    private struct GridKey: Hashable { var x: Int32; var y: Int32 }

    init(_ e: OSMElements) {
        var positions: [Int64: LatLon] = [:]
        // Parent `extractFeatures`: the first copy of a node, unless a later copy has tags and it has none.
        var chosen: [Int64: OSMNode] = [:]
        for n in e.nodes {
            if n.lat.isFinite && n.lon.isFinite && positions[n.id] == nil { positions[n.id] = LatLon(lat: n.lat, lon: n.lon) }
            if let known = chosen[n.id] {
                if known.tags == nil && n.tags != nil { chosen[n.id] = n }
            } else {
                chosen[n.id] = n
            }
        }
        let nodeTags = chosen.compactMapValues(\.tags)
        var ways: [Int64: OSMWay] = [:]
        for w in e.ways where ways[w.id] == nil && w.nodes.count >= 2 && RoadRules.isKeptRoad(w.tags) {
            ways[w.id] = w
        }
        var uses: [Int64: Int] = [:]
        for w in ways.values {
            let closed = w.nodes.count > 2 && w.nodes.first == w.nodes.last
            let end = closed ? w.nodes.count - 1 : w.nodes.count
            for i in 0..<end { uses[w.nodes[i], default: 0] += 1 }
        }
        var segments: [RoadSegment] = []
        var byWay: [Int64: [Int]] = [:]
        for wayId in ways.keys.sorted() {
            let way = ways[wayId]!
            let nodes = way.nodes
            let tags = RoadRules.keptTags(way.tags)
            let categories = RoadRules.categories(way.tags ?? [:])
            let directions = RoadRules.directions(way.tags ?? [:])
            var seen: Set<String> = []
            var start = 0
            for i in 1..<nodes.count {
                if i != nodes.count - 1 && (uses[nodes[i]] ?? 0) < 2 { continue }
                let ids = Array(nodes[start...i])
                start = i
                var coords: [LatLon] = []
                coords.reserveCapacity(ids.count)
                var complete = true
                for id in ids {
                    guard let p = positions[id] else { complete = false; break }
                    coords.append(p)
                }
                guard complete else { continue }
                let id = "\(wayId):\(ids.first!):\(ids.last!)"
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                var cum: [Double] = [0]
                for k in 1..<coords.count { cum.append(cum[k - 1] + OSMGeo.haversine(coords[k - 1], coords[k])) }
                byWay[wayId, default: []].append(segments.count)
                segments.append(RoadSegment(id: id, wayId: wayId, fromNode: ids.first!, toNode: ids.last!, nodeIds: ids,
                                            coords: coords, cum: cum, length: OSMGeo.lineLength(coords), tags: tags,
                                            categories: categories, directions: directions,
                                            qualifiedMaxspeed: way.tags?.keys.contains { $0.hasPrefix("maxspeed:") } ?? false))
            }
        }
        var ends: [Int64: [(segment: Int, atStart: Bool)]] = [:]
        for (k, s) in segments.enumerated() {
            ends[s.fromNode, default: []].append((k, true))
            ends[s.toNode, default: []].append((k, false))
        }
        var grid: [GridKey: [Int]] = [:]
        for (k, s) in segments.enumerated() {
            var cells: Set<GridKey> = []
            for p in s.coords { cells.insert(RoadNetwork.cell(p)) }
            // Long legs: also the cells in between.
            for i in 1..<s.coords.count {
                let a = s.coords[i - 1], b = s.coords[i]
                let steps = Int(max(abs(b.lat - a.lat), abs(b.lon - a.lon)) / (RoadNetwork.cellDeg / 2))
                if steps > 0 {
                    for j in 1...steps {
                        let f = Double(j) / Double(steps + 1)
                        cells.insert(RoadNetwork.cell(LatLon(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)))
                    }
                }
            }
            for c in cells { grid[c, default: []].append(k) }
        }
        self.segments = segments
        self.positions = positions
        self.nodeTags = nodeTags
        self.ends = ends
        self.byWay = byWay
        self.grid = grid
        self.features = RoadFeatures.extract(segments: segments, nodes: chosen, ends: ends)
    }

    private static func cell(_ p: LatLon) -> GridKey {
        GridKey(x: Int32(floor(p.lon / cellDeg)), y: Int32(floor(p.lat / cellDeg)))
    }

    /// Segments with any part possibly within `radius` meters of the point.
    func segmentsNear(_ p: LatLon, radius: Double) -> [Int] {
        let dLat = radius / OSMGeo.R * 180 / .pi
        let dLon = dLat / max(0.01, cos(p.lat * .pi / 180))
        let a = RoadNetwork.cell(LatLon(lat: p.lat - dLat, lon: p.lon - dLon))
        let b = RoadNetwork.cell(LatLon(lat: p.lat + dLat, lon: p.lon + dLon))
        var out: Set<Int> = []
        for x in a.x...b.x {
            for y in a.y...b.y {
                if let list = grid[GridKey(x: x, y: y)] { out.formUnion(list) }
            }
        }
        return out.sorted()
    }

    /// Ways that use a node (through their segments' node lists).
    func waysAt(_ node: Int64) -> Set<Int64> {
        Set((ends[node] ?? []).map { segments[$0.segment].wayId })
    }
}
