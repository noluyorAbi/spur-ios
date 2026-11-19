import Foundation
import SwiftUI
import Observation
import UIKit

enum AppTab: Hashable { case live, plan, history, settings }

/// Owns the store, the settings, the recording engine, the trip index and the navigation state.
@Observable
final class AppModel {
    var selectedTab: AppTab = .live
    /// Navigation stack of the history tab (trip ids).
    var historyPath: [UUID] = []
    /// A route from Planen shown on the live map (SPEC 18.3), until it is closed.
    var plannedRoute: PlannedRoute?
    @ObservationIgnored let store: TripStore
    let settings: Settings
    let engine: RecordingEngine
    /// Road data from OpenStreetMap (version 1.1).
    let roads: RoadService
    /// All trips, newest first, rebuilt from the folders.
    private(set) var trips: [TripRecord] = []
    private(set) var tripsLoaded = false
    /// Long exports (the sensor CSV) live here, not in a view: leaving the detail keeps the
    /// progress and the share sheet.
    let exporter = ExportRunner()
    /// Online or not (SPEC 18.2).
    let connectivity = Connectivity()
    /// The Live Activity of the recording trip (SPEC 16.4).
    @ObservationIgnored private(set) var activity: LiveActivityDriver
    /// The running trip's details, read by the live panel and by its "Fahrt-Details" (SPEC 17.8).
    let live: LiveTripDetails
    /// Light or dark (SPEC 18.1): the setting, or for Automatisch the sun at the position.
    private(set) var isLight = false
    @ObservationIgnored private var appearanceLoop: Task<Void, Never>?

    init(store: TripStore = .appDefault(), settings: Settings = Settings()) {
        self.store = store
        self.settings = settings
        engine = RecordingEngine(store: store, settings: settings)
        live = LiveTripDetails(engine: engine, settings: settings, store: store)
        roads = RoadService.make(store: store, settings: settings)
        let controller = LiveActivityController(api: AppEnvironment.isRunningTests ? NoLiveActivityAPI() : SystemLiveActivityAPI(),
                                                enabled: { [settings] in settings.showLiveActivity })
        activity = LiveActivityDriver(controller: controller, input: { nil }, foreground: { UIApplication.shared.applicationState == .active })
        engine.onTripChanged = { [weak self] in self?.reloadTrips() }
        let roads = roads
        let engine = engine
        engine.onTripStarted = { [weak engine, weak self] in
            roads.tripStarted(existing: engine?.fixes ?? [])
            self?.activity.tripStarted()
        }
        engine.onFixesRecorded = { [weak self] in
            roads.accept($0)
            self?.activity.refresh()
        }
        engine.speedLimitSeconds = { roads.currentCounts.limitSeconds }
        engine.onPauseChanged = { [weak self] in self?.activity.refresh() }
        engine.onTripStopped = { [weak self] in
            roads.tripEnded()
            self?.activityTripStopped()
        }
        engine.onTripFinished = { id in roads.analyze(id, first: true) }
        roads.onTripUpdated = { [weak self] _ in self?.reloadTrips() }
        roads.trips = { [weak self] in self?.finishedTrips ?? [] }
        roads.currentFixes = { [weak engine] in engine?.isRecording == true ? (engine?.fixes ?? []) : [] }
        // SPEC 18.9: where a stopped car stands, for the automatic pause (location only).
        engine.placeLookup = { [weak roads] p in await roads?.place(at: p) ?? .unknown }
        guard !AppEnvironment.isRunningTests else { return }
        #if DEBUG
        if AppEnvironment.seedDemo { DemoSeeder.seedIfNeeded(into: store) }
        if let path = AppEnvironment.importDrives { DemoSeeder.importDrives(path, into: store) }
        if AppEnvironment.stressSeed { DemoSeeder.seedStress(into: store) }
        if AppEnvironment.gapDemo { DemoSeeder.seedGapDemo(into: store) }
        #endif
        let resumed = engine.resumeIfNeeded()
        updateAppearance(initial: true)
        appearanceLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.updateAppearance()
            }
        }
        // Reattach to the resumed trip's activity and end orphans before anything may start one.
        activity = LiveActivityDriver(controller: controller, input: { [weak self] in self?.activityInput() },
                                      foreground: { UIApplication.shared.applicationState == .active })
        activity.onLiveChanged = { [weak engine] live in engine?.setLiveActivityShown(live) }
        let activity = activity
        Task { await activity.launch(recordingTripId: resumed) }
        #if DEBUG
        if resumed != nil, AppEnvironment.stopRecording { engine.stop() }
        #endif
        let config = settings.statsConfig
        Task {
            // Other folders are cleaned up and the index is read once, off the main actor.
            let index = await Task.detached(priority: .userInitiated) { () -> [TripRecord] in
                _ = TripLifecycle.cleanUp(store: store, except: resumed, config: config)
                return store.index()
            }.value
            apply(index: index)
        }
    }

    private func apply(index: [TripRecord]) {
        trips = index
        roads.reloadCoverage(index)
        if !tripsLoaded {
            tripsLoaded = true
            applyLaunchNavigation()
            roads.analyzeMissing(index)
            #if DEBUG
            if AppEnvironment.exportDemo, let newest = finishedTrips.first {
                let store = store
                let config = settings.statsConfig
                Task.detached { _ = try? ExportService.exportTrip(newest.id, store: store, config: config) }
            }
            #endif
        }
    }

    func reloadTrips() {
        let store = store
        Task {
            let index = await Task.detached(priority: .userInitiated) { store.index() }.value
            apply(index: index)
        }
    }

    /// Read-modify-write of one trip: loads the newest `trip.json`, changes it and saves it, so an
    /// edit never overwrites data written meanwhile (for example the end place). Returns the
    /// saved record.
    @discardableResult
    /// Re-decides light or dark: every minute, and when the setting changes. A change crossfades.
    func updateAppearance(initial: Bool = false, now: Date = Date()) {
        let elevation = engine.lastKnownCoordinate.map {
            SunPosition.elevation(latitude: $0.latitude, longitude: $0.longitude, unixTime: now.timeIntervalSince1970)
        }
        let light = initial ? AppearanceRule.initial(choice: settings.mapStyle, sunElevation: elevation)
            : AppearanceRule.isLight(choice: settings.mapStyle, sunElevation: elevation, current: isLight)
        guard light != isLight else { return }
        if initial { isLight = light } else { withAnimation(.easeInOut(duration: 0.6)) { isLight = light } }
    }

    func update(trip id: UUID, _ change: (inout TripRecord) -> Void) -> TripRecord? {
        if engine.isRecording, engine.trip?.id == id {
            guard let saved = engine.updateRunningTrip(change) else { return nil }
            if let k = trips.firstIndex(where: { $0.id == id }) { trips[k] = saved }
            return saved
        }
        guard let saved = try? store.update(id, change) else { return nil }
        if let k = trips.firstIndex(where: { $0.id == id }) { trips[k] = saved }
        return saved
    }

    // MARK: Live Activity (SPEC 16.4)

    /// The recording trip as the Live Activity shows it, nil when nothing records.
    func activityInput(now: Date = Date()) -> LiveActivityInput? {
        Self.activityInput(engine: engine, roads: roads, settings: settings, now: now)
    }

    /// From the current values, never the displayed ones: the Live Activity keeps updating while the
    /// app is in the background and its observed live state holds still (17.4b).
    static func activityInput(engine: RecordingEngine, roads: RoadService, settings: Settings, now: Date) -> LiveActivityInput? {
        guard engine.phase == .recording, let trip = engine.trip else { return nil }
        let last = engine.fixes.last
        return LiveActivityInput(
            tripId: trip.id, startedAt: trip.startedAt, distance: engine.current.distance, lastFix: last,
            pausedForAccess: engine.isPausedForAccess, userPaused: engine.isPaused && !engine.isAutoPaused, drivingWhilePaused: engine.drivingWhilePaused,
            autoPaused: engine.isAutoPaused,
            poorAccuracy: engine.currentPoorAccuracy != nil,
            roadType: roads.currentCounts.category?.label ?? engine.current.roadNow?.label,
            limit: LiveView.displayedLimit(roads.currentCounts.speedLimit, recording: true, enabled: settings.showSpeedLimit,
                                           lastFix: last?.date, now: now),
            units: settings.units)
    }

    /// A fix, the app becoming active, the setting, the ticker: the controller decides whether
    /// anything is sent.
    func refreshActivity(activation: Bool = false) {
        activity.refresh(activation: activation)
    }

    private func activityTripStopped() {
        // The engine is already `.stopping`: the final input is built here, not by `activityInput()`.
        let input = engine.trip.map { trip in
            LiveActivityInput(tripId: trip.id, startedAt: trip.startedAt, distance: engine.current.distance,
                              lastFix: engine.fixes.last, units: settings.units)
        }
        activity.tripStopped(input, kept: engine.fixes.count >= 2)
    }

    /// Finished trips only (the running one is shown separately).
    var finishedTrips: [TripRecord] { trips.filter { !$0.isRecording } }

    /// Shows a trip's detail in the history tab.
    func open(trip id: UUID) {
        selectedTab = .history
        historyPath = [id]
    }

    func save(_ record: TripRecord) {
        try? store.save(record)
        if let k = trips.firstIndex(where: { $0.id == record.id }) { trips[k] = record }
    }

    func delete(_ id: UUID) {
        guard engine.trip?.id != id else { return }
        try? store.delete(id)
        trips.removeAll { $0.id == id }
        historyPath.removeAll { $0 == id }
    }

    /// Deletes every finished trip; a running one stays.
    func deleteAll() {
        for t in finishedTrips { try? store.delete(t.id) }
        historyPath = []
        reloadTrips()
    }

    func bytesUsed() async -> Int64 {
        let store = store
        return await Task.detached { store.bytesUsed() }.value
    }

    func motionBytesUsed() async -> Int64 {
        let store = store
        return await Task.detached { store.motionBytes() }.value
    }

    /// Applies the debug screen selection (`-SpurTab`, `-SpurOpenTrip`) once the index is loaded.
    func applyLaunchNavigation() {
        #if DEBUG
        switch AppEnvironment.initialTab {
        case "history": selectedTab = .history
        case "settings": selectedTab = .settings
        case "plan": selectedTab = .plan
        case "live": selectedTab = .live
        default: break
        }
        if let target = AppEnvironment.openTrip {
            // `gapdemo`: the trip seeded by `-SpurGapDemo`, whatever else is newer.
            let id = target == "newest" ? finishedTrips.first?.id
                : target == "gapdemo" ? finishedTrips.first { $0.note == "Demofahrt mit Lücke" }?.id
                : UUID(uuidString: target)
            if let id { open(trip: id) }
        }
        #endif
    }
}
