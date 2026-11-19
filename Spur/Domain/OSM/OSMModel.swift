import Foundation

/// OpenStreetMap elements as Overpass prints them (SPEC 14.2). Road data © OpenStreetMap
/// contributors, ODbL. Pure value types, no I/O.
nonisolated struct OSMNode: Sendable, Equatable, Codable {
    var id: Int64
    var lat: Double
    var lon: Double
    var tags: [String: String]?
}

nonisolated struct OSMWay: Sendable, Equatable, Codable {
    var id: Int64
    var nodes: [Int64]
    var tags: [String: String]?
}

/// The elements of one or more Overpass answers, in answer order. Duplicates are allowed (tiles
/// overlap); the segmenter and the feature extractor resolve them exactly like the parent.
nonisolated struct OSMElements: Sendable, Equatable, Codable {
    var nodes: [OSMNode] = []
    var ways: [OSMWay] = []

    var isEmpty: Bool { nodes.isEmpty && ways.isEmpty }

    mutating func append(_ other: OSMElements) {
        nodes.append(contentsOf: other.nodes)
        ways.append(contentsOf: other.ways)
    }

    static func merged(_ parts: [OSMElements]) -> OSMElements {
        var out = OSMElements()
        out.nodes.reserveCapacity(parts.reduce(0) { $0 + $1.nodes.count })
        out.ways.reserveCapacity(parts.reduce(0) { $0 + $1.ways.count })
        for p in parts { out.append(p) }
        return out
    }
}

/// The tag vocabulary Spur reads. Everything else is dropped when a tile is parsed, which keeps
/// the cache small and keeps unrelated names (shops, brands) out of the app.
nonisolated enum OSMTags {
    /// Way tags: the parent's `KEPT_TAGS` plus `service`, which decides whether a service road is kept.
    static let wayKeys: Set<String> = [
        "highway", "ref", "name", "oneway", "toll", "maxspeed", "lanes", "junction", "layer",
        "bridge", "tunnel", "hov", "access", "frontage_road", "lane_markings", "lit", "surface", "service",
        // A limit that depends on direction, time, lane or a sign: the speed limit sign stays off (SPEC 16.2).
        "maxspeed:forward", "maxspeed:backward", "maxspeed:conditional", "maxspeed:lanes", "maxspeed:variable",
    ]
    /// Node tags of the feature nodes (SPEC 14.3).
    static let nodeKeys: Set<String> = [
        "highway", "railway", "direction", "stop", "stop:direction", "traffic_signals:direction",
        "traffic_signals", "crossing",
    ]

    static func filter(_ tags: [String: String]?, keys: Set<String>) -> [String: String]? {
        guard let tags else { return nil }
        let kept = tags.filter { keys.contains($0.key) }
        return kept.isEmpty ? nil : kept
    }
}

nonisolated enum OverpassParseError: Error, Equatable {
    case notJSON
    case noElements
    /// The server ran out of time or memory; the element list is incomplete (parent `FAILED_REMARK`).
    case runtimeError(String)
}

/// Parses Overpass JSON (`{"elements": [...]}`), the shape of live answers, of the bundled pack
/// and of the parent's fixtures. One parser for all three.
nonisolated enum OverpassParser {
    static let failedRemark = try! NSRegularExpression(pattern: "runtime error|out of memory|too busy|timed out|timeout", options: [.caseInsensitive])

    /// - Parameter keepAllTags: false (the default) keeps only `OSMTags`; true keeps every tag.
    static func parse(_ data: Data, keepAllTags: Bool = false) throws -> OSMElements {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OverpassParseError.notJSON }
        if let remark = root["remark"] as? String,
           failedRemark.firstMatch(in: remark, range: NSRange(remark.startIndex..., in: remark)) != nil {
            throw OverpassParseError.runtimeError(remark)
        }
        guard let elements = root["elements"] as? [Any] else { throw OverpassParseError.noElements }
        return parse(elements: elements, keepAllTags: keepAllTags)
    }

    static func parse(elements: [Any], keepAllTags: Bool = false) -> OSMElements {
        var out = OSMElements()
        for raw in elements {
            guard let el = raw as? [String: Any], let type = el["type"] as? String, let id = int64(el["id"]) else { continue }
            let tags = el["tags"] as? [String: String]
            switch type {
            case "node":
                guard let lat = el["lat"] as? Double ?? (el["lat"] as? NSNumber)?.doubleValue,
                      let lon = el["lon"] as? Double ?? (el["lon"] as? NSNumber)?.doubleValue,
                      lat.isFinite, lon.isFinite else { continue }
                out.nodes.append(OSMNode(id: id, lat: lat, lon: lon,
                                         tags: keepAllTags ? tags : OSMTags.filter(tags, keys: OSMTags.nodeKeys)))
            case "way":
                let nodes = (el["nodes"] as? [Any] ?? []).compactMap(int64)
                out.ways.append(OSMWay(id: id, nodes: nodes,
                                       tags: keepAllTags ? tags : OSMTags.filter(tags, keys: OSMTags.wayKeys)))
            default:
                continue // relations (place boundaries) are not used by Spur
            }
        }
        return out
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int { return Int64(i) }
        return nil
    }

    /// Overpass JSON for elements (used by the pack builder and tests).
    static func encode(_ e: OSMElements) throws -> Data {
        var list: [[String: Any]] = []
        list.reserveCapacity(e.nodes.count + e.ways.count)
        for n in e.nodes {
            var d: [String: Any] = ["type": "node", "id": n.id, "lat": n.lat, "lon": n.lon]
            if let t = n.tags { d["tags"] = t }
            list.append(d)
        }
        for w in e.ways {
            var d: [String: Any] = ["type": "way", "id": w.id, "nodes": w.nodes]
            if let t = w.tags { d["tags"] = t }
            list.append(d)
        }
        return try JSONSerialization.data(withJSONObject: ["elements": list], options: [.sortedKeys])
    }
}
