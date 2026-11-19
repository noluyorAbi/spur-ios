import Foundation
import Testing
@testable import Spur

/// SPEC 18.11: streets by name, with their driven share and the way to the undriven part.
struct StreetIndexTests {
    /// The planner's grid with names: rows "Elm St 0" … , columns "Main St 0" …, row 2 private.
    static func named() -> [RoadSegment] {
        DiscoveryPlannerTests.grid(4, privateRow: true).map { s in
            var s = s
            s.tags["name"] = s.wayId < 2000 ? "Elm St \(s.wayId - 1000)" : "Hauptstraße \(s.wayId - 2000)"
            return s
        }
    }

    @Test func drivenShareNearestPointsAndExclusions() {
        let origin = LatLon(lat: 32.78, lon: -96.80)
        // Elm St 0 driven on its first block only.
        let driven: (RoadSegment, TravelDirection) -> Bool = { s, d in s.wayId == 1000 && s.fromNode == 0 && d == .forward }
        let streets = StreetIndex.build(Self.named(), origin: origin, driven: driven)
        #expect(!streets.contains { $0.name == "Elm St 2" }, "private ways are left out")
        let elm = try! #require(streets.first { $0.name == "Elm St 0" })
        #expect(elm.lines.count == 3)
        #expect(abs(elm.share - 1.0 / 3) < 0.01, "share \(elm.share)")
        #expect(elm.distanceM < 1, "the origin lies on it")
        let u = try! #require(elm.nearestUndriven)
        #expect(abs(u.lon - (-96.80 + 0.00107)) < 1e-6 && (elm.undrivenDistanceM ?? 0) > 90, "the undriven part starts one block east")
        #expect(streets.first?.distanceM ?? 1 <= streets.last?.distanceM ?? 0, "nearest first")
    }

    @Test func searchMatchesNamesAndPutsTheUndiscoveredFirst() {
        let origin = LatLon(lat: 32.78, lon: -96.80)
        let driven: (RoadSegment, TravelDirection) -> Bool = { s, _ in s.wayId == 2000 }
        let streets = StreetIndex.build(Self.named(), origin: origin, driven: driven)
        #expect(StreetIndex.search(streets, query: "hauptstrasse").count == 4, "ss finds ß, as typed on any keyboard")
        let haupt = StreetIndex.search(streets, query: "haupt")
        #expect(haupt.count == 4 && haupt.last?.name == "Hauptstraße 0", "the driven one last: \(haupt.map(\.name))")
        #expect(StreetIndex.search(streets, query: "ELM").map(\.name).allSatisfy { $0.hasPrefix("Elm") })
        #expect(StreetIndex.search(streets, query: "st 1").map(\.name) == ["Elm St 1"], "word prefix and contains")
        let nearby = StreetIndex.search(streets, query: "")
        #expect(!nearby.contains { $0.name == "Hauptstraße 0" } && nearby.allSatisfy(\.undiscovered), "empty query: undiscovered only")
    }
}
