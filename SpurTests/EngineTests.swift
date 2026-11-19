import CoreLocation
import Foundation
import Testing
import UIKit
@testable import Spur

/// Records every call the engine makes on Core Location.
final class FakeLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var showsBackgroundLocationIndicator = false
    var allowsBackgroundLocationUpdates = false
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization
    var location: CLLocation?

    var whenInUseRequests = 0
    var alwaysRequests = 0
    var fullAccuracyRequests = 0
    var startUpdating = 0
    var stopUpdating = 0
    var startSignificant = 0
    var stopSignificant = 0

    init(status: CLAuthorizationStatus = .authorizedWhenInUse, accuracy: CLAccuracyAuthorization = .fullAccuracy) {
        authorizationStatus = status
        accuracyAuthorization = accuracy
    }

    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String) { fullAccuracyRequests += 1 }
    func startUpdatingLocation() { startUpdating += 1 }
    func stopUpdatingLocation() { stopUpdating += 1 }
    func startMonitoringSignificantLocationChanges() { startSignificant += 1 }
    func stopMonitoringSignificantLocationChanges() { stopSignificant += 1 }
}

final class FakeSession: BackgroundSessioning {
    var invalidated = false
    func invalidate() { invalidated = true }
}

struct EngineTests {
    struct Rig {
        var engine: RecordingEngine
        var manager: FakeLocationManager
        var store: TripStore
        var defaults: UserDefaults
        var sessions: SessionLog
    }

    final class SessionLog {
        var made: [FakeSession] = []
    }

    static func rig(
        status: CLAuthorizationStatus = .authorizedWhenInUse, accuracy: CLAccuracyAuthorization = .fullAccuracy,
        store: TripStore = TripStore(root: Fixtures.tempDir())
    ) -> Rig {
        let defaults = UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.geocodingEnabled = false
        settings.keepScreenAwake = false
        let manager = FakeLocationManager(status: status, accuracy: accuracy)
        let log = SessionLog()
        let engine = RecordingEngine(store: store, settings: settings, manager: manager,
                                     makeSession: { let s = FakeSession(); log.made.append(s); return s }, defaults: defaults)
        return Rig(engine: engine, manager: manager, store: store, defaults: defaults, sessions: log)
    }

    /// Fixes timestamped from now on, so the engine accepts them as new.
    static func freshFixes(_ count: Int) -> [Fix] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Fixtures.northbound(speeds: Array(repeating: 15, count: count), startMs: now)
    }

    static func waitUntilIdle(_ engine: RecordingEngine) async throws {
        for _ in 0..<300 where engine.phase != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.phase == .idle)
    }

    // MARK: Authorization changes mid-trip

    @Test func revokedAccessKeepsTheTripAndAGrantRestartsUpdates() {
        let r = Self.rig()
        r.engine.requestStart()
        #expect(r.engine.phase == .recording)
        #expect(r.manager.startUpdating == 1 && r.manager.startSignificant == 1)
        let id = r.engine.trip!.id

        r.engine.authorizationChanged(.denied, .fullAccuracy)
        #expect(r.engine.phase == .recording)
        #expect(r.engine.isDenied)
        #expect(r.defaults.string(forKey: RecordingEngine.recordingKey) == id.uuidString)
        #expect(r.manager.startUpdating == 1)

        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(!r.engine.isDenied)
        #expect(r.manager.startUpdating == 2)
        // A plain accuracy notification while access is fine does not restart again.
        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(r.manager.startUpdating == 2)
    }

    @Test func contextRecordsTheBestAuthorizationSeenDuringTheTrip() throws {
        let r = Self.rig(status: .authorizedWhenInUse, accuracy: .reducedAccuracy)
        r.engine.requestStart()
        #expect(r.engine.trip?.context.accuracyAuthorization == .reduced)
        #expect(r.engine.trip?.context.authorization == .whenInUse)
        #expect(r.manager.fullAccuracyRequests == 1)

        // The temporary full-accuracy prompt is granted, later "Immer".
        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(r.engine.trip?.context.accuracyAuthorization == .full)
        r.engine.authorizationChanged(.authorizedAlways, .fullAccuracy)
        #expect(r.engine.trip?.context.authorization == .always)
        // A later drop does not erase what the trip was recorded with.
        r.engine.authorizationChanged(.authorizedWhenInUse, .reducedAccuracy)
        #expect(r.engine.trip?.context.authorization == .always)
        #expect(r.engine.trip?.context.accuracyAuthorization == .full)
    }

    @Test func alwaysIsRequestedOnlyOnce() {
        let r = Self.rig()
        #expect(r.engine.requestAlways())
        #expect(!r.engine.requestAlways())
        #expect(r.manager.alwaysRequests == 1)
    }

    // MARK: Resume

    @Test func significantChangesStopWhenNoTripResumes() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let stale = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date().addingTimeInterval(-2 * 3600))
        let r = Self.rig(store: store)
        r.defaults.set(stale.id.uuidString, forKey: RecordingEngine.recordingKey)

        #expect(r.engine.resumeIfNeeded() == nil)
        #expect(r.manager.stopSignificant == 1)
        #expect(r.manager.startUpdating == 0)
        #expect(r.defaults.string(forKey: RecordingEngine.recordingKey) == nil)
        #expect(r.engine.notice == "Letzte Fahrt wurde beendet")
        #expect(try store.load(stale.id).isRecording == false)
    }

    @Test func freshTripResumesWithARelaunchGap() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let fresh = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date().addingTimeInterval(-20))
        let r = Self.rig(store: store)
        r.defaults.set(fresh.id.uuidString, forKey: RecordingEngine.recordingKey)

        #expect(r.engine.resumeIfNeeded() == fresh.id)
        #expect(r.engine.phase == .recording)
        #expect(r.manager.startUpdating == 1 && r.manager.stopSignificant == 0)
        r.engine.handle(Self.freshFixes(3))
        #expect(r.engine.trip?.gaps.last?.reason == .relaunch)
        #expect(r.engine.fixes.count == 33)
    }

    // MARK: Errors and the empty stop

    @Test func lastErrorClearsOnTheNextGoodStartAndCanBeDismissed() throws {
        let base = Fixtures.tempDir()
        let root = base.appendingPathComponent("Trips")
        // A file where the trips folder should be: creating a trip fails.
        try Data("x".utf8).write(to: root)
        let r = Self.rig(store: TripStore(root: root))
        r.engine.requestStart()
        #expect(r.engine.phase == .idle)
        #expect(r.engine.lastError != nil)
        r.engine.dismissError()
        #expect(r.engine.lastError == nil)

        r.engine.requestStart()
        #expect(r.engine.lastError != nil)
        try FileManager.default.removeItem(at: root)
        r.engine.requestStart()
        #expect(r.engine.phase == .recording)
        #expect(r.engine.lastError == nil)
    }

    @Test func stoppingWithoutPositionsDiscardsTheTripWithoutASummary() async throws {
        let r = Self.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        r.engine.handle(Self.freshFixes(1))
        r.engine.stop()
        try await Self.waitUntilIdle(r.engine)
        #expect(r.engine.finishedTrip == nil)
        #expect(r.engine.notice == "Keine Positionen, Fahrt verworfen")
        #expect((try? r.store.load(id)) == nil)
        #expect(r.manager.stopSignificant == 1 && r.manager.stopUpdating == 1)
    }

    @Test func stoppingATripSavesItAndOpensTheSummary() async throws {
        let r = Self.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        r.engine.handle(Self.freshFixes(20))
        r.engine.stop()
        // The finished state is on disk before the statistics.
        #expect(try r.store.load(id).isRecording == false)
        try await Self.waitUntilIdle(r.engine)
        #expect(r.engine.finishedTrip?.id == id)
        #expect(approx(try r.store.load(id).statistics?.distance, 19 * 15, 1e-6))
    }

    @Test func lowBatteryWarnsOnlyWhenNotCharging() {
        #expect(RecordingEngine.showsLowBattery(level: 0.12, state: .unplugged))
        #expect(!RecordingEngine.showsLowBattery(level: 0.12, state: .charging))
        #expect(!RecordingEngine.showsLowBattery(level: 0.12, state: .full))
        #expect(!RecordingEngine.showsLowBattery(level: 0.15, state: .unplugged))
        #expect(!RecordingEngine.showsLowBattery(level: nil, state: .unplugged))
    }

    // MARK: Review 2

    @Test func reGrantKeepsTheBackgroundSession() {
        let r = Self.rig()
        r.engine.requestStart()
        #expect(r.sessions.made.count == 1)
        r.engine.authorizationChanged(.denied, .fullAccuracy)
        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(r.manager.startUpdating == 2)
        #expect(r.sessions.made.count == 1)
        #expect(r.sessions.made[0].invalidated == false)
    }

    @Test func resumeWithoutAccessAsksWhenActiveAndRestartsOnGrant() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let fresh = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date().addingTimeInterval(-20))
        let r = Self.rig(status: .notDetermined, store: store)
        r.defaults.set(fresh.id.uuidString, forKey: RecordingEngine.recordingKey)
        #expect(r.engine.resumeIfNeeded() == fresh.id)
        #expect(r.engine.isPausedForAccess)
        #expect(r.manager.whenInUseRequests == 0) // not while launching

        r.engine.appNotification(UIApplication.didBecomeActiveNotification)
        #expect(r.manager.whenInUseRequests == 1)

        r.manager.authorizationStatus = .authorizedWhenInUse
        r.engine.authorizationChanged(.authorizedWhenInUse, .fullAccuracy)
        #expect(!r.engine.isPausedForAccess)
        #expect(r.manager.startUpdating == 2)
        #expect(r.sessions.made.count == 1)
    }

    @Test func aGeocodeArrivingWhileStoppingIsKept() async throws {
        let r = Self.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        let fixes = Self.freshFixes(20)
        r.engine.handle(fixes)
        r.engine.stop()
        #expect(r.engine.phase == .stopping)
        let sample = PlaceSample(timestampMs: fixes[5].timestampMs, latitude: fixes[5].latitude, longitude: fixes[5].longitude,
                                 kind: .moving, locality: "Dallas", street: "Elm St")
        await r.engine.didGeocode(sample, tripId: id)
        try await Self.waitUntilIdle(r.engine)
        let saved = try r.store.load(id)
        #expect(saved.places.contains(sample))
        #expect(saved.statistics?.places.streets.map(\.name) == ["Elm St"])

        // After the stop, a late result goes into the saved trip.
        let late = PlaceSample(timestampMs: fixes[19].timestampMs, latitude: 0, longitude: 0, kind: .end, locality: "Irving")
        await r.engine.didGeocode(late, tripId: id)
        let updated = try r.store.load(id)
        #expect(updated.places.last == late)
        #expect(updated.statistics?.places.endPlace == "Irving")
        #expect(updated.statistics?.distance == saved.statistics?.distance)
    }

    @Test func aTripWhoseFileCannotReopenIsClosedNotLeftOpen() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let fresh = try TripLifecycleTests.recordingTrip(in: store, lastFixAt: Date().addingTimeInterval(-10))
        // A folder where the fix file should be: it cannot be opened for appending.
        let url = store.fixesURL(fresh.id)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let r = Self.rig(store: store)
        r.defaults.set(fresh.id.uuidString, forKey: RecordingEngine.recordingKey)

        #expect(r.engine.resumeIfNeeded() == nil)
        #expect(r.engine.phase == .idle)
        #expect(try store.load(fresh.id).isRecording == false)
        #expect(r.defaults.string(forKey: RecordingEngine.recordingKey) == nil)
        #expect(r.manager.stopSignificant == 1)
        #expect(r.engine.notice == "Letzte Fahrt wurde beendet")
    }

    @Test func aNewTripClearsTheDiscardNotice() async throws {
        let r = Self.rig()
        r.engine.requestStart()
        r.engine.stop()
        try await Self.waitUntilIdle(r.engine)
        #expect(r.engine.notice == "Keine Positionen, Fahrt verworfen")
        #expect(r.engine.noticeIsWarning)
        r.engine.requestStart()
        #expect(r.engine.notice == nil)
    }
}
