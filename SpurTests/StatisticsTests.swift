import Foundation
import Testing
@testable import Spur

struct DistanceTests {
    @Test func straightLineSumsExactly() {
        // 11 fixes, 1 s apart, 10 m/s: 10 steps of 10 m.
        let f = Fixtures.northbound(speeds: Array(repeating: 10, count: 11))
        #expect(approx(DistanceStats.total(f), 100, 1e-6))
    }

    @Test func stationaryJitterAddsNothing() {
        let base = Fixtures.northbound(speeds: [0])[0]
        let offsets: [Double] = [0, 3, -2, 2.5, -3, 1, -1, 3, 0, -2.5]
        let f = offsets.enumerated().map { k, d in
            var x = base
            x.timestampMs += Int64(k) * 1000
            x.latitude += Geo.latitudeDegrees(forMeters: d)
            x.speed = 0.2
            return x
        }
        #expect(DistanceStats.total(f) == 0)
    }

    @Test func jitterAfterDrivingDoesNotGrowDistance() {
        let moving = Fixtures.northbound(speeds: Array(repeating: 10, count: 6)) // 50 m
        var last = moving.last!
        var f = moving
        for k in 1...10 {
            last.timestampMs += 1000
            var j = last
            j.latitude += Geo.latitudeDegrees(forMeters: k % 2 == 0 ? 2 : -2)
            j.speed = 0
            f.append(j)
        }
        #expect(approx(DistanceStats.total(f), 50, 1e-6))
    }

    @Test func unusableFixesAreSkipped() {
        var f = Fixtures.northbound(speeds: Array(repeating: 10, count: 5)) // 40 m
        // A wild fix 5 km east with poor accuracy, inserted in the middle.
        var wild = f[2]
        wild.longitude += 0.05
        wild.horizontalAccuracy = 65
        f[2] = wild
        // Without fix 2, the distance from fix 1 to fix 3 is still 20 m: 40 m in total.
        #expect(approx(DistanceStats.total(f), 40, 1e-6))
        // Unknown accuracy is unusable too.
        f[2].horizontalAccuracy = nil
        #expect(approx(DistanceStats.total(f), 40, 1e-6))
    }

    @Test func accuracyLimitIsConfigurable() {
        let f = Fixtures.northbound(speeds: Array(repeating: 10, count: 5), accuracy: 20)
        #expect(approx(DistanceStats.total(f, config: StatsConfig(usableAccuracy: 30)), 40, 1e-6))
        #expect(DistanceStats.total(f, config: StatsConfig(usableAccuracy: 10)) == 0)
    }

    @Test func distanceDoesNotBridgeGaps() {
        let a = Fixtures.northbound(speeds: Array(repeating: 10, count: 6)) // 50 m
        // Second part starts 1 km further north, 30 s later.
        let b = Fixtures.northbound(
            speeds: Array(repeating: 10, count: 6), startMs: a.last!.timestampMs + 30_000,
            lat: a.last!.latitude + Geo.latitudeDegrees(forMeters: 1000)
        )
        let track = Track(fixes: a + b)
        #expect(track.segments == [0..<6, 6..<12])
        #expect(approx(track.totalDistance, 100, 1e-6))
    }
}

struct GapTests {
    @Test func gapsSplitSegmentsAndKeepRecordedReasons() {
        let a = Fixtures.northbound(speeds: Array(repeating: 10, count: 5))
        let b = Fixtures.shifted(a, byMs: 20_000)
        let c = Fixtures.shifted(a, byMs: 40_000)
        let f = a + b + c
        let track = Track(fixes: f)
        #expect(track.segments.count == 3)
        #expect(track.segmentOf[4] == 0 && track.segmentOf[5] == 1 && track.segmentOf[14] == 2)
        let recorded = [Gap(startMs: a[4].timestampMs, endMs: b[0].timestampMs, reason: .relaunch)]
        let gaps = track.gaps(recorded: recorded)
        #expect(gaps.count == 2)
        #expect(gaps[0] == Gap(startMs: a[4].timestampMs, endMs: b[0].timestampMs, reason: .relaunch))
        #expect(gaps[1].reason == .signal)
        #expect(approx(gaps[1].duration, 16))
    }

    @Test func fiveSecondsIsNotAGapButMoreIs() {
        let f = Fixtures.northbound(speeds: [10, 10], dt: 5)
        #expect(Track(fixes: f).segments.count == 1)
        let g = Fixtures.northbound(speeds: [10, 10], dt: 5.001)
        #expect(Track(fixes: g).segments.count == 2)
    }
}

struct TimeAndSpeedTests {
    /// 10 s at 10 m/s, 5 s standing, 10 s at 20 m/s (speeds are those of the fix ending each interval).
    static var profile: [Fix] {
        Fixtures.northbound(speeds: [10] + Array(repeating: 10, count: 10) + Array(repeating: 0, count: 5)
            + Array(repeating: 20, count: 10))
    }

    @Test func movingAndStoppedTime() {
        let t = TimeStats.compute(Track(fixes: Self.profile))
        #expect(approx(t.totalDuration, 25))
        #expect(approx(t.movingTime, 20))
        #expect(approx(t.stoppedTime, 5))
        #expect(t.gapTime == 0)
    }

    @Test func averagesMaxAndP85() {
        let analysis = TripAnalyzer.analyze(fixes: Self.profile)
        let s = analysis.statistics
        #expect(approx(s.distance, 300, 1e-6)) // 10 x 10 m + 10 x 20 m
        #expect(approx(s.speed.average, 12))     // 300 m / 25 s
        #expect(approx(s.speed.movingAverage, 15)) // 300 m / 20 s
        #expect(s.speed.max == 20)
        // Moving fix speeds: 11 x 10 and 10 x 20 = 21 values, rank ceil(0.85 * 21) = 18 -> 20.
        #expect(s.speed.p85 == 20)
    }

    @Test func p85NearestRank() {
        #expect(Quantile.nearestRank((1...20).map(Double.init), 0.85) == 17)
        #expect(Quantile.nearestRank([5], 0.85) == 5)
        #expect(Quantile.median([4, 1, 3, 2]) == 2.5)
        #expect(Quantile.median([3, 1, 2]) == 2)
        #expect(Quantile.nearestRank([], 0.5) == nil)
    }

    @Test func maxIgnoresInaccurateSpeeds() {
        var f = Fixtures.northbound(speeds: [10, 10, 30, 10])
        f[2].speedAccuracy = 2.5
        let s = TripAnalyzer.analyze(fixes: f).statistics
        #expect(s.speed.max == 10)
        f[2].speedAccuracy = nil // unknown accuracy counts
        #expect(TripAnalyzer.analyze(fixes: f).statistics.speed.max == 30)
    }

    @Test func histogramIsMovingSecondsPer10KmhBin() {
        // 4 s at 5 m/s (18 km/h, bin 10) and 3 s at 25 m/s (90 km/h, bin 90).
        let f = Fixtures.northbound(speeds: [5, 5, 5, 5, 5, 25, 25, 25])
        let h = TripAnalyzer.analyze(fixes: f).statistics.speed.histogram
        #expect(h.count == 10)
        #expect(h[1] == SpeedStats.Bin(lowerKmh: 10, seconds: 4))
        #expect(h[9] == SpeedStats.Bin(lowerKmh: 90, seconds: 3))
        #expect(h[0].seconds == 0 && h[5].seconds == 0)
    }

    @Test func missingSpeedFallsBackToDerivedSpeed() {
        var f = Fixtures.northbound(speeds: Array(repeating: 10, count: 4))
        for i in f.indices { f[i].speed = nil }
        let t = TimeStats.compute(Track(fixes: f))
        #expect(approx(t.movingTime, 3))
    }
}

struct StopTests {
    @Test func stopsStartStopEventsAndPerKm() {
        // moving 10 s, stop 5 s, moving 10 s, slow 2 s (too short), moving 5 s, stop 4 s at the end.
        let speeds: [Double] = [10] + Array(repeating: 10, count: 10) + Array(repeating: 0.5, count: 5)
            + Array(repeating: 10, count: 10) + [0, 0] + Array(repeating: 10, count: 5) + Array(repeating: 0, count: 4)
        let track = Track(fixes: Fixtures.northbound(speeds: speeds))
        let stops = StopStats.stops(track)
        #expect(stops.count == 2)
        #expect(stops[0].duration == 5 && stops[0].followedByMoving)
        #expect(stops[0].startIndex == 10)
        #expect(stops[1].duration == 4 && !stops[1].followedByMoving)
        let s = StopStats.compute(track, stops: stops)
        #expect(s.count == 2)
        #expect(s.totalTime == 9)
        #expect(s.longest == 5)
        #expect(s.startStopEvents == 1)
        // Distance: 25 moving seconds at 10 m/s = 250 m, plus the 5 x 0.5 m crept during the
        // first stop, credited once moving resumes: 252.5 m -> 1 event / 0.2525 km.
        #expect(approx(track.totalDistance, 252.5, 1e-6))
        #expect(approx(s.startStopPerKm, 1 / 0.2525))
    }

    @Test func threeSecondsIsAStop() {
        let three = Track(fixes: Fixtures.northbound(speeds: [10, 10, 0, 0, 0, 10]))
        #expect(StopStats.stops(three).count == 1)
        let two = Track(fixes: Fixtures.northbound(speeds: [10, 10, 0, 0, 10]))
        #expect(StopStats.stops(two).isEmpty)
    }
}

struct RoadTypeTests {
    static func kmh(_ v: Double) -> Double { v / 3.6 }

    @Test func steadySpeedsGiveOneClass() {
        for (speed, expected) in [(120.0, RoadClass.autobahn), (70, .land), (40, .stadt)] {
            let f = Fixtures.northbound(speeds: Array(repeating: Self.kmh(speed), count: 120))
            let classes = TripAnalyzer.analyze(fixes: f).roadClassPerFix
            #expect(classes.allSatisfy { $0 == expected })
        }
    }

    @Test func thresholdsAreInclusiveAtTheLowerBound() {
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(85), stopsInWindow: 0, windowDistance: 1000) == .autobahn)
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(84.9), stopsInWindow: 0, windowDistance: 1000) == .land)
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(50), stopsInWindow: 0, windowDistance: 1000) == .land)
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(49.9), stopsInWindow: 0, windowDistance: 1000) == .stadt)
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: nil, stopsInWindow: 0, windowDistance: 1000) == nil)
    }

    @Test func manyStopsPerKmMeanStadt() {
        // 2 stops in 0.6 km = 3.3 per km.
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(60), stopsInWindow: 2, windowDistance: 600) == .stadt)
        // 1 stop in 0.6 km = 1.7 per km.
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(60), stopsInWindow: 1, windowDistance: 600) == .land)
        // Exactly 2 per km is not more than 2.
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(60), stopsInWindow: 2, windowDistance: 1000) == .land)
        // Window too short to judge the rate.
        #expect(RoadTypeClassifier.candidateClass(medianSpeed: Self.kmh(60), stopsInWindow: 2, windowDistance: 200) == .land)
    }

    @Test func switchHappensOnlyAfterThirtySecondsOfTheNewClass() {
        // Fix k at second k: 110 km/h up to k = 120, then 70 km/h. At k = 150 the window is
        // half and half (median 90 km/h, still Autobahn). The median turns to 70 km/h at k = 151
        // (31 of 60 window fixes); the new class must hold 30 s, so Land replaces Autobahn at k = 181.
        let speeds = (0...240).map { $0 <= 120 ? Self.kmh(110) : Self.kmh(70) }
        let c = TripAnalyzer.analyze(fixes: Fixtures.northbound(speeds: speeds)).roadClassPerFix
        #expect(c[150] == .autobahn)
        #expect(c[180] == .autobahn)
        #expect(c[181] == .land)
        #expect(c[240] == .land)
    }

    @Test func shortDeviationDoesNotSwitch() {
        // 31 s at 30 km/h (k = 121...151) inside 100 km/h: the window median is 30 km/h only for
        // k = 151...180 (Stadt pending from 151), at k = 150 and 181 it is 65 km/h (Land), so no
        // candidate ever holds 30 s.
        let speeds = (0...300).map { (121...151).contains($0) ? Self.kmh(30) : Self.kmh(100) }
        let c = TripAnalyzer.analyze(fixes: Fixtures.northbound(speeds: speeds)).roadClassPerFix
        #expect(c.allSatisfy { $0 == .autobahn })
        // One second longer (k = 121...152): slow median at k = 151...181, Stadt at k = 181.
        let longer = (0...300).map { (121...152).contains($0) ? Self.kmh(30) : Self.kmh(100) }
        let d = TripAnalyzer.analyze(fixes: Fixtures.northbound(speeds: longer)).roadClassPerFix
        #expect(d[180] == .autobahn)
        #expect(d[181] == .stadt)
    }

    @Test func distanceAndTimePerClass() {
        let speeds = Array(repeating: Self.kmh(120), count: 61)
        let s = TripAnalyzer.analyze(fixes: Fixtures.northbound(speeds: speeds)).statistics.roadType
        #expect(approx(s.autobahn.time, 60))
        #expect(approx(s.autobahn.distance, 2000, 1e-6))
        #expect(s.stadt.distance == 0 && s.land.distance == 0)
        #expect(s.distanceShare(.autobahn) == 1)
    }
}

struct ElevationTests {
    static func fixes(_ altitudes: [Double]) -> [Fix] {
        altitudes.enumerated().map { k, a in
            Fix(timestampMs: Int64(k) * 1000, latitude: 1, longitude: 1, horizontalAccuracy: 3, altitude: a)
        }
    }

    @Test func gainAndLossWithThreeMeterHysteresis() {
        let e = ElevationStats.compute(Self.fixes([100, 101, 99, 100, 104, 108, 105, 103, 100]))
        #expect(e == ElevationStats(min: 99, max: 108, gain: 8, loss: 8))
    }

    @Test func noiseAddsNothing() {
        let e = ElevationStats.compute(Self.fixes([100, 101, 99, 101.9, 99, 100, 98.5]))
        #expect(e?.gain == 0 && e?.loss == 0)
        #expect(e?.min == 98.5 && e?.max == 101.9)
    }

    @Test func noAltitudeMeansNoElevation() {
        #expect(ElevationStats.compute([Fix(timestampMs: 0, latitude: 0, longitude: 0)]) == nil)
    }
}

struct DynamicsTests {
    @Test func hardAccelerationAndBrakingEvents() {
        // a = 0, +4, +4, 0, 0, -5, 0, 0 m/s².
        let f = Fixtures.northbound(speeds: [10, 10, 14, 18, 18, 18, 13, 13, 13])
        let d = DynamicsStats.compute(Track(fixes: f))
        #expect(d.hardAccelerations == 1)
        #expect(d.hardBrakings == 1)
        #expect(d.maxAcceleration == 4)
        #expect(d.maxDeceleration == -5)
    }

    @Test func pairsMoreThanTwoSecondsApartAreIgnored() {
        let f = Fixtures.northbound(speeds: [10, 22], dt: 3)
        let d = DynamicsStats.compute(Track(fixes: f))
        #expect(d.hardAccelerations == 0)
        #expect(d.maxAcceleration == nil)
        // Exactly 2 s apart counts: 8 m/s in 2 s = 4 m/s².
        let g = Fixtures.northbound(speeds: [10, 18], dt: 2)
        #expect(DynamicsStats.compute(Track(fixes: g)).hardAccelerations == 1)
    }

    @Test func thresholdIsExclusive() {
        let f = Fixtures.northbound(speeds: [10, 13, 10])
        let d = DynamicsStats.compute(Track(fixes: f))
        #expect(d.hardAccelerations == 0 && d.hardBrakings == 0)
    }
}

struct SunTests {
    /// Reference: PyEphem 4.x (VSOP87), geometric altitude without refraction (pressure 0),
    /// computed outside this repository. Tolerance 0.05°.
    static let cases: [(lat: Double, lon: Double, unix: Double, elevation: Double)] = [
        (48.1374, 11.5755, 1_782_039_600, 65.1081),   // Munich 2026-06-21 11:00 UTC
        (48.1374, 11.5755, 1_797_867_000, -1.8947),   // Munich 2026-12-21 15:30 UTC
        (32.7767, -96.7970, 1_774_029_600, 56.2780),  // Dallas 2026-03-20 18:00 UTC
        (32.7767, -96.7970, 1_794_439_800, -1.1746),  // Dallas 2026-11-11 23:30 UTC
        (32.7767, -96.7970, 1_794_384_000, -61.1334), // Dallas 2026-11-11 08:00 UTC
        (-33.8688, 151.2093, 1_736_906_400, 77.1928), // Sydney 2025-01-15 02:00 UTC
    ]

    @Test(arguments: 0..<6) func elevationMatchesReference(_ k: Int) {
        let c = Self.cases[k]
        let e = SunPosition.elevation(latitude: c.lat, longitude: c.lon, unixTime: c.unix)
        #expect(abs(e - c.elevation) < 0.05, "case \(k): \(e) vs \(c.elevation)")
    }

    @Test func dayAndNightShare() {
        // 10 minutes of driving in Dallas at 18:00 UTC (noon local): all day.
        let day = Fixtures.northbound(speeds: Array(repeating: 15, count: 601), startMs: 1_794_420_000_000)
        let d = DayNightStats.compute(Track(fixes: day))
        #expect(d.daySeconds == 600 && d.nightSeconds == 0 && d.dayShare == 1)
        // At 08:00 UTC (2 a.m. local): all night.
        let night = Fixtures.northbound(speeds: Array(repeating: 15, count: 601), startMs: 1_794_384_000_000)
        let n = DayNightStats.compute(Track(fixes: night))
        #expect(n.dayShare == 0)
    }
}

struct GPSQualityTests {
    @Test func qualityFigures() {
        var f = Fixtures.northbound(speeds: Array(repeating: 10, count: 6))
        for (i, a) in [3.0, 4, 5, 6, 40].enumerated() { f[i].horizontalAccuracy = a }
        f[5].horizontalAccuracy = nil
        f[1].isSimulatedBySoftware = true
        f[2].isProducedByAccessory = true
        let q = GPSQualityStats.compute(Track(fixes: f), gaps: [])
        #expect(q.fixCount == 6)
        #expect(q.meanRateHz == 1)
        #expect(q.medianAccuracy == 5)
        #expect(q.p95Accuracy == 40)
        #expect(q.percentPrecise == 60)
        #expect(q.percentAbove30 == 20)
        #expect(q.unknownAccuracyCount == 1)
        #expect(q.simulatedCount == 1 && q.accessoryCount == 1)
    }

    @Test func gapsAreCountedAndExcludedFromTheRate() {
        let a = Fixtures.northbound(speeds: Array(repeating: 10, count: 5))
        let b = Fixtures.shifted(a, byMs: 14_000) // 10 s gap after a's last fix
        let analysis = TripAnalyzer.analyze(fixes: a + b)
        let q = analysis.statistics.gps
        #expect(q.gapCount == 1)
        #expect(approx(q.gapTotal, 10))
        #expect(q.meanRateHz == 1)
        #expect(analysis.statistics.segmentCount == 2)
    }
}

struct PlacesTests {
    @Test func placesLocalitiesAndStreets() {
        // 0 to 300 s at 10 m/s: 3 km.
        let f = Fixtures.northbound(speeds: Array(repeating: 10, count: 301))
        func sample(_ s: Int, _ kind: PlaceSample.Kind, _ loc: String?, _ street: String?) -> PlaceSample {
            PlaceSample(timestampMs: f[s].timestampMs, latitude: f[s].latitude, longitude: f[s].longitude,
                        kind: kind, locality: loc, street: street)
        }
        let samples = [
            sample(0, .start, "Dallas", "Main Street"),
            sample(100, .moving, "Dallas", "Elm Street"),
            sample(200, .moving, "Irving", "Main Street"),
            sample(300, .end, "Dallas", "Elm Street"),
        ]
        let p = PlacesSummary.compute(samples: samples, track: Track(fixes: f))
        #expect(p.startPlace == "Dallas")
        #expect(p.endPlace == "Dallas")
        #expect(p.localities == ["Dallas", "Irving", "Dallas"])
        #expect(p.streets.map(\.name) == ["Main Street", "Elm Street"])
        #expect(approx(p.streets[0].distance, 2000, 1e-6))
        #expect(approx(p.streets[1].distance, 1000, 1e-6))
    }

    @Test func samplerNeedsMovementTimeAndDistance() {
        let f = Fixtures.northbound(speeds: [20])[0]
        #expect(GeocodeSampler.shouldSample(fix: f, last: nil))
        var stopped = f
        stopped.speed = 0
        #expect(!GeocodeSampler.shouldSample(fix: stopped, last: nil))

        let last = PlaceSample(timestampMs: f.timestampMs - 61_000, latitude: f.latitude - Geo.latitudeDegrees(forMeters: 1200),
                               longitude: f.longitude, kind: .moving)
        #expect(GeocodeSampler.shouldSample(fix: f, last: last))
        var recent = last
        recent.timestampMs = f.timestampMs - 30_000
        #expect(!GeocodeSampler.shouldSample(fix: f, last: recent))
        var near = last
        near.latitude = f.latitude - Geo.latitudeDegrees(forMeters: 500)
        #expect(!GeocodeSampler.shouldSample(fix: f, last: near))
    }

    @Test func tripTitleFromPlaces() {
        var r = TripRecord(startedAt: Date())
        #expect(r.placeTitle == nil)
        r.places = [PlaceSample(timestampMs: 0, latitude: 0, longitude: 0, kind: .start, locality: "Plano"),
                    PlaceSample(timestampMs: 1, latitude: 0, longitude: 0, kind: .end, locality: "Frisco")]
        #expect(r.placeTitle == "Plano nach Frisco")
    }
}
