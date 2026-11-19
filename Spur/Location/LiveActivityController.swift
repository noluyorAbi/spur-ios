import ActivityKit
import Foundation

/// What the Live Activity shows, taken from the engine and the road service.
nonisolated struct LiveActivityInput: Equatable, Sendable {
    var tripId: UUID
    var startedAt: Date
    var distance: Double
    var lastFix: Fix?
    var pausedForAccess = false
    /// A manual pause (SPEC 18.9), and whether the phone sees driving during it.
    var userPaused = false
    var drivingWhilePaused = false
    var autoPaused = false
    var poorAccuracy = false
    var roadType: String?
    /// The limit the HUD sign shows right now (`LiveView.displayedLimit`), nil when none.
    var limit: SpeedLimit?
    var units: UnitSystem = .metric
}

/// The pure part of SPEC 16.4: the content state, the stale date and when to update.
nonisolated enum LiveActivityState {
    /// A killed app leaves a stale state, not frozen numbers.
    static let staleAfter: TimeInterval = 120
    /// Updates at most about every 10 s, else on a state change.
    static let updateInterval: TimeInterval = 10
    /// A limit or road type change waits at least this long after the last update (a sign that
    /// drops for one fix must not flicker); a status change goes out at once.
    static let changeGap: TimeInterval = 2.5
    /// The ended activity stays on the lock screen this long.
    static let dismissAfter: TimeInterval = 300
    /// The GPS accuracy is shown only from a fix at most this old (the HUD chip's rule).
    static let accuracyFreshness: TimeInterval = 10
    /// A refused request is tried again after this, or at the next activation.
    static let retryAfter: TimeInterval = 60

    static func content(_ input: LiveActivityInput, now: Date) -> SpurActivityAttributes.ContentState {
        let fix = input.lastFix
        let age = fix.map { now.timeIntervalSince($0.date) } ?? .infinity
        let fresh = age <= StatsConstants.gapThreshold
        let status: SpurActivityAttributes.ContentState.Status =
            input.pausedForAccess ? .paused
            : input.autoPaused ? .autoPaused
            : input.userPaused ? (input.drivingWhilePaused ? .pausedDriving : .userPaused)
            : (!fresh ? .gap : (input.poorAccuracy ? .poorAccuracy : .recording))
        return SpurActivityAttributes.ContentState(
            status: status,
            distanceMeters: (input.distance / 10).rounded() * 10,
            speedMps: fresh ? fix?.speed.map { ($0 * 100).rounded() / 100 } : nil,
            accuracyMeters: age <= accuracyFreshness ? fix?.horizontalAccuracy.map { $0.rounded() } : nil,
            roadType: input.roadType,
            limit: input.limit.map { .init(value: $0.value, mph: $0.unit == .mph) },
            metric: input.units == .metric,
            endedAt: nil,
            updatedAt: now)
    }

    /// The final state: the numbers at the stop, no speed.
    static func final(_ input: LiveActivityInput, endedAt: Date) -> SpurActivityAttributes.ContentState {
        var s = content(input, now: endedAt)
        s.status = .ended
        s.speedMps = nil
        s.limit = nil
        s.endedAt = endedAt
        return s
    }

    static func staleDate(_ now: Date) -> Date { now.addingTimeInterval(staleAfter) }

    /// A status change is shown at once, a limit or road type change after at least 2.5 s,
    /// anything else at most every 10 s.
    static func shouldUpdate(last: SpurActivityAttributes.ContentState?, sentAt: Date?,
                             next: SpurActivityAttributes.ContentState, now: Date) -> Bool {
        guard let last, let sentAt else { return true }
        if last.status != next.status { return true }
        let since = now.timeIntervalSince(sentAt)
        if last.limit != next.limit || last.roadType != next.roadType { return since >= changeGap }
        return since >= updateInterval
    }
}

/// The part of ActivityKit the controller uses, so tests drive it with a fake.
@MainActor
protocol LiveActivityAPI: AnyObject {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled`.
    var isEnabled: Bool { get }
    /// Activities that are active or stale: id and trip id.
    func running() -> [(id: String, tripId: UUID)]
    /// Whether the activity is still active or stale (not ended by the system or the person).
    func isLive(_ id: String) -> Bool
    func request(_ attributes: SpurActivityAttributes, state: SpurActivityAttributes.ContentState, staleDate: Date) throws -> String
    func update(_ id: String, state: SpurActivityAttributes.ContentState, staleDate: Date) async
    /// Ends the activity; `dismissal` nil removes it at once.
    func end(_ id: String, state: SpurActivityAttributes.ContentState?, dismissal: Date?) async
}

/// The Live Activity of the recording trip (SPEC 16.4). Starts only in the foreground, reattaches
/// after a relaunch, updates throttled (also from the background), ends with the final state, and
/// fails silently when Live Activities are off. When the system or the person ends it during a
/// trip, it is not started again for that trip, also after a relaunch. Every update and end runs
/// on one serial chain, in the order decided, so the end always goes last.
@MainActor
final class LiveActivityController {
    static let givenUpKey = "liveActivity.givenUpTrip"

    private let api: LiveActivityAPI
    private let enabled: () -> Bool
    private let defaults: UserDefaults
    private(set) var current: (id: String, tripId: UUID)?
    private var lastSent: (state: SpurActivityAttributes.ContentState, at: Date)?
    /// A trip whose activity the system (8 h cap) or the person ended: left alone. Persisted, so a
    /// relaunch does not start it again.
    private(set) var givenUp: UUID? {
        didSet { defaults.set(givenUp?.uuidString, forKey: Self.givenUpKey) }
    }
    /// Nothing starts before `launch` looked for an activity to reattach to.
    private var launched = false
    /// The trip that was just stopped: a late refresh for it never starts a new activity.
    private(set) var stoppedTrip: UUID?
    /// The last refused request, for the back-off.
    private var refused: (trip: UUID, at: Date)?
    private var chain: Task<Void, Never>?

    init(api: LiveActivityAPI, enabled: @escaping () -> Bool, defaults: UserDefaults = .standard) {
        self.api = api
        self.enabled = enabled
        self.defaults = defaults
    }

    var isLive: Bool { current != nil }

    /// Runs an API call after every call decided before it.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await op()
        }
        chain = task
        await task.value
    }

    /// At launch: ends activities whose trip no longer records and reattaches to the recording
    /// trip's own; a give-up for that trip survives, one for an older trip is dropped.
    func launch(recordingTripId: UUID?) async {
        let stored = defaults.string(forKey: Self.givenUpKey).flatMap(UUID.init)
        givenUp = stored != nil && stored == recordingTripId ? stored : nil
        for activity in api.running() {
            if activity.tripId == recordingTripId, current == nil, givenUp != recordingTripId {
                current = activity
            } else if activity.id != current?.id {
                await enqueue { [api] in await api.end(activity.id, state: nil, dismissal: nil) }
            }
        }
        launched = true
    }

    /// A new snapshot of the trip (a fix, a state change, the app becoming active, a timer).
    /// Starts the activity when none runs and the app is in the foreground; `activation` marks a
    /// scene activation, which may retry a refused request at once.
    func refresh(_ input: LiveActivityInput?, foreground: Bool, activation: Bool = false, now: Date = Date()) async {
        guard launched else { return }
        guard let input, enabled(), api.isEnabled else {
            // Nothing records, or the setting or iOS switched it off: no activity stays.
            if let current { await endNow(current) }
            return
        }
        guard input.tripId != stoppedTrip else { return }
        if let current, current.tripId != input.tripId {
            await endNow(current)
        }
        if let c = current, !api.isLive(c.id) {
            // Ended by the system (about 8 h) or swiped away: do not fight it.
            givenUp = c.tripId
            current = nil
            lastSent = nil
            return
        }
        let state = LiveActivityState.content(input, now: now)
        guard let current else {
            guard foreground, givenUp != input.tripId else { return }
            if let r = refused, r.trip == input.tripId, !activation, now.timeIntervalSince(r.at) < LiveActivityState.retryAfter { return }
            do {
                let id = try api.request(SpurActivityAttributes(tripId: input.tripId, startedAt: input.startedAt),
                                         state: state, staleDate: LiveActivityState.staleDate(now))
                self.current = (id, input.tripId)
                lastSent = (state, now)
                refused = nil
            } catch {
                // Disabled, too many activities or not allowed now: silently none, retried later.
                refused = (input.tripId, now)
            }
            return
        }
        guard LiveActivityState.shouldUpdate(last: lastSent?.state, sentAt: lastSent?.at, next: state, now: now) else { return }
        lastSent = (state, now)
        let id = current.id
        await enqueue { [api] in await api.update(id, state: state, staleDate: LiveActivityState.staleDate(now)) }
    }

    /// The trip stopped: the final state, removed after 5 minutes; a discarded trip at once.
    func stop(_ input: LiveActivityInput?, kept: Bool, now: Date = Date()) async {
        defer { givenUp = nil }
        stoppedTrip = input?.tripId ?? current?.tripId
        guard let current else { return }
        self.current = nil
        lastSent = nil
        let id = current.id
        guard kept, let input else {
            await enqueue { [api] in await api.end(id, state: nil, dismissal: nil) }
            return
        }
        let final = LiveActivityState.final(input, endedAt: now)
        await enqueue { [api] in await api.end(id, state: final, dismissal: now.addingTimeInterval(LiveActivityState.dismissAfter)) }
    }

    private func endNow(_ c: (id: String, tripId: UUID)) async {
        current = nil
        lastSent = nil
        await enqueue { [api] in await api.end(c.id, state: nil, dismissal: nil) }
    }
}

/// The wiring between the recording and the controller (SPEC 16.4): refreshes on fixes, scene
/// activations and a 10 s ticker, the stop with the final state, and whether an activity is live
/// (for the background-location pill). Kept out of `AppModel` so the stop path is testable.
@MainActor
final class LiveActivityDriver {
    let controller: LiveActivityController
    private let input: () -> LiveActivityInput?
    private let foreground: () -> Bool
    private let tick: Duration
    /// After every step: whether an activity is live now.
    var onLiveChanged: ((Bool) -> Void)?
    private var ticker: Task<Void, Never>?

    init(controller: LiveActivityController, tick: Duration = .seconds(LiveActivityState.updateInterval),
         input: @escaping () -> LiveActivityInput?, foreground: @escaping () -> Bool) {
        self.controller = controller
        self.tick = tick
        self.input = input
        self.foreground = foreground
    }

    func launch(recordingTripId: UUID?) async {
        await controller.launch(recordingTripId: recordingTripId)
        refresh()
    }

    /// A fix, the app becoming active, the setting, the ticker.
    func refresh(activation: Bool = false) {
        let i = input()
        let fg = foreground()
        Task {
            await controller.refresh(i, foreground: fg, activation: activation)
            onLiveChanged?(controller.isLive)
        }
    }

    func tripStarted() {
        refresh()
        ticker?.cancel()
        // Without fixes nothing else refreshes: the ticker shows a gap and moves the stale date on.
        ticker = Task { [weak self, tick] in
            while !Task.isCancelled {
                // A cancelled sleep must not fall through to one more refresh while stopping.
                do { try await Task.sleep(for: tick) } catch { return }
                self?.refresh()
            }
        }
    }

    /// The final input is built by the caller (the engine is already stopping then).
    func tripStopped(_ final: LiveActivityInput?, kept: Bool) {
        ticker?.cancel()
        ticker = nil
        Task {
            await controller.stop(final, kept: kept)
            onLiveChanged?(controller.isLive)
        }
    }
}

/// ActivityKit itself.
@MainActor
final class SystemLiveActivityAPI: LiveActivityAPI {
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private nonisolated static func activity(_ id: String) -> Activity<SpurActivityAttributes>? {
        Activity<SpurActivityAttributes>.activities.first { $0.id == id }
    }

    func running() -> [(id: String, tripId: UUID)] {
        Activity<SpurActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { ($0.id, $0.attributes.tripId) }
    }

    func isLive(_ id: String) -> Bool {
        guard let a = Self.activity(id) else { return false }
        return a.activityState == .active || a.activityState == .stale
    }

    func request(_ attributes: SpurActivityAttributes, state: SpurActivityAttributes.ContentState, staleDate: Date) throws -> String {
        try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: nil).id
    }

    // Nonisolated: the `Activity` is looked up and awaited in the same context, never sent across.
    nonisolated func update(_ id: String, state: SpurActivityAttributes.ContentState, staleDate: Date) async {
        await Self.activity(id)?.update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated func end(_ id: String, state: SpurActivityAttributes.ContentState?, dismissal: Date?) async {
        await Self.activity(id)?.end(state.map { ActivityContent(state: $0, staleDate: nil) },
                                     dismissalPolicy: dismissal.map { .after($0) } ?? .immediate)
    }
}

/// Unit tests run inside the app: no real activity is ever started there.
@MainActor
final class NoLiveActivityAPI: LiveActivityAPI {
    var isEnabled: Bool { false }
    func running() -> [(id: String, tripId: UUID)] { [] }
    func isLive(_ id: String) -> Bool { false }
    func request(_ attributes: SpurActivityAttributes, state: SpurActivityAttributes.ContentState, staleDate: Date) throws -> String {
        throw CancellationError()
    }
    func update(_ id: String, state: SpurActivityAttributes.ContentState, staleDate: Date) async {}
    func end(_ id: String, state: SpurActivityAttributes.ContentState?, dismissal: Date?) async {}
}
