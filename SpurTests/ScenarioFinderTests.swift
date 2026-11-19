import Foundation
import Testing
@testable import Spur

/// SPEC 18.4: the scenario finder on Spur's road data (ported from the parent's SPEC 8).
struct ScenarioFinderTests {
    /// A street running east from `lon0`, `n` segments of about 100 m, way `way`, nodes from `node0`.
    static func street(way: Int64, node0: Int64, n: Int, lat: Double = 32.78, lon0: Double = -96.80,
                       tags: [String: String] = ["highway": "residential", "name": "Elm St"],
                       categories: [RoadCategory] = [.local], oneway: Bool = false) -> [RoadSegment] {
        (0..<n).map { k in
            let a = LatLon(lat: lat, lon: lon0 + Double(k) * 0.00107), b = LatLon(lat: lat, lon: lon0 + Double(k + 1) * 0.00107)
            let len = OSMGeo.haversine(a, b)
            return RoadSegment(id: "\(way):\(node0 + Int64(k)):\(node0 + Int64(k) + 1)", wayId: way, fromNode: node0 + Int64(k),
                               toNode: node0 + Int64(k) + 1, nodeIds: [node0 + Int64(k), node0 + Int64(k) + 1], coords: [a, b],
                               cum: [0, len], length: len, tags: tags, categories: categories,
                               directions: oneway ? [.forward] : [.forward, .backward])
        }
    }

    static func signal(_ node: Int64, lat: Double = 32.78, lon: Double) -> FeatureNode {
        FeatureNode(nodeId: node, lat: lat, lon: lon, type: .trafficSignals)
    }

    @Test func aSignalCorridorRanksAndExplainsItself() {
        let elm = Self.street(way: 1, node0: 100, n: 10)                       // 1 km, 5 signals
        let oak = Self.street(way: 2, node0: 500, n: 10, lat: 32.79)           // 1 km, 1 signal
        let features = (0..<5).map { Self.signal(100 + Int64($0) * 2, lon: -96.80 + Double($0) * 0.00214) }
            + [Self.signal(503, lat: 32.79, lon: -96.80 + 3 * 0.00107)]
        let q = ScenarioFinder.Query(origin: LatLon(lat: 32.785, lon: -96.795), radiusM: 3000, features: [.signals])
        let r = ScenarioFinder.find(q, segments: elm + oak, features: features) { _, _ in false }
        // As in the parent, a cluster holds only segments with a hit: Oak's one signal sits on two
        // segments of 100 m, 5 per km, so it counts too, but ranks behind Elm's corridor.
        #expect(r.count == 2)
        #expect(r.first?.counts[.signals] == 5)
        #expect(r.first?.reason == "5 Ampeln, noch nicht befahren")
        #expect(r.last?.counts[.signals] == 1)
    }

    @Test func drivenDirectionsChangeTheReasonAndOnlyMissingDropsDrivenClusters() {
        let elm = Self.street(way: 1, node0: 100, n: 4)
        let stops = (0..<4).map { FeatureNode(nodeId: 100 + Int64($0), lat: 32.78, lon: -96.80 + Double($0) * 0.00107, type: .stop) }
        let q = ScenarioFinder.Query(origin: LatLon(lat: 32.78, lon: -96.80), radiusM: 2000, features: [.stopSigns])
        // Driven eastbound (forward) only: westbound is missing.
        let east = ScenarioFinder.find(q, segments: elm, features: stops) { _, d in d == .forward }
        #expect(east.first?.reason == "4 Stoppschilder, Richtung West fehlt")
        // All driven: still offered with "egal", left out with "nur fehlende Richtung".
        let all = ScenarioFinder.find(q, segments: elm, features: stops) { _, _ in true }
        #expect(all.first?.reason == "4 Stoppschilder, bereits befahren")
        var missingOnly = q
        missingOnly.onlyMissing = true
        #expect(ScenarioFinder.find(missingOnly, segments: elm, features: stops) { _, _ in true }.isEmpty)
    }

    @Test func outsideTheRadiusNothingAndTagFeaturesCount() {
        let ramp = Self.street(way: 7, node0: 900, n: 3, tags: ["highway": "motorway_link"], categories: [.ramp], oneway: true)
        let near = ScenarioFinder.Query(origin: LatLon(lat: 32.78, lon: -96.80), radiusM: 500, features: [.ramps])
        #expect(ScenarioFinder.find(near, segments: ramp, features: []) { _, _ in false }.first?.reason == "1 Rampe, noch nicht befahren")
        var far = near
        far.origin = LatLon(lat: 32.90, lon: -96.80)
        #expect(ScenarioFinder.find(far, segments: ramp, features: []) { _, _ in false }.isEmpty)
    }

    @Test func theNearestUndrivenSegmentDirection() {
        let elm = Self.street(way: 1, node0: 100, n: 5)
        let origin = LatLon(lat: 32.78, lon: -96.80 + 2.2 * 0.00107)
        // Everything driven except segment 103-104 westbound.
        let n = ScenarioFinder.nearestUndriven(from: origin, segments: elm, features: [], chips: []) { s, d in
            !(s.id == "1:103:104" && d == .backward)
        }
        #expect(n?.segment.id == "1:103:104" && n?.direction == .backward)
        #expect(n.map { abs($0.start.lon - (-96.80 + 4 * 0.00107)) < 1e-9 } == true, "entered from its east end")
    }

    @Test func drivenComesFromTheCoverageEdges() {
        let elm = Self.street(way: 1, node0: 100, n: 1)
        let edge = RoadCoverage.Edge(key: CoverageEdgeKey(wayId: 1, a: 100, b: 101), a: elm[0].coords[0], b: elm[0].coords[1],
                                     forward: true, backward: false)
        let driven = ScenarioFinder.drivenLookup([edge])
        #expect(driven(elm[0], .forward) && !driven(elm[0], .backward))
    }
}
