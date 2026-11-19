import Foundation

/// Live counters for the HUD ("7 Ampeln · 2 Stopp · 1 schräg").
nonisolated struct LiveRoadCounts: Equatable, Sendable {
    var signalSites = 0
    var stopSigns = 0
    var allWayStops = 0
    var skewedJunctions = 0
    /// True once road data covers the car's position.
    var hasRoadData = false
    /// OSM category of the road the car is matched to right now, nil when not matched.
    var category: RoadCategory?
    /// The tagged limit of the matched way, only when `SpeedLimitSelector` allows it (SPEC 16.2).
    var speedLimit: SpeedLimit?
    /// Over that limit (`OverLimitDetector`), and by how much in the sign's unit.
    var overLimit = false
    var overLimitBy: Int?
    /// Why no sign is shown now (SPEC 17.9), nil while one is.
    var limitHidden: SpeedLimitSelector.Hidden? = .unstable
    /// Moving time so far per sign state: "shown" or a `Hidden` raw value (SPEC 17.9).
    var limitSeconds: [String: Double] = [:]
}

/// One symbol of the live map's POI layer (SPEC 14.6).
nonisolated struct RoadPOI: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case signal
        case stop(allWay: Bool)
        case skewed
    }

    /// Node id, or the site id for a signal site.
    var id: Int64
    var kind: Kind
    var lat: Double
    var lon: Double
    /// On the car's road ahead (drawn a little stronger than the rest).
    var ahead = false
    /// The OSM nodes the symbol stands for (a signal site has several).
    var nodes: [Int64] = []
}

/// What the live map draws from road data.
nonisolated struct RoadMapLayer: Equatable, Sendable {
    var pois: [RoadPOI] = []
    /// Streets in view with more than 3 signal sites per km (at least 300 m of them in view).
    var manySignalStreets: [[LatLon]] = []
    /// The tiles the layer was built from.
    var tiles: [TileKey] = []
}

/// Road data while the app runs: the network of the tiles around the car (or the map), the light
/// matcher fed fix by fix for the HUD counters, and the POI layer. Off the main actor; it only
/// reads local tiles (cache and pack), never the network, so recording never waits on it.
actor LiveRoads {
    /// The layer shows road features only near the car (or the map center without a trip):
    /// within this radius, at most `maxPOIs`, nearest first (design review: calm, near the car).
    static let poiRadius = 600.0
    static let maxPOIs = 25
    /// Streets with many signals: lines within this radius, at most `maxLines`.
    static let lineRadius = 600.0
    static let maxLines = 20
    /// How far along the car's road a feature counts as "ahead".
    static let aheadMeters = 800.0

    private let local: LocalTiles
    private var netTiles: Set<TileKey> = []
    private var net: RoadNetwork?
    private var sites: [Int64: Int64] = [:]
    private var matcher: LightMatcher?
    /// Built once per network: every symbol the layer could show, and the streets with many signals.
    private var candidates: [RoadPOI] = []
    private var manyStreets: [[LatLon]] = []
    private var consumed = 0
    private var counts = LiveRoadCounts()
    private var lastSite: Int64?
    private var lastSiteTime = -Double.infinity
    private var limits = SpeedLimitSelector()
    private var over = OverLimitDetector()
    /// While a trip records, the map layer reuses the car's network instead of building its own.
    private var tripActive = false

    init(local: LocalTiles) {
        self.local = local
    }

    /// A new trip: counters back to zero.
    func reset() {
        tripActive = true
        counts = LiveRoadCounts()
        lastAccounted = nil
        matcher = net.map { LightMatcher(network: $0) }
        consumed = 0
        lastSite = nil
        lastSiteTime = -.infinity
        clearLimit()
    }

    /// No sign and no red state until the selector allows one again.
    /// Moving time between consecutive fixes (at most 5 s apart, at 2 m/s or more), credited to
    /// the sign's state at the later fix.
    private var lastAccounted: Double?

    private func account(_ f: Fix, state: String) {
        defer { lastAccounted = f.time }
        guard let last = lastAccounted, f.time > last, f.time - last <= 5, (f.speed ?? 0) >= SpeedLimitSelector.minSpeed else { return }
        counts.limitSeconds[state, default: 0] += f.time - last
    }

    private func clearLimit() {
        limits.reset()
        over = OverLimitDetector()
        counts.speedLimit = nil
        counts.overLimit = false
        counts.overLimitBy = nil
    }

    /// The trip ended.
    func endTrip() {
        tripActive = false
    }

    private func available(_ keys: [TileKey]) -> Set<TileKey> {
        Set(keys.filter { local.cache.contains($0) || (local.pack?.covers($0) ?? false) })
    }

    /// Makes sure the network covers these tiles (rebuilt only when the available set changes).
    @discardableResult
    private func ensureNetwork(_ keys: [TileKey]) -> Bool {
        let have = available(keys)
        guard !have.isEmpty else { return false }
        if have != netTiles || net == nil {
        #if DEBUG
        PerfCounters.add("roads.rebuild")
        #endif
            let lookup = local.lookup(Array(have))
            let network = RoadNetwork(lookup.elements)
            net = network
            netTiles = have
            sites = RoadFeatures.signalSites(network)
            matcher = LightMatcher(network: network)
            consumed = 0
            (candidates, manyStreets) = Self.layerContent(network, sites: sites)
        }
        return true
    }

    /// Signal sites (one symbol at the mean of their nodes), stop signs, skewed junctions, and the
    /// streets of the network with more than 3 signal sites per km over at least 300 m.
    static func layerContent(_ net: RoadNetwork, sites: [Int64: Int64]) -> ([RoadPOI], [[LatLon]]) {
        var pois: [RoadPOI] = []
        var siteMembers: [Int64: [LatLon]] = [:]
        for f in net.features.values {
            switch f.type {
            case .trafficSignals:
                if let s = sites[f.nodeId] { siteMembers[s, default: []].append(f.position) }
            case .stop:
                pois.append(RoadPOI(id: f.nodeId, kind: .stop(allWay: RoadFeatures.isAllWayStop(net.nodeTags[f.nodeId])),
                                    lat: f.lat, lon: f.lon, nodes: [f.nodeId]))
            default:
                // Only junctions the skew rule flags; ordinary junctions get no symbol.
                if f.skewed == true { pois.append(RoadPOI(id: f.nodeId, kind: .skewed, lat: f.lat, lon: f.lon, nodes: [f.nodeId])) }
            }
        }
        var siteNodes: [Int64: [Int64]] = [:]
        for (node, site) in sites { siteNodes[site, default: []].append(node) }
        for (site, members) in siteMembers {
            pois.append(RoadPOI(id: site, kind: .signal,
                                lat: members.map(\.lat).reduce(0, +) / Double(members.count),
                                lon: members.map(\.lon).reduce(0, +) / Double(members.count), nodes: siteNodes[site] ?? [site]))
        }
        var length: [String: Double] = [:]
        var streetSites: [String: Set<Int64>] = [:]
        var wayIds: [String: [Int64]] = [:]
        for s in net.segments where s.tags["name"] != nil || s.tags["ref"] != nil {
            length[s.streetName, default: 0] += s.length
            if wayIds[s.streetName]?.last != s.wayId { wayIds[s.streetName, default: []].append(s.wayId) }
            for id in s.nodeIds { if let site = sites[id] { streetSites[s.streetName, default: []].insert(site) } }
        }
        // One line per way (its segments joined in OSM order), not one per segment: the map draws
        // a few dozen lines instead of hundreds.
        var many: [[LatLon]] = []
        for (name, m) in length where m >= RoadConstants.streetMinDrivenM {
            guard Double(streetSites[name]?.count ?? 0) / (m / 1000) > RoadConstants.manyPerKm else { continue }
            for wayId in Set(wayIds[name] ?? []) {
                var line: [LatLon] = []
                for k in net.byWay[wayId] ?? [] {
                    let coords = net.segments[k].coords
                    line.append(contentsOf: line.last == coords.first ? coords.dropFirst() : coords[...])
                }
                if line.count >= 2 { many.append(line) }
            }
        }
        return (pois, many)
    }

    /// Feeds recorded fixes and returns the counters. With `mayRebuild` false (the app is in the
    /// background) the network is never rebuilt: building one takes a few hundred MB for a moment,
    /// which a background app should not ask for while it records. Fixes beyond it are not counted.
    func feed(_ fixes: [Fix], mayRebuild: Bool = true) -> LiveRoadCounts {
        #if DEBUG
        PerfCounters.add("roads.feed")
        #endif
        guard let last = fixes.last else { return counts }
        let center = TileKey.containing(lat: last.latitude, lon: last.longitude)
        if mayRebuild {
            counts.hasRoadData = ensureNetwork(center.withNeighbours)
        } else {
            counts.hasRoadData = net != nil && netTiles.contains(center)
        }
        guard counts.hasRoadData else {
            clearLimit()
            for f in fixes { account(f, state: SpeedLimitSelector.Hidden.noRoadData.rawValue) }
            counts.limitHidden = .noRoadData
            return counts
        }
        consume(fixes)
        return counts
    }

    /// Rebuilds the counters from a whole trip (a resumed trip), region by region: each analysis
    /// chunk (at most 12 tiles) gets its own network, so passes far from the last fix count too.
    /// The network around the last fix then stays for the live feed. Builds networks, so only
    /// while the app is active.
    func refill(_ fixes: [Fix]) -> LiveRoadCounts {
        guard let last = fixes.last else { return counts }
        for range in RoadAnalyzer.chunks(fixes) {
            let part = Array(fixes[range])
            guard ensureNetwork(RoadAnalyzer.tiles(for: part)) else { continue }
            consume(part)
        }
        counts.hasRoadData = ensureNetwork(TileKey.containing(lat: last.latitude, lon: last.longitude).withNeighbours)
        // The replayed history says nothing about the road now: the sign waits for live fixes.
        clearLimit()
        return counts
    }

    /// True while a network is built (tests).
    var hasNetwork: Bool { net != nil }

    /// Runs fixes through the matcher of the current network and counts the new passes.
    private func consume(_ fixes: [Fix]) {
        guard let net, var m = matcher else { return }
        for f in fixes {
            let mf = MatchFix(f)
            m.add(mf)
            selectLimit(mf, position: m.currentPosition, net: net)
            account(f, state: limits.hidden?.rawValue ?? "shown")
            // Each fix against the limit shown at that fix, in order.
            over.update(time: f.time, speed: f.speed, speedAccuracy: f.speedAccuracy, limit: limits.shown)
        }
        counts.speedLimit = limits.shown
        counts.limitHidden = limits.hidden
        counts.overLimit = over.over
        counts.overLimitBy = over.excess
        let passes = m.result.passes
        for pass in passes[min(consumed, passes.count)...] {
            guard let f = net.features[pass.nodeId] else { continue }
            let tags = net.nodeTags[pass.nodeId]
            guard RoadFeatures.applies(net: net, node: pass.nodeId, type: f.type, segment: pass.segment, travel: pass.direction) else { continue }
            switch f.type {
            case .trafficSignals:
                let site = sites[pass.nodeId]
                if site != lastSite || pass.time - lastSiteTime > RoadConstants.sameSiteSeconds { counts.signalSites += 1 }
                lastSite = site
                lastSiteTime = pass.time
            case .stop:
                counts.stopSigns += 1
                if RoadFeatures.isAllWayStop(tags) { counts.allWayStops += 1 }
            default:
                break
            }
            if f.skewed == true { counts.skewedJunctions += 1 }
        }
        consumed = passes.count
        matcher = m
        counts.category = m.currentPosition.flatMap { net.segments[$0.segment].categories.first }
    }

    /// Feeds the speed-limit selector with one fix: the matched way's limit and every other way
    /// within the match's distance plus the selector's margin whose legal travel bearing there is
    /// within the matcher's heading limit of the matched direction (not only the matcher's own
    /// candidates, whose radius is 12 m at good accuracy). A bare number is no limit in the US.
    private func selectLimit(_ f: MatchFix, position: MatchPosition?, net: RoadNetwork) {
        guard let position, let acc = f.accuracy else {
            limits.update(point: f.point, accuracy: f.accuracy, speed: f.speed, matchedWay: nil, limit: nil, distance: 0, rivals: [])
            return
        }
        let seg = net.segments[position.segment]
        let unitless = SpeedLimit.unitless(atLat: f.lat, lon: f.lon)
        let matchedBearing = Self.bearing(net, position)
        let distance = OSMGeo.project(f.point, onto: seg.coords).distance
        let reach = distance + SpeedLimitSelector.rivalMarginM
        var rivals: [SpeedLimitSelector.Rival] = []
        for k in net.segmentsNear(f.point, radius: reach) {
            let s = net.segments[k]
            guard s.wayId != seg.wayId else { continue }
            let pr = OSMGeo.project(f.point, onto: s.coords)
            guard pr.distance <= reach else { continue }
            let compatible = s.directions.contains { d in
                let b = d == .forward ? pr.bearing : (pr.bearing + 180).truncatingRemainder(dividingBy: 360)
                return matchedBearing.map { OSMGeo.angleDiff($0, b) <= RoadConstants.headingMaxDiffDeg } ?? true
            }
            guard compatible else { continue }
            rivals.append(SpeedLimitSelector.Rival(way: s.wayId, limit: SpeedLimit.parse(s.tags["maxspeed"], unitless: unitless),
                                                   distance: pr.distance))
        }
        limits.update(point: f.point, accuracy: acc, speed: f.speed, matchedWay: seg.wayId, direction: position.direction,
                      limit: SpeedLimit.parse(seg.tags["maxspeed"], unitless: unitless), qualified: seg.qualifiedMaxspeed,
                      distance: distance, rivals: rivals)
    }

    /// Travel bearing at a matched position.
    static func bearing(_ net: RoadNetwork, _ p: MatchPosition) -> Double? {
        let s = net.segments[p.segment]
        let coords = p.direction == .forward ? s.coords : Array(s.coords.reversed())
        return TrailGeometry.point(along: coords, at: p.offset)?.bearing
    }

    /// The POI layer around an anchor (the car while recording, else the map center): signal
    /// sites, stop signs and skewed junctions within 800 m, at most 40, nearest first; those on the
    /// car's road ahead flagged `ahead`. Plus the nearby streets with many signals.
    func layer(lat: Double, lon: Double) -> RoadMapLayer {
        let center = TileKey.containing(lat: lat, lon: lon)
        if !tripActive || net == nil { ensureNetwork(center.withNeighbours) }
        guard let net else { return RoadMapLayer() }
        let here = LatLon(lat: lat, lon: lon)
        let ahead = tripActive ? aheadNodes(net) : []
        var near: [(RoadPOI, Double)] = []
        for var p in candidates {
            let d = OSMGeo.haversine(here, LatLon(lat: p.lat, lon: p.lon))
            guard d <= Self.poiRadius else { continue }
            p.ahead = p.nodes.contains { ahead.contains($0) }
            near.append((p, d))
        }
        near.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
        var lines: [([LatLon], Double)] = []
        for line in manyStreets {
            let d = line.map { OSMGeo.haversine(here, $0) }.min() ?? .infinity
            if d <= Self.lineRadius { lines.append((line, d)) }
        }
        lines.sort { $0.1 < $1.1 }
        return RoadMapLayer(pois: near.prefix(Self.maxPOIs).map(\.0), manySignalStreets: lines.prefix(Self.maxLines).map(\.0),
                            tiles: netTiles.sorted())
    }

    /// Nodes on the car's road ahead: from the matched position along segments of the same street,
    /// in their legal direction, up to 800 m.
    private func aheadNodes(_ net: RoadNetwork) -> Set<Int64> {
        guard let pos = matcher?.currentPosition else { return [] }
        let first = net.segments[pos.segment]
        let street = first.streetName
        var out: Set<Int64> = []
        let n = first.nodeIds.count
        for j in 0..<n {
            let i = pos.direction == .forward ? j : n - 1 - j
            let off = pos.direction == .forward ? first.cum[i] : first.length - first.cum[i]
            if off >= pos.offset { out.insert(first.nodeIds[i]) }
        }
        var frontier: [(node: Int64, dist: Double, from: Int)] = [(first.exitNode(pos.direction), first.length - pos.offset, pos.segment)]
        var seen: Set<Int> = [pos.segment]
        while let (node, dist, _) = frontier.popLast() {
            guard dist < Self.aheadMeters else { continue }
            for end in net.ends[node] ?? [] where !seen.contains(end.segment) {
                let seg = net.segments[end.segment]
                let dir: TravelDirection = end.atStart ? .forward : .backward
                guard seg.streetName == street, seg.allows(dir) else { continue }
                seen.insert(end.segment)
                out.formUnion(seg.nodeIds)
                frontier.append((seg.exitNode(dir), dist + seg.length, end.segment))
            }
        }
        return out
    }
}
