import Foundation
import Testing
@testable import Spur

struct StreetNameTests {
    @Test func streetFromShortAddress() {
        #expect(StreetName.from(shortAddress: "1313 Jackson St, Dallas", city: "Dallas") == "Jackson St")
        #expect(StreetName.from(shortAddress: "12237 N Central Expy, Dallas", city: "Dallas") == "N Central Expy")
        #expect(StreetName.from(shortAddress: "Marienplatz 7\u{2013}11, München", city: "München") == "Marienplatz")
        #expect(StreetName.from(shortAddress: "Leopoldstraße 12a, München", city: "München") == "Leopoldstraße")
        #expect(StreetName.from(shortAddress: "2300 Crossunder No 3 Rd, Grapevine", city: "Grapevine") == "Crossunder No 3 Rd")
        #expect(StreetName.from(shortAddress: "Highway 75", city: nil) == "Highway 75")
        #expect(StreetName.from(shortAddress: "FM 2551, Lucas", city: "Lucas") == "FM 2551")
        #expect(StreetName.from(shortAddress: "County Rd 470, Princeton", city: "Princeton") == "County Rd 470")
        #expect(StreetName.from(shortAddress: "4100 State Hwy 121, Plano", city: "Plano") == "State Hwy 121")
    }

    @Test func noStreetWhenOnlyTheCityOrNumbers() {
        #expect(StreetName.from(shortAddress: "Grapevine", city: "Grapevine") == nil)
        #expect(StreetName.from(shortAddress: "12, Dallas", city: "Dallas") == nil)
        #expect(StreetName.from(shortAddress: nil, city: "Dallas") == nil)
        #expect(StreetName.from(shortAddress: "", city: nil) == nil)
    }
}

struct LiveAccumulatorTests {
    /// A messy sequence: moving, a stop with jitter, an unusable fix, a missing speed, a gap.
    static var messy: [Fix] {
        var f = Fixtures.northbound(speeds: Array(repeating: 12, count: 20))
        for i in 8..<12 { f[i].speed = 0.3; f[i].latitude += Geo.latitudeDegrees(forMeters: Double(i % 2) * 2) }
        f[14].horizontalAccuracy = 80
        f[15].speed = nil
        let later = Fixtures.shifted(Fixtures.northbound(speeds: Array(repeating: 25, count: 15)), byMs: 60_000)
        return f + later
    }

    @Test func matchesBatchStatistics() {
        var acc = LiveAccumulator()
        var gaps = 0
        for f in Self.messy where acc.add(f) { gaps += 1 }
        let track = Track(fixes: Self.messy)
        #expect(gaps == 1)
        #expect(approx(acc.distance, track.totalDistance, 1e-6))
        #expect(approx(acc.movingTime, TimeStats.compute(track).movingTime, 1e-9))
        #expect(acc.fixCount == Self.messy.count)
    }
}
