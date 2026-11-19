import CoreLocation
import Foundation
import Testing
import UIKit
@testable import Spur

/// SPEC 14.1: position accuracy.
struct AccuracyTests {
    // MARK: 1. The recording configuration is unchanged

    static func expectRecordingConfiguration(_ m: FakeLocationManager) {
        #expect(m.desiredAccuracy == kCLLocationAccuracyBestForNavigation)
        #expect(m.distanceFilter == kCLDistanceFilterNone)
        #expect(m.activityType == .automotiveNavigation)
        #expect(m.pausesLocationUpdatesAutomatically == false)
        #expect(m.allowsBackgroundLocationUpdates == true)
        #expect(m.showsBackgroundLocationIndicator == true)
    }

    @Test func aStartedTripUsesTheFullPrecisionConfiguration() {
        let r = EngineTests.rig(status: .authorizedWhenInUse, accuracy: .fullAccuracy)
        r.engine.requestStart()
        #expect(r.engine.phase == .recording)
        Self.expectRecordingConfiguration(r.manager)
        #expect(r.manager.startUpdating == 1)
        #expect(r.manager.fullAccuracyRequests == 0)
    }

    @Test func reducedAccuracyAsksForTemporaryFullAccuracy() {
        let r = EngineTests.rig(status: .authorizedAlways, accuracy: .reducedAccuracy)
        r.engine.requestStart()
        Self.expectRecordingConfiguration(r.manager)
        #expect(r.manager.fullAccuracyRequests == 1)
    }

    @Test func aResumedTripUsesTheSameConfiguration() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let first = EngineTests.rig(store: store)
        first.engine.requestStart()
        first.engine.handle(EngineTests.freshFixes(3))
        let id = try #require(first.engine.trip?.id)

        let second = EngineTests.rig(store: store)
        second.defaults.set(id.uuidString, forKey: RecordingEngine.recordingKey)
        #expect(second.engine.resumeIfNeeded() == id)
        Self.expectRecordingConfiguration(second.manager)
    }

    @Test func aWarmUpBeforeTheTripDoesNotChangeTheRecordingConfiguration() {
        let r = EngineTests.rig()
        r.engine.warmUpWanted = true
        #expect(r.manager.allowsBackgroundLocationUpdates == false)
        r.engine.requestStart()
        Self.expectRecordingConfiguration(r.manager)
        // The warm-up's updates were handed over, not stopped and restarted.
        #expect(r.manager.stopUpdating == 0)
    }

    // MARK: 2. Warm-up

    @Test func warmUpRunsForegroundOnlyAndStoresNothing() throws {
        let r = EngineTests.rig()
        r.engine.warmUpWanted = true
        #expect(r.engine.isWarmingUp)
        #expect(r.manager.startUpdating == 1)
        #expect(r.manager.allowsBackgroundLocationUpdates == false)
        #expect(r.manager.startSignificant == 0)
        #expect(r.sessions.made.isEmpty)
        #expect(r.manager.desiredAccuracy == kCLLocationAccuracyBestForNavigation)

        r.engine.handle(EngineTests.freshFixes(3))
        #expect(r.engine.warmFix != nil)
        #expect(r.engine.trip == nil)
        #expect(r.engine.fixes.isEmpty)
        try r.store.ensureRoot()
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.store.root.path).isEmpty)

        r.engine.warmUpWanted = false
        #expect(!r.engine.isWarmingUp)
        #expect(r.manager.stopUpdating == 1)
        #expect(r.engine.warmFix == nil)
    }

    @Test func warmUpNeverAsksForPermission() {
        let r = EngineTests.rig(status: .notDetermined)
        r.engine.warmUpWanted = true
        #expect(!r.engine.isWarmingUp)
        #expect(r.manager.startUpdating == 0)
        #expect(r.manager.whenInUseRequests == 0)
        // Access granted later while the tab is still visible: the warm-up starts.
        r.manager.authorizationStatus = .authorizedWhenInUse
        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(r.engine.isWarmingUp)
    }

    @Test func warmUpStopsInTheBackgroundAndResumesInTheForeground() {
        let r = EngineTests.rig()
        r.engine.warmUpWanted = true
        r.engine.appNotification(UIApplication.didEnterBackgroundNotification)
        #expect(!r.engine.isWarmingUp)
        #expect(r.manager.stopUpdating == 1)
        r.engine.appNotification(UIApplication.willEnterForegroundNotification)
        #expect(r.engine.isWarmingUp)
        #expect(r.manager.startUpdating == 2)
    }

    @Test func warmUpComesBackAfterATripWhileTheTabIsVisible() async throws {
        let r = EngineTests.rig()
        r.engine.warmUpWanted = true
        r.engine.requestStart()
        #expect(!r.engine.isWarmingUp)
        r.engine.handle(EngineTests.freshFixes(5))
        r.engine.stop()
        try await EngineTests.waitUntilIdle(r.engine)
        #expect(r.engine.isWarmingUp)
        #expect(r.manager.allowsBackgroundLocationUpdates == false)
        #expect(r.manager.startSignificant == 1) // only the trip's
    }

    // MARK: 3. Precision banner

    static func feed(_ m: inout PrecisionMonitor, from t0: Double, seconds: Int, accuracy: Double) -> [Double?] {
        var out: [Double?] = []
        for k in 0..<seconds {
            let t = t0 + Double(k)
            m.add(time: t, accuracy: accuracy)
            out.append(m.evaluate(now: t))
        }
        return out
    }

    @Test func precisionBannerNeedsThirtySecondsOfPoorMedian() {
        var m = PrecisionMonitor()
        let good = Self.feed(&m, from: 0, seconds: 40, accuracy: 4)
        #expect(good.allSatisfy { $0 == nil })
        // From t = 40 every fix is 18 m. The 30 s median crosses 15 m once more than half of the
        // window is poor (t = 55), and the banner is due 30 s after that.
        let poor = Self.feed(&m, from: 40, seconds: 60, accuracy: 18)
        let firstBanner = poor.firstIndex { $0 != nil }.map { 40 + $0 }
        #expect(firstBanner == 85)
        #expect(poor.last! == 18)
        // Recovery: the banner clears at the first evaluation with a median of 15 m or better.
        let recovered = Self.feed(&m, from: 100, seconds: 40, accuracy: 5)
        let clearedAt = recovered.firstIndex { $0 == nil }.map { 100 + $0 }
        #expect(clearedAt == 114)
        #expect(recovered.last! == nil)
    }

    @Test func aShortPoorSpellShowsNoBanner() {
        var m = PrecisionMonitor()
        _ = Self.feed(&m, from: 0, seconds: 30, accuracy: 4)
        let spell = Self.feed(&m, from: 30, seconds: 25, accuracy: 25)
        // The 30 s median is above 15 m from t = 45 and recovers at t = 69 (15 good fixes in the
        // window again): 24 s, short of the 30 s hold.
        #expect(spell.allSatisfy { $0 == nil })
        let after = Self.feed(&m, from: 55, seconds: 30, accuracy: 4)
        #expect(after.allSatisfy { $0 == nil })
    }

    @Test func fixesWithoutAccuracyDoNotEnterTheMedian() {
        var m = PrecisionMonitor()
        for k in 0..<70 {
            m.add(time: Double(k), accuracy: k % 2 == 0 ? 20 : nil)
            m.evaluate(now: Double(k))
        }
        #expect(m.median == 20)
        #expect(m.evaluate(now: 69) == 20)
    }

    @Test func theEngineRaisesAndClearsTheBanner() {
        let r = EngineTests.rig()
        r.engine.requestStart()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var poor = Fixtures.northbound(speeds: Array(repeating: 15, count: 70), startMs: now, accuracy: 22)
        for k in poor.indices {
            r.engine.handle([poor[k]])
            r.engine.forcePublishForTesting()
        }
        #expect(r.engine.poorAccuracy == 22)
        poor = Fixtures.northbound(speeds: Array(repeating: 15, count: 20), startMs: now + 70_000, accuracy: 4)
        for f in poor {
            r.engine.handle([f])
            r.engine.forcePublishForTesting()
        }
        #expect(r.engine.poorAccuracy == nil)
    }

    // MARK: 4. GPS quality shares

    @Test func gpsQualityHasTheFiveAndTenMeterSharesAndTheAccessoryShare() {
        var fixes = Fixtures.northbound(speeds: Array(repeating: 10, count: 10))
        let accuracies: [Double] = [3, 5, 6, 10, 11, 4, 9, 30, 31, 2]
        for k in fixes.indices {
            fixes[k].horizontalAccuracy = accuracies[k]
            fixes[k].isProducedByAccessory = k < 4
        }
        let g = GPSQualityStats.compute(Track(fixes: fixes, config: .default), gaps: [])
        #expect(approx(g.percentPrecise, 40))   // 3, 5, 4, 2
        #expect(approx(g.percentWithin10, 70))  // plus 6, 10, 9
        #expect(approx(g.percentAbove30, 10))   // 31
        #expect(g.accessoryCount == 4)
        #expect(approx(g.accessoryShare, 0.4))
    }

    @Test func aGpsBlockWithoutTheTenMeterShareStillDecodes() throws {
        let json = #"{"fixCount":3,"unknownAccuracyCount":0,"gapCount":0,"gapTotal":0,"simulatedCount":0,"accessoryCount":0}"#
        let g = try JSONDecoder().decode(GPSQualityStats.self, from: Data(json.utf8))
        #expect(g.percentWithin10 == nil)
        #expect(g.accessoryShare == 0)
    }
}
