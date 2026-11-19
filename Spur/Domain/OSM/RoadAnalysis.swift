import Foundation

/// The optional `roads` block of `trip.json` (SPEC 14.5): road statistics from OpenStreetMap. Every
/// field is optional or has a default, so the block can grow without breaking older records.
/// Road data © OpenStreetMap contributors, ODbL.
nonisolated struct RoadStatistics: Codable, Sendable, Equatable {
    static let currentVersion = 1

    struct Counts: Codable, Sendable, Equatable {
        /// Signal sites passed (signal nodes of one intersection count once).
        var signalSites = 0
        /// Stop signs passed that apply in the direction of travel.
        var stopSigns = 0
        /// Of those, all-way stops (`stop=all`).
        var allWayStops = 0
        var giveWay = 0
        var roundabouts = 0
        var levelCrossings = 0
        var motorwayJunctions = 0
        var skewedJunctions = 0
    }

    struct StopsByClass: Codable, Sendable, Equatable {
        var signal = 0
        var stopSign = 0
        var other = 0
    }

    /// A street with many signals or stop signs.
    struct StreetDensity: Codable, Sendable, Equatable, Hashable {
        var name: String
        var drivenMeters: Double
        var count: Int
        var perKm: Double
    }

    struct CategoryShare: Codable, Sendable, Equatable, Hashable {
        var category: RoadCategory
        var distance: Double
        var time: Double
    }

    var version: Int = RoadStatistics.currentVersion
    var analyzedAt: Date
    /// Tiles used, by source.
    var tilesFromCache: Int = 0
    var tilesFromPack: Int = 0
    var tilesFromLive: Int = 0
    /// Tiles the trip touches that had no data at analysis time; the analysis runs again when they arrive.
    var missingTiles: [TileKey]?
    /// Share (0 to 1) of the trip distance (Spur's distance statistic) driven between fixes that
    /// are matched to the road network ("Straßendaten für 97 % der Strecke").
    var coverage: Double?
    /// Length of the matched road path in meters.
    var matchedDistance: Double = 0
    var counts = Counts()
    var stops = StopsByClass()
    var manySignals: [StreetDensity] = []
    var manyStopSigns: [StreetDensity] = []
    var categories: [CategoryShare] = []
    /// Share (0 to 1) of the matched distance on roads with a known speed limit.
    var speedLimitKnownShare: Double?
    /// Share (0 to 1) of that distance driven more than 5 mph (8 km/h) above the limit.
    var speedingShare: Double?

    var hasMissingTiles: Bool { !(missingTiles ?? []).isEmpty }
}

/// One passed feature (roads.json and the JSON export, SPEC 14.7).
nonisolated struct PassedFeature: Codable, Sendable, Equatable, Hashable {
    var nodeId: Int64
    var type: FeatureType
    /// Signal site id (smallest signal node id of the intersection).
    var siteId: Int64?
    /// Milliseconds since 1970.
    var timeMs: Int64
    var lat: Double
    var lon: Double
    var wayId: Int64
    var street: String
    /// For a stop or signal: whether it applies in the direction of travel.
    var applies: Bool
    var allWay: Bool?
    var skewed: Bool?
}

/// Per-trip road details too large for `trip.json` (which every launch reads for the index):
/// `roads.json` in the trip folder.
nonisolated struct RoadDetails: Codable, Sendable, Equatable {
    struct Way: Codable, Sendable, Equatable {
        var street: String
        /// First category of the parent's order (the most specific).
        var category: RoadCategory?
        var maxspeedMph: Double?
    }

    var version: Int = RoadStatistics.currentVersion
    var passed: [PassedFeature] = []
    /// Way id per fix (in fix file order), nil when the fix is not matched.
    var fixWays: [Int64?] = []
    var ways: [String: Way] = [:]

    func way(forFix i: Int) -> (Int64, Way)? {
        guard i < fixWays.count, let id = fixWays[i], let w = ways[String(id)] else { return nil }
        return (id, w)
    }
}

/// The road analysis of one trip (SPEC 14.5). Pure: fixes and a tile loader in, statistics out.
///
/// Bounded: the trip is cut into chunks whose fixes touch at most `maxTilesPerChunk` tiles, so a
/// long trip never holds more than that many parsed tiles. Each chunk is matched with 30 s of the
/// neighbouring fixes on both sides, and keeps only what happens in its own time span.
nonisolated enum RoadAnalyzer {
    static let maxTilesPerChunk = 12
    static let chunkOverlapSeconds = 30.0

    /// The z13 tiles a fix needs: every tile within 60 m of it.
    static func tiles(near f: Fix) -> Set<TileKey> {
        let dLat = 60 / OSMGeo.R * 180 / .pi
        let dLon = dLat / max(0.01, cos(f.latitude * .pi / 180))
        var out: Set<TileKey> = []
        for (a, b) in [(-dLat, -dLon), (-dLat, dLon), (dLat, -dLon), (dLat, dLon), (0, 0)] {
            out.insert(TileKey.containing(lat: f.latitude + a, lon: f.longitude + b))
        }
        return out
    }

    /// The tiles a whole trip needs.
    static func tiles(for fixes: [Fix]) -> [TileKey] {
        var out: Set<TileKey> = []
        for f in fixes { out.formUnion(tiles(near: f)) }
        return out.sorted()
    }

    /// Consecutive fix ranges whose tiles stay within the chunk limit.
    static func chunks(_ fixes: [Fix], maxTiles: Int = maxTilesPerChunk) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var current: Set<TileKey> = []
        for (i, f) in fixes.enumerated() {
            let t = tiles(near: f)
            if !current.isEmpty && current.union(t).count > maxTiles {
                out.append(start..<i)
                start = i
                current = []
            }
            current.formUnion(t)
        }
        if start < fixes.count { out.append(start..<fixes.count) }
        return out
    }

    struct Output: Sendable {
        var statistics: RoadStatistics
        var details: RoadDetails
        /// The driven edges and directions (SPEC 15), stored as `coverage.json`.
        var coverage = TripCoverage()
    }

    /// What one chunk contributes.
    private struct Piece {
        var length: Double
        var time: Double
        var street: String
        var categories: [RoadCategory]
        var hasLimit: Bool
    }

    private struct Pass {
        var feature: PassedFeature
        var onRoundabout: Bool
    }

    static func analyze(fixes: [Fix], config: StatsConfig, now: Date = Date(),
                        maxTilesPerChunk: Int = maxTilesPerChunk,
                        load: ([TileKey]) -> RoadTileProvider.Lookup) -> Output {
        var stats = RoadStatistics(analyzedAt: now)
        var details = RoadDetails()
        details.fixWays = Array(repeating: nil, count: fixes.count)
        let track = Track(fixes: fixes, config: config)
        guard fixes.count >= 2 else { return Output(statistics: stats, details: details) }
        var cover = CoverageAccumulator()

        let stopList = StopStats.stops(track)
        var passes: [Pass] = []
        var pieces: [Piece] = []
        var limitMph = [Double?](repeating: nil, count: fixes.count)
        var matchedFix = [Bool](repeating: false, count: fixes.count)
        var sources: [TileKey: RoadTileSource] = [:]
        var missing: Set<TileKey> = []

        for core in chunks(fixes, maxTiles: maxTilesPerChunk) {
            let t0 = fixes[core.lowerBound].time
            let t1 = core.upperBound < fixes.count ? fixes[core.upperBound].time : .infinity
            var lo = core.lowerBound
            while lo > 0 && fixes[lo - 1].time >= t0 - chunkOverlapSeconds { lo -= 1 }
            var hi = core.upperBound
            while hi < fixes.count && fixes[hi].time < t1 + chunkOverlapSeconds { hi += 1 }
            let window = Array(fixes[lo..<hi])
            let lookup = load(tiles(for: window))
            for (k, v) in lookup.sources { sources[k] = v }
            missing.formUnion(lookup.missing)
            let net = RoadNetwork(lookup.elements)
            guard !net.segments.isEmpty else { continue }
            let match = HMMMatcher.match(window.map(MatchFix.init), network: net)
            let sites = RoadFeatures.signalSites(net)
            let inCore: (Double) -> Bool = { $0 >= t0 && $0 < t1 }

            for p in match.pieces where inCore(p.startTime) {
                let seg = net.segments[p.segment]
                cover.add(p, segment: seg)
                pieces.append(Piece(length: p.length, time: max(0, p.endTime - p.startTime), street: seg.streetName,
                                    categories: seg.categories, hasLimit: RoadRules.maxspeedMph(seg.tags["maxspeed"]) != nil))
            }
            for pass in match.passes where inCore(pass.time) {
                guard let f = net.features[pass.nodeId] else { continue }
                let seg = net.segments[pass.segment]
                let tags = net.nodeTags[pass.nodeId]
                passes.append(Pass(feature: PassedFeature(
                    nodeId: pass.nodeId, type: f.type, siteId: f.type == .trafficSignals ? sites[pass.nodeId] : nil,
                    timeMs: Int64((pass.time * 1000).rounded()), lat: f.lat, lon: f.lon, wayId: seg.wayId, street: seg.streetName,
                    applies: RoadFeatures.applies(net: net, node: pass.nodeId, type: f.type, segment: pass.segment, travel: pass.direction),
                    allWay: f.type == .stop ? RoadFeatures.isAllWayStop(tags) : nil, skewed: f.skewed),
                    onRoundabout: seg.tags["junction"] == "roundabout"))
            }
            for (j, pos) in match.positions.enumerated() {
                let i = lo + j
                guard core.contains(i), let pos else { continue }
                let seg = net.segments[pos.segment]
                matchedFix[i] = true
                details.fixWays[i] = seg.wayId
                limitMph[i] = RoadRules.maxspeedMph(seg.tags["maxspeed"])
                if details.ways[String(seg.wayId)] == nil {
                    details.ways[String(seg.wayId)] = RoadDetails.Way(street: seg.streetName, category: seg.categories.first,
                                                                     maxspeedMph: limitMph[i])
                }
            }
            for p in passes where details.ways[String(p.feature.wayId)] == nil {
                if let k = net.byWay[p.feature.wayId]?.first {
                    let seg = net.segments[k]
                    details.ways[String(seg.wayId)] = RoadDetails.Way(street: seg.streetName, category: seg.categories.first,
                                                                     maxspeedMph: RoadRules.maxspeedMph(seg.tags["maxspeed"]))
                }
            }
            // Stops whose start lies in this chunk, against this chunk's matched path.
            let pathNodes = RoadStops.pathNodes(match, net: net)
            for stop in stopList where inCore(fixes[stop.startIndex].time) {
                switch RoadStops.classify(RoadStops.standingPoint(stop, fixes: fixes), pathNodes: pathNodes, net: net) {
                case .signal: stats.stops.signal += 1
                case .stopSign: stats.stops.stopSign += 1
                case .other: stats.stops.other += 1
                }
            }
        }
        // Stops in stretches without any road data.
        let classified = stats.stops.signal + stats.stops.stopSign + stats.stops.other
        stats.stops.other += max(0, stopList.count - classified)

        stats.tilesFromCache = sources.values.filter { $0 == .cache }.count
        stats.tilesFromPack = sources.values.filter { $0 == .pack }.count
        stats.tilesFromLive = sources.values.filter { $0 == .live }.count
        stats.missingTiles = missing.isEmpty ? nil : missing.sorted()

        // Distance and time per category and street, and the speed limit shares.
        var matched = 0.0, limited = 0.0
        var streetMeters: [String: Double] = [:]
        var categoryDistance: [RoadCategory: Double] = [:]
        var categoryTime: [RoadCategory: Double] = [:]
        for p in pieces {
            matched += p.length
            streetMeters[p.street, default: 0] += p.length
            for c in p.categories {
                categoryDistance[c, default: 0] += p.length
                categoryTime[c, default: 0] += p.time
            }
            if p.hasLimit { limited += p.length }
        }
        stats.matchedDistance = matched
        // Coverage in one metric: the distance statistic's increments whose fix is matched. A fix
        // that stands (not a matcher layer) adds no distance either way.
        var covered = 0.0
        for i in 1..<fixes.count where matchedFix[i] { covered += track.distanceIncrement[i] }
        stats.coverage = track.totalDistance > 0 ? min(1, covered / track.totalDistance) : nil
        stats.categories = RoadCategory.allCases.compactMap { c in
            guard let d = categoryDistance[c], d > 0 else { return nil }
            return RoadStatistics.CategoryShare(category: c, distance: d, time: categoryTime[c] ?? 0)
        }
        stats.speedLimitKnownShare = matched > 0 ? limited / matched : nil
        stats.speedingShare = speedingShare(track: track, limitMph: limitMph)

        // Counts from the passes, in time order.
        passes.sort { $0.feature.timeMs < $1.feature.timeMs }
        var lastSite: Int64?
        var lastSiteMs = Int64.min / 2
        var lastOnRing = false
        var signalsByStreet: [String: Int] = [:]
        var stopsByStreet: [String: Int] = [:]
        for p in passes {
            let f = p.feature
            switch f.type {
            case .trafficSignals where f.applies:
                // A divided road carries two to four signal nodes per intersection: one site. The
                // same site counts again only when it is passed again later (around the block).
                if f.siteId != lastSite || Double(f.timeMs - lastSiteMs) / 1000 > RoadConstants.sameSiteSeconds {
                    stats.counts.signalSites += 1
                    signalsByStreet[f.street, default: 0] += 1
                }
                lastSite = f.siteId
                lastSiteMs = f.timeMs
            case .stop where f.applies:
                stats.counts.stopSigns += 1
                stopsByStreet[f.street, default: 0] += 1
                if f.allWay == true { stats.counts.allWayStops += 1 }
            case .giveWay where f.applies:
                stats.counts.giveWay += 1
            case .levelCrossing:
                stats.counts.levelCrossings += 1
            case .motorwayJunction:
                stats.counts.motorwayJunctions += 1
            case .roundabout, .miniRoundabout:
                // Every node passed while going round one roundabout is that one roundabout.
                if !(lastOnRing && p.onRoundabout) { stats.counts.roundabouts += 1 }
            default:
                break
            }
            lastOnRing = p.onRoundabout
            if f.skewed == true { stats.counts.skewedJunctions += 1 }
        }
        details.passed = passes.map(\.feature)

        // Streets with many signals or stop signs.
        func dense(_ counts: [String: Int]) -> [RoadStatistics.StreetDensity] {
            counts.compactMap { name, count in
                guard let m = streetMeters[name], m >= RoadConstants.streetMinDrivenM else { return nil }
                let perKm = Double(count) / (m / 1000)
                guard perKm > RoadConstants.manyPerKm else { return nil }
                return RoadStatistics.StreetDensity(name: name, drivenMeters: m, count: count, perKm: perKm)
            }.sorted { $0.perKm != $1.perKm ? $0.perKm > $1.perKm : $0.name < $1.name }
        }
        stats.manySignals = dense(signalsByStreet)
        stats.manyStopSigns = dense(stopsByStreet)
        return Output(statistics: stats, details: details, coverage: cover.coverage())
    }

    /// Share of the distance on roads with a known limit driven more than 5 mph above it: an
    /// interval between two matched fixes counts with its distance when its speed exceeds the
    /// limit of the later fix's road by more than the tolerance.
    static func speedingShare(track: Track, limitMph: [Double?]) -> Double? {
        var total = 0.0
        var over = 0.0
        for i in 1..<max(1, track.fixes.count) {
            guard let mph = limitMph[i], limitMph[i - 1] != nil, let v = track.intervalSpeed[i] else { continue }
            let d = track.distanceIncrement[i]
            total += d
            if v > mph * 0.44704 + RoadConstants.speedingToleranceMps { over += d }
        }
        return total > 0 ? over / total : nil
    }
}

/// History totals of the road data (SPEC 14.5): signal sites and stop signs over all analyzed trips.
nonisolated struct RoadTotals: Equatable, Sendable {
    var signalSites = 0
    var stopSigns = 0
    /// Trips that have a road analysis.
    var analyzedTrips = 0

    static func of(_ trips: [TripRecord]) -> RoadTotals {
        var t = RoadTotals()
        for trip in trips {
            guard let r = trip.roads else { continue }
            t.signalSites += r.counts.signalSites
            t.stopSigns += r.counts.stopSigns
            t.analyzedTrips += 1
        }
        return t
    }
}
