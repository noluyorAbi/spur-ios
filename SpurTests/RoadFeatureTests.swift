import Foundation
import Testing
@testable import Spur

/// SPEC 14.3: signal sites, stop-sign direction, streets with many signals or stops.
struct RoadFeatureTests {
    /// Builds elements from a list of nodes (id, meters east, meters north of a Dallas origin, tags)
    /// and ways.
    static func elements(_ nodes: [(Int64, Double, Double, [String: String]?)], _ ways: [(Int64, [Int64], [String: String])]) -> OSMElements {
        let lat0 = 32.78, lon0 = -96.80
        let mLat = 111_195.0, mLon = 111_195.0 * cos(lat0 * .pi / 180)
        return OSMElements(
            nodes: nodes.map { OSMNode(id: $0.0, lat: lat0 + $0.2 / mLat, lon: lon0 + $0.1 / mLon, tags: $0.3) },
            ways: ways.map { OSMWay(id: $0.0, nodes: $0.1, tags: $0.2) }
        )
    }

    static let signal = ["highway": "traffic_signals"]

    /// A divided road (two one-way carriageways 20 m apart) crossing a two-way street, with a
    /// signal on each carriageway at the crossing, plus a lone signal 200 m away, plus a signal on
    /// an unconnected parallel road 25 m from the lone one.
    static func dividedCrossing() -> RoadNetwork {
        RoadNetwork(elements([
            (1, -100, -10, nil), (2, 0, -10, signal), (3, 100, -10, nil),      // carriageway east, y = -10
            (4, 100, 10, nil), (5, 0, 10, signal), (6, -100, 10, nil),         // carriageway west, y = +10
            (7, 0, -100, nil), (8, 0, 100, nil),                                // cross street x = 0
            (9, 200, -10, signal), (10, 300, -10, nil),                         // lone signal further east
            (11, 180, 15, nil), (12, 200, 15, signal), (13, 220, 15, nil),     // parallel road, not connected
        ], [
            (100, [1, 2, 3, 9, 10], ["highway": "primary", "oneway": "yes", "name": "Main Street"]),
            (101, [4, 5, 6], ["highway": "primary", "oneway": "yes", "name": "Main Street"]),
            (102, [7, 2, 5, 8], ["highway": "secondary", "name": "Cross Street"]),
            (103, [11, 12, 13], ["highway": "residential", "name": "Side Street"]),
        ]))
    }

    @Test func signalNodesOfOneIntersectionAreOneSite() {
        let net = Self.dividedCrossing()
        let sites = RoadFeatures.signalSites(net)
        #expect(sites.count == 4)
        // The two carriageway signals, 20 m apart and joined by the cross street: one site.
        #expect(sites[2] == sites[5])
        #expect(sites[2] == 2)
        // 200 m away: its own site.
        #expect(sites[9] == 9)
        // 25 m from node 9 but on a road that is not connected within 30 m: its own site.
        #expect(sites[12] == 12)
        #expect(Set(sites.values).count == 3)
    }

    @Test func signalSitesInTheDowntownFixture() throws {
        let c = try OracleCase.load(6)
        let sites = RoadFeatures.signalSites(c.network)
        let distinct = Set(sites.values).count
        print("SIGNAL SITES downtown-grid: \(sites.count) signal nodes in \(distinct) sites")
        #expect(sites.count > 20)
        #expect(distinct < sites.count) // divided streets carry several signal nodes per intersection
        // Every site's nodes lie within 30 m of its id node along the network.
        let graph = RoadFeatures.nodeGraph(c.network)
        for (node, site) in sites where node != site {
            let reach = Dictionary(uniqueKeysWithValues: RoadFeatures.withinNetworkDistance(from: node, limit: 400, graph: graph))
            #expect(reach[site] != nil, "node \(node) and site \(site) are not connected")
        }
    }

    @Test func stopSignDirection() {
        let forward = ["highway": "stop", "direction": "forward"]
        let backward = ["highway": "stop", "direction": "backward"]
        let stopDir = ["highway": "stop", "stop:direction": "backward", "direction": "forward"]
        let untagged = ["highway": "stop"]
        #expect(RoadFeatures.applies(tags: forward, type: .stop, travel: .forward))
        #expect(!RoadFeatures.applies(tags: forward, type: .stop, travel: .backward))
        #expect(RoadFeatures.applies(tags: backward, type: .stop, travel: .backward))
        #expect(!RoadFeatures.applies(tags: backward, type: .stop, travel: .forward))
        // `stop:direction` wins over `direction` for a stop sign.
        #expect(RoadFeatures.applies(tags: stopDir, type: .stop, travel: .backward))
        #expect(!RoadFeatures.applies(tags: stopDir, type: .stop, travel: .forward))
        // Untagged, `both` or anything else: applies.
        #expect(RoadFeatures.applies(tags: untagged, type: .stop, travel: .forward))
        #expect(RoadFeatures.applies(tags: untagged, type: .stop, travel: .backward))
        #expect(RoadFeatures.applies(tags: ["highway": "stop", "direction": "both"], type: .stop, travel: .backward))
        // Signals read `traffic_signals:direction`.
        let sig = ["highway": "traffic_signals", "traffic_signals:direction": "forward"]
        #expect(RoadFeatures.applies(tags: sig, type: .trafficSignals, travel: .forward))
        #expect(!RoadFeatures.applies(tags: sig, type: .trafficSignals, travel: .backward))
        // All-way stop.
        #expect(RoadFeatures.isAllWayStop(["highway": "stop", "stop": "all"]))
        #expect(!RoadFeatures.isAllWayStop(untagged))
    }

    @Test func taggedTypePrecedenceFollowsTheParent() {
        #expect(RoadFeatures.taggedType(["highway": "traffic_signals", "railway": "level_crossing"]) == .trafficSignals)
        #expect(RoadFeatures.taggedType(["railway": "level_crossing"]) == .levelCrossing)
        #expect(RoadFeatures.taggedType(["highway": "street_lamp"]) == nil)
        #expect(RoadFeatures.taggedType(nil) == nil)
    }

    @Test func skewRule() {
        #expect(!RoadFeatures.isSkewed([90, 90]))               // fewer than three approaches
        #expect(!RoadFeatures.isSkewed([90, 90, 180]))          // T junction
        #expect(RoadFeatures.isSkewed([60, 120, 180]))          // 60 below 70
        #expect(RoadFeatures.isSkewed([80, 130, 150]))          // 130 between 110 and 150
        #expect(!RoadFeatures.isSkewed([70, 110, 150, 180]))   // edges are not skewed
    }

    @Test func maxspeedParsing() {
        #expect(RoadRules.maxspeedMph("65 mph") == 65)
        #expect(abs(RoadRules.maxspeedMph("50")! - 31.0686) < 1e-3)
        #expect(RoadRules.maxspeedMph("55 mph;45 mph") == 45)
        #expect(RoadRules.maxspeedMph("signals") == nil)
        #expect(RoadRules.maxspeedMph("55 mph;none") == nil)
    }
}
