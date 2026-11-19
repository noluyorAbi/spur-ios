import CoreLocation
import os
import Foundation
import Observation
import UIKit

/// What the live HUD reads. Published at most twice per second.
struct LiveSnapshot: Equatable {
    var revision = 0
    var lastFix: Fix?
    var distance: Double = 0
    var movingTime: Double = 0
    var fixCount = 0
    var roadNow: RoadClass?
    /// Course of the last fix, else the bearing of the recent trail.
    var heading: Double?
}

/// The parts of `CLLocationManager` the engine uses, so tests can drive it with a fake.
protocol LocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var activityType: CLActivityType { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    /// The most recent position Core Location has, possibly cached.
    var location: CLLocation? { get }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String)
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
}

extension CLLocationManager: LocationManaging {}

/// A held background activity session (`CLBackgroundActivitySession`).
protocol BackgroundSessioning: AnyObject {
    func invalidate()
}

extension CLBackgroundActivitySession: BackgroundSessioning {}

/// The recording core (SPEC section 4): Core Location setup, background session, the fix file,
/// gaps, resume after termination, geocoding samples and the live state.
///
/// The location callback does minimal work: append each fix to the file with one write, update
/// the incremental counters, and publish a throttled snapshot.
@Observable
final class RecordingEngine: NSObject {
    enum Phase: Equatable { case idle, awaitingPermission, recording, stopping }

    static let recordingKey = "recording.tripId"
    private static let log = Logger(subsystem: "dev.adatepe.spur", category: "engine")
    static let fullAccuracyPurposeKey = "TripRecording"

    private(set) var phase: Phase = .idle
    private(set) var authorization: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    /// The trip being recorded.
    private(set) var trip: TripRecord?
    /// What the screen shows of the running trip. While the scene is in the background it holds still
    /// (17.4b: SwiftUI otherwise re-renders the live screen on every fix in the background);
    /// `current` keeps the truth for recording, the Live Activity and the road accounting, and
    /// becoming active copies it over in one assignment.
    private(set) var live = LiveSnapshot()
    @ObservationIgnored private(set) var current = LiveSnapshot() { didSet { show() } }
    @ObservationIgnored private(set) var displayActive = true
    /// Assignments to the observed live state (tests: none while the display is inactive).
    @ObservationIgnored private(set) var displayMutations = 0
    private(set) var events: [TripEvent] = []
    /// The most recent gap of the running trip, for the "resumed after a gap" banner.
    private(set) var lastGap: Gap?
    /// Battery level 0 to 1, nil when unknown (simulator).
    private(set) var batteryLevel: Float?
    private(set) var lastError: String?
    /// Battery state, to warn only when the phone is not charging.
    private(set) var batteryState: UIDevice.BatteryState = .unknown
    /// The low battery banner was closed during this trip.
    var batteryWarningDismissed = false
    /// A one-time notice, for example after a stale trip was finalized at launch.
    var notice: String?
    /// True when the notice reports something that did not go as intended (shown as a warning).
    var noticeIsWarning = false
    /// The trip that just finished, for the summary sheet.
    var finishedTrip: TripRecord?
    /// Called on the main actor after a trip was finished and saved.
    @ObservationIgnored var onTripChanged: (() -> Void)?
    /// Road data hooks (SPEC 14): a trip starts or resumes, fixes were stored, a kept trip finished.
    /// They must stay cheap; the road service does its work off the main actor.
    @ObservationIgnored var onTripStarted: (() -> Void)?
    @ObservationIgnored var onFixesRecorded: (([Fix]) -> Void)?
    @ObservationIgnored var onTripStopped: (() -> Void)?
    @ObservationIgnored var onTripFinished: ((UUID) -> Void)?
    /// The latest position of the warm-up before Start (SPEC 14.1), for the GPS chip. Never stored.
    private(set) var warmFix: Fix?
    /// True while the foreground-only warm-up updates run.
    private(set) var isWarmingUp = false
    /// Set by the UI: the Fahrt tab is visible and the app is active. The engine warms up GPS only
    /// while this holds, nothing is recording and access is granted.
    @ObservationIgnored var warmUpWanted = false { didSet { refreshWarmUp() } }
    /// The median accuracy to show in the "Ungenaue Position" banner, nil when none is due.
    private(set) var poorAccuracy: Double?
    @ObservationIgnored private(set) var currentPoorAccuracy: Double? { didSet { show() } }

    /// All fixes of the running trip, in memory for the trail. Not observed: views follow `live.revision`.
    @ObservationIgnored private(set) var fixes: [Fix] = []

    @ObservationIgnored let store: TripStore
    @ObservationIgnored let settings: Settings
    @ObservationIgnored private let manager: LocationManaging
    @ObservationIgnored private let makeSession: () -> BackgroundSessioning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var session: BackgroundSessioning?
    /// True after access was revoked during the trip, until it comes back.
    @ObservationIgnored private var accessLost = false
    @ObservationIgnored private var writer: FixFileWriter?
    @ObservationIgnored private var accumulator = LiveAccumulator()
    @ObservationIgnored private var pendingGapReason: Gap.Reason?
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var backgroundSinceLastFix = false
    @ObservationIgnored private var metaDirty = false
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var lastRoadEvaluation = Date.distantPast
    @ObservationIgnored private var lastSync = Date.distantPast
    @ObservationIgnored private var lastGeocodeAttempt = Date.distantPast
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private let geocoder = PlaceGeocoder()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startWhenAuthorized = false
    @ObservationIgnored private var precision = PrecisionMonitor()
    @ObservationIgnored private var lastWarmPublish = Date.distantPast
    /// The motion samples of the running trip (SPEC 16.3.1), written off the main actor.
    @ObservationIgnored let motion = MotionRecorder()
    /// The live estimator's feed (SPEC 17.4), forked from `motion`'s batches and fed the fixes.
    @ObservationIgnored let liveMotion = LiveMotionFeed()
    /// The live roads' moving time per speed-limit sign state, saved with the stopped trip.
    @ObservationIgnored var speedLimitSeconds: (() -> [String: Double])?
    /// What earlier runs of the resumed trip recorded about motion problems.
    @ObservationIgnored private var motionHealthBase: MotionHealth?
    /// Makes the motion source for a trip; nil when the device has none.
    @ObservationIgnored private let makeMotionSource: () -> MotionSource?
    /// The automatic pause (SPEC 18.9), from the location only: the detector fed per fix, and
    /// where the car of the current stop stands, looked up once per stop from cached road data.
    @ObservationIgnored private var breaks = BreakDetector()
    /// Set by the app: the place at a position from the road data on the phone (no network).
    @ObservationIgnored var placeLookup: ((LatLon) async -> BreakDetector.Place)?
    @ObservationIgnored private var stopPlace: BreakDetector.Place?
    @ObservationIgnored private var placeAskedFor: Double?
    /// Debug and tests: every stop stands at this place instead of looking it up.
    @ObservationIgnored var placeOverride: BreakDetector.Place?

    init(
        store: TripStore, settings: Settings,
        manager: LocationManaging = CLLocationManager(),
        makeSession: @escaping () -> BackgroundSessioning = { CLBackgroundActivitySession() },
        defaults: UserDefaults = .standard,
        makeMotionSource: (() -> MotionSource?)? = nil
    ) {
        self.makeMotionSource = makeMotionSource ?? { RecordingEngine.defaultMotionSource() }
        self.store = store
        self.settings = settings
        self.manager = manager
        self.makeSession = makeSession
        self.defaults = defaults
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        motion.live = liveMotion
        let recorder = motion
        liveMotion.onActiveChanged = { recorder.setFastBatches($0) }
        motion.onProblem = { [weak self] text in
            Task { @MainActor in
                self?.notice = text
                self?.noticeIsWarning = true
            }
        }
        manager.delegate = self
        configureManager()
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        observeApp()
    }

    /// CoreMotion on a device; in a Debug simulator run with `-SpurSynthMotion YES`, motion
    /// derived from the fixes (the simulator has no motion hardware).
    static func defaultMotionSource() -> MotionSource? {
        #if DEBUG
        if AppEnvironment.synthMotion { return SyntheticMotionSource() }
        #endif
        let source = CoreMotionSource()
        return source.isAvailable ? source : nil
    }

    /// Starts writing the trip's motion when the setting allows it; appends after a resume (at the
    /// rate already in the file).
    private func startMotion(_ id: UUID) {
        motionHealthBase = trip?.motionHealth
        // The first start of a trip records how motion stood (a resume keeps it).
        func note(_ m: TripRecord.MotionStart) {
            guard trip?.motionStart == nil else { return }
            trip?.motionStart = m
            if let t = trip { try? store.save(t) }
        }
        guard settings.recordMotion else { return note(.off) }
        guard let source = makeMotionSource() else { return note(.unavailable) }
        if motion.start(url: store.motionURL(id), rateHz: settings.motionRateHz, source: source) {
            liveMotion.begin(url: store.motionURL(id), fixes: fixes)
            note(.recording)
        } else {
            note(source.isAvailable ? .failed : .unavailable)
        }
    }

    /// The motion setting changed: turned off during a trip, motion stops at once (the person
    /// does not want it recorded); turned on, it starts with the next trip.
    func applyMotionSetting() {
        if !settings.recordMotion, motion.isRecording {
            motion.stop()
            liveMotion.end()
        }
    }

    /// The recorder's account so far, on top of what an earlier run of this trip recorded.
    private func motionHealthNow() -> MotionHealth? {
        let now = motion.currentHealth
        var total = motionHealthBase ?? MotionHealth()
        total.restarts += now.restarts
        total.writeFailures += now.writeFailures
        total.openFailed = total.openFailed || now.openFailed
        total.gaveUp = total.gaveUp || now.gaveUp
        return total.isClean ? nil : total
    }

    static func thermalName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func configureManager() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    /// Whether a Live Activity of the trip is live (SPEC 4 as amended for 16.4). The blue
    /// background-location pill would push it to the island's smallest form; with Always access
    /// the activity itself shows that Spur records, so the pill is switched off while it is live.
    /// In every other case the pill stays (under When In Use iOS shows it regardless).
    private(set) var liveActivityShown = false

    func setLiveActivityShown(_ live: Bool) {
        liveActivityShown = live
        applyLocationIndicator()
    }

    private func applyLocationIndicator() {
        let hide = liveActivityShown && authorization == .authorizedAlways
        if manager.showsBackgroundLocationIndicator == hide {
            manager.showsBackgroundLocationIndicator = !hide
            Self.log.info("background location indicator \(hide ? "off" : "on", privacy: .public) (activity live: \(self.liveActivityShown), always: \(self.authorization == .authorizedAlways))")
        }
    }

    var isRecording: Bool { phase == .recording }
    /// The best known position for "Gebiet vorladen": the trip's, the warm-up's, else Core Location's cache.
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        (current.lastFix ?? warmFix)?.coordinate ?? manager.location?.coordinate
    }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    /// A trip is open but nothing can be recorded: access denied, restricted or not determined.
    var isPausedForAccess: Bool { phase == .recording && (isDenied || authorization == .notDetermined) }
    var isReducedAccuracy: Bool { accuracyAuthorization == .reducedAccuracy }
    var hasAlways: Bool { authorization == .authorizedAlways }

    /// The low battery banner: below 15 % and not charging (SPEC 7.1).
    static func showsLowBattery(level: Float?, state: UIDevice.BatteryState) -> Bool {
        guard let level else { return false }
        return level < 0.15 && state == .unplugged
    }

    var showsLowBatteryWarning: Bool {
        !batteryWarningDismissed && Self.showsLowBattery(level: batteryLevel, state: batteryState)
    }

    func dismissError() { lastError = nil }

    // MARK: Start

    /// Starts a new trip. Asks for "Beim Verwenden" on the first start.
    func requestStart() {
        guard phase == .idle else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            startWhenAuthorized = true
            phase = .awaitingPermission
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginNewTrip()
        default:
            authorization = manager.authorizationStatus
        }
    }

    /// Offers the upgrade to "Immer". iOS shows that prompt only once per install, so after the
    /// first request this returns false and the caller opens the iOS settings instead.
    @discardableResult
    func requestAlways() -> Bool {
        guard !settings.alwaysRequested else { return false }
        settings.alwaysRequested = true
        manager.requestAlwaysAuthorization()
        return true
    }

    /// Asks for temporary full accuracy when "Genaue Position" is off.
    func requestFullAccuracy() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey)
    }

    private func beginNewTrip() {
        lastError = nil
        notice = nil
        accessLost = false
        batteryWarningDismissed = false
        var record = TripRecord(startedAt: Date())
        record.context = captureContext(start: nil)
        record.usableAccuracyLimit = settings.usableAccuracy
        do {
            try store.create(record)
            writer = try store.openWriter(record.id)
        } catch {
            lastError = "Die Fahrt konnte nicht angelegt werden."
            phase = .idle
            return
        }
        defaults.set(record.id.uuidString, forKey: Self.recordingKey)
        trip = record
        fixes = []
        events = []
        accumulator = LiveAccumulator(config: settings.statsConfig)
        pendingGapReason = nil
        lastGap = nil
        current = LiveSnapshot()
        precision.reset()
        currentPoorAccuracy = nil
        // The warm-up hands its running updates over to the recording; nothing is stopped.
        isWarmingUp = false
        warmFix = nil
        phase = .recording
        startUpdates()
        startMotion(record.id)
        startBreakWatch()
        onTripStarted?()
        onTripChanged?()
    }

    private func startUpdates() {
        configureManager()
        // The session keeps background updates alive. It must be created in the foreground for a
        // new trip; after a background relaunch it is recreated as Core Location recommends.
        // Kept across a revoke and re-grant: a denial only suspends the session, and a new one could
        // not become active while Spur is in the background. It is invalidated only on stop.
        if session == nil { session = makeSession() }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        if manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey)
        }
        startSyncTimer()
        updateIdleTimer()
    }

    // MARK: Resume

    /// On launch: continue the marked trip right away when it is fresh (newest fix at most 30
    /// minutes old), else finalize it. Only the marked trip is read here, so the engine restarts
    /// immediately (also on a background relaunch); other folders are cleaned up off the main actor
    /// by `TripLifecycle.cleanUp`. Returns the id of the resumed trip.
    @discardableResult
    func resumeIfNeeded(now: Date = Date()) -> UUID? {
        guard phase == .idle else { return nil }
        let marked = defaults.string(forKey: Self.recordingKey).flatMap(UUID.init(uuidString:))
        let decision = TripLifecycle.recoverMarked(store: store, markedId: marked, now: now, config: settings.statsConfig)
        if decision.finalized {
            notice = "Letzte Fahrt wurde beendet"
            noticeIsWarning = false
        }
        guard let (stored, contents) = decision.resume else {
            // No trip continues: nothing may relaunch Spur in the background any more.
            manager.stopMonitoringSignificantLocationChanges()
            defaults.removeObject(forKey: Self.recordingKey)
            if decision.finalized { onTripChanged?() }
            return nil
        }
        lastError = nil
        var record = stored
        // Gap records in the fix file are authoritative; trip.json may lag behind a kill.
        for gap in contents.gaps where !record.gaps.contains(gap) { record.gaps.append(gap) }
        do {
            writer = try store.openWriter(record.id)
        } catch {
            // The fix file cannot be reopened: close the trip with what is on disk instead of
            // leaving it half open, and stop everything that could relaunch Spur for it.
            manager.stopMonitoringSignificantLocationChanges()
            try? store.save(TripLifecycle.finalized(record, contents: contents, config: settings.statsConfig))
            defaults.removeObject(forKey: Self.recordingKey)
            notice = "Letzte Fahrt wurde beendet"
            noticeIsWarning = false
            lastError = "Die laufende Fahrt konnte nicht fortgesetzt werden."
            onTripChanged?()
            return nil
        }
        fixes = contents.fixes
        accumulator = LiveAccumulator(config: StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? settings.usableAccuracy))
        for f in fixes { accumulator.add(f) }
        precision.reset()
        for f in fixes.suffix(600) { precision.add(time: f.time, accuracy: f.horizontalAccuracy) }
        isWarmingUp = false
        warmFix = nil
        events = store.loadEvents(record.id)
        trip = record
        pendingGapReason = record.openPause == nil ? .relaunch : .pause
        phase = .recording
        // A trip paused before the relaunch stays paused: no motion until "Fortsetzen".
        if record.openPause == nil { startMotion(record.id) }
        startBreakWatch(paused: record.openPause?.kind == .auto)
        onTripStarted?()
        try? store.save(trip ?? record)
        evaluateRoadType()
        publish(force: true)
        startUpdates()
        // Without access (for example a lapsed one-time grant) the trip waits; the request is
        // made when the app becomes active, see `appNotification`.
        if manager.authorizationStatus == .notDetermined { accessLost = true }
        return record.id
    }

    // MARK: Fixes

    func handle(_ incoming: [Fix]) {
        if phase != .recording {
            // Warm-up fixes only feed the GPS chip; they are never stored.
            if isWarmingUp, phase == .idle, let f = incoming.last { warm(f) }
            return
        }
        if trip?.openPause?.kind == .manual { return watchWhilePaused(incoming) }
        guard let writer, var trip else { return }
        let startMs = Int64(trip.startedAt.timeIntervalSince1970 * 1000) - 1000
        var appended = false
        var gapAdded = false
        var stored: [Fix] = []
        for f in incoming {
            // A cached position from before the trip, or a fix delivered twice, is not new data.
            if f.timestampMs < startMs { continue }
            if let last = fixes.last, f.timestampMs <= last.timestampMs { continue }
            // A resume always records its relaunch gap (SPEC 4), even when iOS relaunched Spur so
            // quickly that no fix was missed; other gaps need more than 5 s without a fix.
            if let last = fixes.last,
               f.time - last.time > StatsConstants.gapThreshold || pendingGapReason == .relaunch {
                let reason = pendingGapReason ?? (backgroundSinceLastFix || isInBackground ? .background : .signal)
                let gap = Gap(startMs: last.timestampMs, endMs: f.timestampMs, reason: reason)
                try? writer.append(gap)
                trip.gaps.append(gap)
                lastGap = gap
                metaDirty = true
                gapAdded = true
            }
            pendingGapReason = nil
            do {
                try writer.append(f)
                if lastError != nil { lastError = nil }
            } catch {
                // Memory must match the file: an unwritten fix is not counted.
                lastError = "Positionen konnten nicht gespeichert werden."
                continue
            }
            fixes.append(f)
            accumulator.add(f)
            precision.add(time: f.time, accuracy: f.horizontalAccuracy)
            stored.append(f)
            appended = true
        }
        guard appended else { return }
        for f in stored {
            motion.observe(f)
            liveMotion.ingest(fix: f)
        }
        if settings.autoPause {
            for f in stored {
                let o = BreakDetector.Observation(time: f.time, speed: f.speed, place: stopPlace)
                if let e = breaks.observe(o) { applyBreak(e) }
                askPlaceIfNewStop(at: f)
            }
        }
        onFixesRecorded?(stored)
        backgroundSinceLastFix = isInBackground
        // Only a new gap changes the record; reassigning it on every fix would re-render every
        // view that observes the trip.
        if gapAdded { self.trip = trip }
        if Date().timeIntervalSince(lastSync) >= 10 { syncToDisk() }
        if let last = fixes.last { maybeGeocode(last) }
        publish(force: false)
    }

    private func publish(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) >= 0.5 else { return }
        lastPublish = now
        if force || now.timeIntervalSince(lastRoadEvaluation) >= 5 { evaluateRoadType() }
        if let newest = fixes.last {
            let banner = precision.evaluate(now: newest.time)
            if banner != currentPoorAccuracy { currentPoorAccuracy = banner }
        }
        let recent = fixes.suffix(12).map { LatLon(lat: $0.latitude, lon: $0.longitude) }
        current = LiveSnapshot(
            revision: current.revision + 1,
            lastFix: fixes.last,
            distance: accumulator.distance,
            movingTime: accumulator.movingTime,
            fixCount: fixes.count,
            roadNow: current.roadNow,
            heading: TrailGeometry.heading(course: fixes.last?.course, recent: Array(recent))
        )
    }

    /// The scene came to the front or left it (17.4b). Coming back shows the newest values at once.
    func setDisplayActive(_ active: Bool) {
        displayActive = active
        show()
    }

    private func show() {
        guard displayActive else { return }
        if live != current { live = current; displayMutations += 1 }
        if poorAccuracy != currentPoorAccuracy { poorAccuracy = currentPoorAccuracy; displayMutations += 1 }
    }

    /// Publishes without the 0.5 s throttle (unit tests feed fixes faster than real time).
    func forcePublishForTesting() { publish(force: true) }

    /// Road type now: the classifier over the last 10 minutes, every 5 s.
    private func evaluateRoadType() {
        lastRoadEvaluation = Date()
        guard let last = fixes.last else { return }
        var lo = fixes.count - 1
        while lo > 0 && last.time - fixes[lo - 1].time <= 600 { lo -= 1 }
        let track = Track(fixes: Array(fixes[lo...]), config: accumulator.config)
        let classes = RoadTypeClassifier.classify(track, stops: StopStats.stops(track))
        current.roadNow = classes.last ?? nil
    }

    // MARK: Warm-up (SPEC 14.1)

    /// Starts or stops the warm-up so it runs exactly while it is wanted, nothing records, the app
    /// is in the foreground and access is granted. Foreground only: no background updates, no
    /// background session, no significant-change monitoring, and it never asks for permission.
    func refreshWarmUp() {
        let status = manager.authorizationStatus
        let granted = status == .authorizedWhenInUse || status == .authorizedAlways
        let run = warmUpWanted && phase == .idle && !isInBackground && granted
        guard run != isWarmingUp else { return }
        isWarmingUp = run
        if run {
            configureManager()
            manager.allowsBackgroundLocationUpdates = false
            manager.startUpdatingLocation()
        } else {
            if phase == .idle { manager.stopUpdatingLocation() }
            warmFix = nil
        }
    }

    private func warm(_ f: Fix) {
        let now = Date()
        guard warmFix == nil || now.timeIntervalSince(lastWarmPublish) >= 0.5 else { return }
        lastWarmPublish = now
        warmFix = f
    }

    // MARK: Geocoding

    private func maybeGeocode(_ f: Fix) {
        guard settings.geocodingEnabled, !geocoder.isBusy, let trip else { return }
        guard Date().timeIntervalSince(lastGeocodeAttempt) >= 15 else { return }
        let kind: PlaceSample.Kind
        if !trip.places.contains(where: { $0.kind == .start }) {
            kind = .start
        } else if GeocodeSampler.shouldSample(fix: f, last: trip.places.last) {
            kind = .moving
        } else {
            return
        }
        lastGeocodeAttempt = Date()
        let tripId = trip.id
        Task {
            guard let sample = await geocoder.sample(f, kind: kind) else { return }
            await self.didGeocode(sample, tripId: tripId)
        }
    }

    /// A geocoding result. While the trip records or stops it goes into the in-memory record,
    /// which stop() merges before its final save; after that into the saved trip.
    func didGeocode(_ sample: PlaceSample, tripId: UUID) async {
        if trip?.id == tripId && (phase == .recording || phase == .stopping) {
            trip?.places.append(sample)
            metaDirty = true
        } else {
            await appendPlace(sample, toStored: tripId)
        }
    }

    // MARK: Events

    /// Changes the recording trip's record (title, note) through the engine, which owns it while
    /// it records: a change saved behind its back would be overwritten by its next save (SPEC 17.8).
    @discardableResult
    func updateRunningTrip(_ change: (inout TripRecord) -> Void) -> TripRecord? {
        guard phase == .recording, var t = trip else { return nil }
        change(&t)
        trip = t
        try? store.save(t)
        return t
    }

    // MARK: Pause (SPEC 18.9)

    /// A manual pause lasts: no fixes and no motion are written until "Fortsetzen" or Stop.
    var isPaused: Bool { trip?.openPause != nil }
    /// While paused, the phone sees driving (at least 5 m/s for 30 s, kept in memory only): the
    /// HUD and the Live Activity say "Pausiert, du fährst". It never resumes by itself.
    private(set) var drivingWhilePaused = false
    @ObservationIgnored private var drivingSince: Double?
    /// A pause began or ended, or driving during it was seen or ended (the Live Activity).
    @ObservationIgnored var onPauseChanged: (() -> Void)?
    static let pausedDrivingSpeed = 5.0
    static let pausedDrivingSeconds = 30.0

    @discardableResult
    func pauseTrip(now: Date = Date()) -> Bool {
        guard phase == .recording, var t = trip, t.openPause == nil else { return false }
        t.pauses = (t.pauses ?? []) + [TripPause(start: now, end: nil, kind: .manual)]
        trip = t
        breaks = BreakDetector(config: .init(minutes: AppEnvironment.autoPauseMinutes ?? Double(settings.autoPauseMinutes)))
        try? store.save(t)
        motion.stop()
        liveMotion.end()
        drivingWhilePaused = false
        drivingSince = nil
        publish(force: true)
        onPauseChanged?()
        return true
    }

    @discardableResult
    func resumeTrip(now: Date = Date()) -> Bool {
        guard phase == .recording, var t = trip, t.openPause != nil else { return false }
        let wasAuto = t.openPause?.kind == .auto
        TripLifecycle.closePause(&t, at: now)
        trip = t
        try? store.save(t)
        breaks = BreakDetector(config: .init(minutes: AppEnvironment.autoPauseMinutes ?? Double(settings.autoPauseMinutes)))
        if wasAuto { setPausedLocationRate(false) }
        // The next fix after the pause records the gap as a pause, not as lost signal.
        pendingGapReason = .pause
        drivingWhilePaused = false
        drivingSince = nil
        startMotion(t.id)
        publish(force: true)
        onPauseChanged?()
        return true
    }

    // MARK: Automatic pause (SPEC 18.9 part 2b)

    var isAutoPaused: Bool { trip?.openPause?.kind == .auto }

    private func startBreakWatch(paused: Bool = false) {
        breaks = BreakDetector(config: .init(minutes: AppEnvironment.autoPauseMinutes ?? Double(settings.autoPauseMinutes)))
        if paused { breaks.resumeAsPaused() }
        stopPlace = nil
        placeAskedFor = nil
    }

    private func stopBreakWatch() {
        stopPlace = nil
        placeAskedFor = nil
    }

    /// A stop began: where does the car stand? Once per stop, from the car's position at the
    /// stop's start; the answer reaches the detector with the following fixes.
    private func askPlaceIfNewStop(at f: Fix) {
        guard let start = breaks.stopStart else {
            if placeAskedFor != nil { placeAskedFor = nil; stopPlace = nil }
            return
        }
        guard placeAskedFor != start else { return }
        placeAskedFor = start
        stopPlace = nil
        if let fixed = placeOverride ?? AppEnvironment.synthPlace {
            stopPlace = fixed
            return
        }
        guard let lookup = placeLookup else { return }
        let at = LatLon(lat: f.latitude, lon: f.longitude)
        Task { [weak self] in
            let place = await lookup(at)
            // Still the same stop: a stop that ended meanwhile keeps nothing.
            if let self, self.placeAskedFor == start { self.stopPlace = place }
        }
    }

    /// During an automatic pause fixes keep coming, but coarser and only every 25 m, so the trip
    /// stays continuous and the resume is seen; motion pauses.
    private func setPausedLocationRate(_ paused: Bool) {
        manager.desiredAccuracy = paused ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = paused ? 25 : kCLDistanceFilterNone
    }

    private func applyBreak(_ e: BreakDetector.Event) {
        guard var t = trip else { return }
        switch e {
        case .pauseStarted(let at, let evidence):
            guard t.openPause == nil else { return }
            t.pauses = (t.pauses ?? []) + [TripPause(start: Date(timeIntervalSince1970: at), end: nil, kind: .auto, evidence: evidence)]
            motion.stop()
            liveMotion.end()
            setPausedLocationRate(true)
        case .pauseEnded(let at):
            guard t.openPause?.kind == .auto else { return }
            TripLifecycle.closePause(&t, at: Date(timeIntervalSince1970: at))
            setPausedLocationRate(false)
            startMotion(t.id)
        case .pauseSpan(let from, let to, let evidence):
            t.pauses = (t.pauses ?? []) + [TripPause(start: Date(timeIntervalSince1970: from), end: Date(timeIntervalSince1970: to),
                                                     kind: .auto, evidence: evidence)]
        }
        trip = t
        try? store.save(t)
        publish(force: true)
        onPauseChanged?()
    }


    /// While paused: nothing is written; only whether the car drives is watched, in memory.
    private func watchWhilePaused(_ incoming: [Fix]) {
        for f in incoming {
            if (f.speed ?? 0) >= Self.pausedDrivingSpeed {
                let since = drivingSince ?? f.time
                drivingSince = since
                if f.time - since >= Self.pausedDrivingSeconds, !drivingWhilePaused {
                    drivingWhilePaused = true
                    onPauseChanged?()
                }
            } else {
                drivingSince = nil
                if drivingWhilePaused {
                    drivingWhilePaused = false
                    onPauseChanged?()
                }
            }
        }
    }

    @discardableResult
    func addEvent(_ tag: TripEvent.Tag) -> Bool {
        guard phase == .recording, let trip, let f = fixes.last else { return false }
        let e = TripEvent(
            id: UUID(), timestampMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            latitude: f.latitude, longitude: f.longitude, altitude: f.altitude,
            ellipsoidalAltitude: f.ellipsoidalAltitude, tag: tag, note: nil
        )
        events.append(e)
        try? store.saveEvents(events, for: trip.id)
        return true
    }

    // MARK: Stop

    /// Stops the trip. The record is saved at once with `isRecording = false` and its end time, so
    /// a kill during the statistics leaves a finished trip (the next launch fills in the missing
    /// statistics); then the statistics are computed off the main actor and saved again.
    func stop() {
        guard phase == .recording, let running = trip else { return }
        phase = .stopping
        onTripStopped?()
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        session?.invalidate()
        session = nil
        syncTimer?.invalidate()
        syncTimer = nil
        writer?.close()
        writer = nil
        motion.stop()
        liveMotion.end()
        stopBreakWatch()
        var stopped = TripLifecycle.ended(running, at: Date(), context: captureContext(start: running.context))
        stopped.motionHealth = motionHealthNow()
        if let seconds = speedLimitSeconds?(), !seconds.isEmpty { stopped.speedLimitSeconds = seconds }
        let ended = stopped
        try? store.save(ended)
        defaults.removeObject(forKey: Self.recordingKey)
        let recorded = fixes
        let config = accumulator.config
        updateIdleTimer()

        Task {
            let contents = FixFile.Contents(fixes: recorded, gaps: ended.gaps)
            var record = await Task.detached(priority: .userInitiated) {
                TripLifecycle.finalized(ended, contents: contents, config: config)
            }.value
            // Geocoding results that arrived while stopping belong to this trip too.
            let late = (trip?.places ?? []).filter { !record.places.contains($0) }
            if !late.isEmpty {
                record.places.append(contentsOf: late)
                record.places.sort { $0.timestampMs < $1.timestampMs }
                record.statistics?.places = PlacesSummary.compute(
                    samples: record.places, track: Track(fixes: recorded, config: config))
            }
            let kept = recorded.count >= 2
            if kept {
                try? store.save(record)
            } else {
                // Nothing was recorded: an empty trip is not worth keeping, and no summary opens.
                try? store.delete(record.id)
            }
            trip = nil
            fixes = []
            events = []
            lastGap = nil
            drivingWhilePaused = false
            drivingSince = nil
            current = LiveSnapshot()
            currentPoorAccuracy = nil
            precision.reset()
            phase = .idle
            refreshWarmUp()
            if kept {
                finishedTrip = record
                onTripFinished?(record.id)
            } else {
                notice = "Keine Positionen, Fahrt verworfen"
                noticeIsWarning = true
            }
            onTripChanged?()
            if kept, settings.geocodingEnabled, let last = recorded.last,
               let sample = await geocoder.sample(last, kind: .end) {
                await appendPlace(sample, toStored: record.id)
            }
        }
    }

    /// Adds a place sample to a saved trip and refreshes its place statistics. The fix file is
    /// parsed off the main actor; the read-modify-write of `trip.json` happens on the main actor,
    /// so it is serialized with stop(), renames and other samples.
    private func appendPlace(_ sample: PlaceSample, toStored id: UUID) async {
        let store = store
        let fixes = await Task.detached(priority: .utility) { store.loadFixes(id).fixes }.value
        let config = settings.statsConfig
        var appended = false
        let updated = try? store.update(id) { record in
            guard !record.isRecording, !record.places.contains(sample) else { return }
            record.places.append(sample)
            record.places.sort { $0.timestampMs < $1.timestampMs }
            if record.statistics != nil {
                let effective = StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? config.usableAccuracy)
                record.statistics?.places = PlacesSummary.compute(samples: record.places, track: Track(fixes: fixes, config: effective))
            }
            appended = true
        }
        guard appended, let updated else { return }
        if finishedTrip?.id == id { finishedTrip = updated }
        onTripChanged?()
    }

    // MARK: Persistence

    private func syncToDisk() {
        lastSync = Date()
        try? writer?.sync()
        motion.sync()
        motion.checkStall()
        if var t = trip, t.motionHealth != motionHealthNow() {
            t.motionHealth = motionHealthNow()
            trip = t
            metaDirty = true
        }
        if let trip, metaDirty || trip.isRecording {
            try? store.save(trip)
            metaDirty = false
        }
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncToDisk() }
        }
    }

    // MARK: App state

    private func observeApp() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.willTerminateNotification,
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
        ]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let received = note.name
                MainActor.assumeIsolated { self?.appNotification(received) }
            })
        }
        isInBackground = UIApplication.shared.applicationState == .background
    }

    func appNotification(_ name: Notification.Name) {
        switch name {
        case UIApplication.didBecomeActiveNotification:
            // A trip resumed without access (a lapsed one-time grant): iOS only shows the prompt
            // while the app is in use, so ask here.
            if phase == .recording, manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
        case UIApplication.didEnterBackgroundNotification: appStateChanged(background: true)
        case UIApplication.willEnterForegroundNotification: appStateChanged(background: false)
        case UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification: updateBattery()
        default: syncIfRecording()
        }
    }

    private func appStateChanged(background: Bool) {
        isInBackground = background
        if background { backgroundSinceLastFix = true }
        refreshWarmUp()
        syncIfRecording()
        updateIdleTimer()
    }

    private func syncIfRecording() {
        guard phase == .recording else { return }
        syncToDisk()
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && phase == .recording && !isInBackground
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? level : nil
        batteryState = UIDevice.current.batteryState
    }

    // MARK: Context

    /// Context at start (pass nil) or the start context completed with end values.
    private func captureContext(start: TripContext?) -> TripContext {
        let level = UIDevice.current.batteryLevel
        let battery = level >= 0 ? Double(level) : nil
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if var c = start {
            c.batteryLevelEnd = battery
            c.lowPowerModeEnd = lowPower
            c.thermalStateEnd = Self.thermalName()
            Self.upgrade(&c, status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
            return c
        }
        var c = TripContext()
        c.driverName = settings.driverName.isEmpty ? nil : settings.driverName
        c.vehicleName = settings.vehicleName.isEmpty ? nil : settings.vehicleName
        c.deviceModel = AppEnvironment.deviceModel
        c.systemVersion = UIDevice.current.systemVersion
        c.appVersion = AppEnvironment.appVersion
        c.appBuild = AppEnvironment.appBuild
        c.timeZoneIdentifier = TimeZone.current.identifier
        c.batteryLevelStart = battery
        c.lowPowerModeStart = lowPower
        c.thermalStateStart = Self.thermalName()
        switch manager.authorizationStatus {
        case .authorizedAlways: c.authorization = .always
        case .authorizedWhenInUse: c.authorization = .whenInUse
        default: c.authorization = .other
        }
        c.accuracyAuthorization = manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced
        return c
    }

    /// Raises the recorded authorization and accuracy to the best level seen during the trip
    /// (a temporary full-accuracy grant or an upgrade to "Immer" after the start). Returns true
    /// when something changed.
    @discardableResult
    static func upgrade(_ c: inout TripContext, status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) -> Bool {
        var changed = false
        let rank: (TripContext.Authorization?) -> Int = { a in
            switch a {
            case .always: 2
            case .whenInUse: 1
            default: 0
            }
        }
        let seen: TripContext.Authorization? = status == .authorizedAlways ? .always : (status == .authorizedWhenInUse ? .whenInUse : nil)
        if let seen, rank(seen) > rank(c.authorization) {
            c.authorization = seen
            changed = true
        }
        if accuracy == .fullAccuracy, c.accuracyAuthorization != .full {
            c.accuracyAuthorization = .full
            changed = true
        }
        return changed
    }
}

// MARK: - CLLocationManagerDelegate

extension RecordingEngine: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Fix.init(location:))
        MainActor.assumeIsolated { self.handle(fixes) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        MainActor.assumeIsolated { self.authorizationChanged(status, accuracy) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            if code == .denied {
                self.authorization = .denied
                if self.phase == .recording { self.accessLost = true }
            }
        }
    }

    /// Authorization or accuracy changed. During a trip: a revocation keeps the trip (the HUD
    /// shows the denied banner), a grant restarts the updates, and the trip context records the
    /// best level seen.
    func authorizationChanged(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization) {
        authorization = status
        accuracyAuthorization = accuracy
        applyLocationIndicator()
        if phase == .recording {
            if var t = trip, Self.upgrade(&t.context, status: status, accuracy: accuracy) {
                trip = t
                metaDirty = true
            }
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                if accessLost {
                    accessLost = false
                    startUpdates()
                }
            case .denied, .restricted, .notDetermined:
                accessLost = true
            @unknown default:
                break
            }
            return
        }
        guard startWhenAuthorized else {
            refreshWarmUp()
            return
        }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            startWhenAuthorized = false
            phase = .idle
            beginNewTrip()
        case .denied, .restricted:
            startWhenAuthorized = false
            phase = .idle
        default:
            break
        }
    }
}
