import Foundation

/// How a stop is classified (parent SPEC 7, SPEC 14.5).
nonisolated enum StopClass: String, Codable, Sendable, CaseIterable {
    /// Within 30 m of a signal node of the matched path ("an Ampel").
    case signal
    /// Within 30 m of a stop-sign node of the matched path ("an Stoppschild").
    case stopSign
    /// Anything else ("sonstige").
    case other
}

/// Stops against the road data. Pure.
nonisolated enum RoadStops {
    /// Where the car stood: the mean position of the fixes of the slow run (parent `standingPoint`).
    static func standingPoint(_ stop: StopStats.Stop, fixes: [Fix]) -> LatLon {
        let lo = min(stop.startIndex + 1, stop.endIndex)
        let range = lo...stop.endIndex
        var lat = 0.0, lon = 0.0
        for i in range {
            lat += fixes[i].latitude
            lon += fixes[i].longitude
        }
        let n = Double(range.count)
        return LatLon(lat: lat / n, lon: lon / n)
    }

    /// Every node on the matched path: the nodes inside the driven pieces (0.5 m tolerance at the
    /// piece ends, like the parent's `nodesPassed`). The whole trip's path, so a car standing at
    /// the stop line before a signal finds that signal (it passes it afterwards).
    static func pathNodes(_ r: MatchResult, net: RoadNetwork) -> Set<Int64> {
        var out: Set<Int64> = []
        for p in r.pieces {
            let s = net.segments[p.segment]
            for (i, id) in s.nodeIds.enumerated() {
                let o = p.direction == .forward ? s.cum[i] : s.length - s.cum[i]
                if o >= p.from - 0.5 && o <= p.to + 0.5 { out.insert(id) }
            }
        }
        return out
    }

    /// Parent `classifyStop` over the signal and stop-sign nodes of the matched path: the nearer of
    /// the two kinds when within 30 m, else `other`.
    static func classify(_ at: LatLon, pathNodes: Set<Int64>, net: RoadNetwork) -> StopClass {
        var kind = StopClass.other
        var best = Double.infinity
        for id in pathNodes {
            guard let f = net.features[id] else { continue }
            let k: StopClass
            switch f.type {
            case .trafficSignals: k = .signal
            case .stop: k = .stopSign
            default: continue
            }
            let d = OSMGeo.haversine(at, f.position)
            if d <= RoadConstants.stopFeatureRadiusM && d < best {
                best = d
                kind = k
            }
        }
        return kind
    }
}
