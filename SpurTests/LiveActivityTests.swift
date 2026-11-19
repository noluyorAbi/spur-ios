import Foundation
import Testing
@testable import Spur

/// SPEC 16.4: the Live Activity's state builder, its text, and the controller's lifecycle.
@MainActor
struct LiveActivityTests {
    typealias State = SpurActivityAttributes.ContentState

    static let t0 = Date(timeIntervalSince1970: 1_794_420_000)
    static let trip = UUID(uuidString: "6F1B2D3C-0000-4000-8000-0000000000A1")!

    static func fix(at date: Date, speed: Double? = 13.4, accuracy: Double? = 4.4) -> Fix {
        Fix(timestampMs: Int64(date.timeIntervalSince1970 * 1000), latitude: 32.78, longitude: -96.80,
            horizontalAccuracy: accuracy, speed: speed, speedAccuracy: 0.3, course: 0)
    }

    static func input(_ now: Date, trip: UUID = trip, distance: Double = 12_404, fixAge: Double = 1,
                      units: UnitSystem = .metric) -> LiveActivityInput {
        LiveActivityInput(tripId: trip, startedAt: t0, distance: distance, lastFix: fix(at: now.addingTimeInterval(-fixAge)),
                          roadType: "Stadt", limit: SpeedLimit(value: 35, unit: .mph), units: units)
    }

    // MARK: State builder

    @Test func theStateRoundsAndMapsTheStatus() {
        let now = Self.t0.addingTimeInterval(1380)
        let s = LiveActivityState.content(Self.input(now), now: now)
        #expect(s.status == .recording)
        #expect(s.distanceMeters == 12_400)
        #expect(s.speedMps == 13.4)
        #expect(s.accuracyMeters == 4)
        #expect(s.limit == State.Limit(value: 35, mph: true))
        #expect(s.metric && s.roadType == "Stadt" && s.endedAt == nil)

        var gap = Self.input(now, fixAge: 6)
        #expect(LiveActivityState.content(gap, now: now).status == .gap)
        #expect(LiveActivityState.content(gap, now: now).speedMps == nil, "no speed from an old fix")
        gap.lastFix = nil
        #expect(LiveActivityState.content(gap, now: now).status == .gap)
        var poor = Self.input(now)
        poor.poorAccuracy = true
        #expect(LiveActivityState.content(poor, now: now).status == .poorAccuracy)
        poor.pausedForAccess = true
        #expect(LiveActivityState.content(poor, now: now).status == .paused, "a pause outranks the accuracy")
        #expect(!LiveActivityState.content(Self.input(now, units: .imperial), now: now).metric)
    }

    @Test func theFinalStateCarriesTheEndAndNoSpeed() {
        let end = Self.t0.addingTimeInterval(23 * 60 + 40)
        let s = LiveActivityState.final(Self.input(end), endedAt: end)
        #expect(s.status == .ended && s.endedAt == end && s.speedMps == nil && s.limit == nil)
        #expect(SpurActivityText.ended(s, startedAt: Self.t0) == "Fahrt beendet · 12,4 km · 23 min")
        var long = s
        long.endedAt = Self.t0.addingTimeInterval(2 * 3600 + 5 * 60)
        long.distanceMeters = 170_000
        long.metric = false
        #expect(SpurActivityText.ended(long, startedAt: Self.t0) == "Fahrt beendet · 106 mi · 2 h 05 min")
    }

    @Test func updatesAreThrottledExceptOnAStateChange() {
        let now = Self.t0.addingTimeInterval(600)
        let a = LiveActivityState.content(Self.input(now), now: now)
        #expect(LiveActivityState.shouldUpdate(last: nil, sentAt: nil, next: a, now: now))
        var b = a
        b.distanceMeters += 50
        #expect(!LiveActivityState.shouldUpdate(last: a, sentAt: now, next: b, now: now.addingTimeInterval(9.9)))
        #expect(LiveActivityState.shouldUpdate(last: a, sentAt: now, next: b, now: now.addingTimeInterval(10)))
        // A status change goes out at once; a limit or road type change waits 2.5 s (no flicker).
        var gap = a
        gap.status = .gap
        #expect(LiveActivityState.shouldUpdate(last: a, sentAt: now, next: gap, now: now.addingTimeInterval(0.5)))
        for change in [{ (s: inout State) in s.limit = nil }, { $0.roadType = "Autobahn" }] {
            var c = a
            change(&c)
            #expect(!LiveActivityState.shouldUpdate(last: a, sentAt: now, next: c, now: now.addingTimeInterval(1)))
            #expect(LiveActivityState.shouldUpdate(last: a, sentAt: now, next: c, now: now.addingTimeInterval(2.5)))
        }
        #expect(LiveActivityState.staleDate(now) == now.addingTimeInterval(120))
    }

    // MARK: Text

    @Test func theTextFollowsTheAppsFormat() {
        for meters in [0.0, 4.9, 999, 1004, 9_994, 9_996, 12_404, 99_949, 99_951, 123_456] {
            for units in UnitSystem.allCases {
                #expect(SpurActivityText.distance(meters, metric: units == .metric) == Format.distance(meters, units), "\(meters) \(units)")
            }
        }
        for mps in [nil, 0, 0.13, 13.4, 31.29] as [Double?] {
            for units in UnitSystem.allCases {
                #expect(SpurActivityText.speed(mps, metric: units == .metric) == Format.speed(mps, units))
            }
        }
        for seconds in [0.0, 59.9, 60, 844, 3599, 3600, 3780, 30_000] {
            #expect(SpurActivityText.duration(seconds) == Format.duration(seconds))
        }
        #expect(SpurActivityText.accuracy(4.4) == "± 4 m" && SpurActivityText.accuracy(nil) == "GPS")
        #expect([5.0, 5.1, 15, 15.1, nil].map(SpurActivityText.quality) == [.good, .fair, .fair, .poor, .none])
        var s = LiveActivityState.content(Self.input(Self.t0), now: Self.t0)
        #expect(SpurActivityText.status(s, stale: false) == nil)
        #expect(SpurActivityText.status(s, stale: true) == "Keine Aktualisierung")
        s.status = .gap
        #expect(SpurActivityText.status(s, stale: false) == "Kein GPS-Signal")
        s.status = .ended
        #expect(SpurActivityText.status(s, stale: true) == nil, "an ended activity is not stale news")
    }

    // MARK: Controller

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "spur-la-\(UUID().uuidString)")! }

    final class FakeAPI: LiveActivityAPI {
        var isEnabled = true
        var activities: [(id: String, tripId: UUID, live: Bool)] = []
        var requests: [(SpurActivityAttributes, State, Date)] = []
        var updates: [(String, State, Date)] = []
        var ends: [(String, State?, Date?)] = []
        var failRequests = false
        var requestAttempts = 0
        /// Calls in the order they finished.
        var log: [String] = []
        var updateDelay: Duration?

        func running() -> [(id: String, tripId: UUID)] { activities.filter(\.live).map { ($0.id, $0.tripId) } }
        func isLive(_ id: String) -> Bool { activities.contains { $0.id == id && $0.live } }
        func request(_ attributes: SpurActivityAttributes, state: State, staleDate: Date) throws -> String {
            requestAttempts += 1
            if failRequests { throw CancellationError() }
            requests.append((attributes, state, staleDate))
            let id = "A\(requests.count)"
            activities.append((id, attributes.tripId, true))
            return id
        }
        func update(_ id: String, state: State, staleDate: Date) async {
            if let updateDelay { try? await Task.sleep(for: updateDelay) }
            updates.append((id, state, staleDate))
            log.append("update")
        }
        func end(_ id: String, state: State?, dismissal: Date?) async {
            ends.append((id, state, dismissal))
            log.append("end")
            if let k = activities.firstIndex(where: { $0.id == id }) { activities[k].live = false }
        }
    }

    @Test func itStartsOnlyInTheForegroundAndAfterTheLaunchCheck() async {
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        let now = Self.t0.addingTimeInterval(60)
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.requests.isEmpty, "nothing before launch looked for an activity to reattach to")
        await c.launch(recordingTripId: Self.trip)
        await c.refresh(Self.input(now), foreground: false, now: now)
        #expect(api.requests.isEmpty, "never requested from the background")
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.requests.count == 1)
        #expect(api.requests[0].0.tripId == Self.trip && api.requests[0].0.startedAt == Self.t0)
        #expect(api.requests[0].2 == now.addingTimeInterval(120))
        // Throttled: a second later nothing is sent, ten seconds later an update with a new stale date.
        await c.refresh(Self.input(now.addingTimeInterval(1)), foreground: false, now: now.addingTimeInterval(1))
        #expect(api.updates.isEmpty)
        let later = now.addingTimeInterval(10)
        await c.refresh(Self.input(later), foreground: false, now: later)
        #expect(api.updates.count == 1 && api.updates[0].0 == "A1" && api.updates[0].2 == later.addingTimeInterval(120))
        #expect(api.requests.count == 1, "updates run from the background too, no second request")
        // A gap is a state change: sent at once.
        await c.refresh(Self.input(later.addingTimeInterval(1), fixAge: 7), foreground: false, now: later.addingTimeInterval(1))
        #expect(api.updates.count == 2 && api.updates[1].1.status == .gap)
    }

    @Test func aLaunchReattachesToTheRecordingTripAndEndsOrphans() async {
        let api = FakeAPI()
        api.activities = [("old", UUID(), true), ("mine", Self.trip, true), ("done", UUID(), false)]
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: Self.trip)
        #expect(c.current?.id == "mine")
        #expect(api.ends.map(\.0) == ["old"] && api.ends[0].1 == nil && api.ends[0].2 == nil, "orphans end at once")
        let now = Self.t0.addingTimeInterval(30)
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.requests.isEmpty && api.updates.map(\.0) == ["mine"], "reattached, not started twice")

        let none = FakeAPI()
        none.activities = [("stray", Self.trip, true)]
        let d = LiveActivityController(api: none, enabled: { true }, defaults: Self.defaults())
        await d.launch(recordingTripId: nil)
        #expect(none.ends.map(\.0) == ["stray"] && d.current == nil, "a trip that no longer records leaves no activity")
    }

    @Test func aStopEndsWithTheFinalStateOrAtOnce() async {
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(23 * 60)
        await c.refresh(Self.input(now), foreground: true, now: now)
        await c.stop(Self.input(now), kept: true, now: now)
        #expect(api.ends.count == 1 && api.ends[0].0 == "A1")
        #expect(api.ends[0].1?.status == .ended && api.ends[0].1?.endedAt == now)
        #expect(api.ends[0].2 == now.addingTimeInterval(300), "removed after 5 minutes")
        #expect(c.current == nil)

        // A late refresh of the stopped trip (the ticker, a fix still in flight) starts nothing.
        await c.refresh(Self.input(now.addingTimeInterval(1)), foreground: true, now: now.addingTimeInterval(1))
        #expect(api.requests.count == 1, "no second activity for the stopped trip")

        await c.refresh(Self.input(now, trip: UUID()), foreground: true, now: now)
        await c.stop(nil, kept: false, now: now)
        #expect(api.ends.count == 2 && api.ends[1].1 == nil && api.ends[1].2 == nil, "a discarded trip ends at once")
    }

    @Test func theSettingAndTheSystemSwitchAreObeyedSilently() async {
        let api = FakeAPI()
        var on = true
        let c = LiveActivityController(api: api, enabled: { on }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(100)
        await c.refresh(Self.input(now), foreground: true, now: now)
        on = false
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.ends.map(\.0) == ["A1"] && api.ends[0].2 == nil, "turning the setting off ends it at once")
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.requests.count == 1, "nothing starts while off")
        on = true
        await c.refresh(Self.input(now), foreground: true, now: now)
        #expect(api.requests.count == 2, "on again in the foreground: a new one")

        let off = FakeAPI()
        off.isEnabled = false
        let d = LiveActivityController(api: off, enabled: { true }, defaults: Self.defaults())
        await d.launch(recordingTripId: nil)
        await d.refresh(Self.input(now), foreground: true, now: now)
        #expect(off.requests.isEmpty && off.ends.isEmpty, "Live Activities off in iOS: nothing, no error")

        let failing = FakeAPI()
        failing.failRequests = true
        let e = LiveActivityController(api: failing, enabled: { true }, defaults: Self.defaults())
        await e.launch(recordingTripId: nil)
        await e.refresh(Self.input(now), foreground: true, now: now)
        #expect(e.current == nil, "a refused request is silent")
    }

    @Test func anActivityTheSystemEndedIsNotRestartedForThatTrip() async {
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(8 * 3600)
        await c.refresh(Self.input(now), foreground: true, now: now)
        api.activities[0].live = false // the 8 hour cap, or swiped away
        await c.refresh(Self.input(now.addingTimeInterval(20)), foreground: true, now: now.addingTimeInterval(20))
        await c.refresh(Self.input(now.addingTimeInterval(40)), foreground: true, now: now.addingTimeInterval(40))
        #expect(api.requests.count == 1 && c.givenUp == Self.trip, "not fought")
        await c.stop(Self.input(now), kept: true, now: now)
        await c.refresh(Self.input(now, trip: UUID()), foreground: true, now: now)
        #expect(api.requests.count == 2, "the next trip gets its own")
    }

    // MARK: Live Activity review

    @Test func aStopRacingTheTickerAndALateFixNeverRequestsAgain() async throws {
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        var recording: LiveActivityInput? = Self.input(Date())
        let driver = LiveActivityDriver(controller: c, tick: .milliseconds(20), input: { recording.map { var i = $0; i.lastFix = Self.fix(at: Date()); return i } },
                                        foreground: { true })
        var lives: [Bool] = []
        driver.onLiveChanged = { lives.append($0) }
        await driver.launch(recordingTripId: nil)
        driver.tripStarted()
        try await Task.sleep(for: .milliseconds(70))
        #expect(api.requests.count == 1)
        // The stop as the app wires it, with the ticker due and a fix still in flight: the input
        // even still reports the trip (the worst case).
        driver.tripStopped(recording, kept: true)
        driver.refresh()
        try await Task.sleep(for: .milliseconds(120))
        recording = nil
        #expect(api.requests.count == 1, "no second activity after the stop")
        #expect(api.ends.count == 1 && api.ends[0].1?.status == .ended)
        #expect(api.log.last == "end", "the end goes last")
        #expect(lives.last == false)
    }

    @Test func aGiveUpSurvivesARelaunchOfTheSameTrip() async {
        let defaults = Self.defaults()
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: defaults)
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(100)
        await c.refresh(Self.input(now), foreground: true, now: now)
        api.activities[0].live = false // swiped away
        await c.refresh(Self.input(now.addingTimeInterval(20)), foreground: true, now: now.addingTimeInterval(20))
        #expect(c.givenUp == Self.trip)
        // Spur is relaunched while the same trip records.
        let again = LiveActivityController(api: api, enabled: { true }, defaults: defaults)
        await again.launch(recordingTripId: Self.trip)
        await again.refresh(Self.input(now.addingTimeInterval(40)), foreground: true, activation: true, now: now.addingTimeInterval(40))
        #expect(api.requests.count == 1, "still left alone after the relaunch")
        // A later trip is not affected.
        let next = LiveActivityController(api: api, enabled: { true }, defaults: defaults)
        await next.launch(recordingTripId: UUID())
        #expect(next.givenUp == nil)
    }

    @Test func noTripOrTheSettingOffEndsALiveActivity() async {
        let api = FakeAPI()
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(100)
        await c.refresh(Self.input(now), foreground: true, now: now)
        await c.refresh(nil, foreground: true, now: now)
        #expect(api.ends.count == 1 && c.current == nil, "nothing records: the activity ends")
    }

    @Test func aRefusedRequestBacksOff() async {
        let api = FakeAPI()
        api.failRequests = true
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(100)
        for k in 0..<30 { await c.refresh(Self.input(now.addingTimeInterval(Double(k))), foreground: true, now: now.addingTimeInterval(Double(k))) }
        #expect(api.requestAttempts == 1, "not once per fix")
        await c.refresh(Self.input(now.addingTimeInterval(31)), foreground: true, activation: true, now: now.addingTimeInterval(31))
        #expect(api.requestAttempts == 2, "a scene activation retries")
        await c.refresh(Self.input(now.addingTimeInterval(92)), foreground: true, now: now.addingTimeInterval(92))
        #expect(api.requestAttempts == 3, "and so does a minute")
    }

    @Test func theAccuracyFollowsTheTenSecondFreshnessRule() {
        let now = Self.t0.addingTimeInterval(500)
        #expect(LiveActivityState.content(Self.input(now, fixAge: 6), now: now).accuracyMeters == 4)
        let old = LiveActivityState.content(Self.input(now, fixAge: 11), now: now)
        #expect(old.status == .gap && old.accuracyMeters == nil, "no green ± 4 m next to Kein GPS-Signal")
        #expect(LiveActivityState.content(Self.input(now), now: now).updatedAt == now)
    }

    @Test func updatesAndTheEndRunInOrder() async {
        let api = FakeAPI()
        api.updateDelay = .milliseconds(40)
        let c = LiveActivityController(api: api, enabled: { true }, defaults: Self.defaults())
        await c.launch(recordingTripId: nil)
        let now = Self.t0.addingTimeInterval(100)
        await c.refresh(Self.input(now), foreground: true, now: now)
        let later = now.addingTimeInterval(10)
        // The update is on its way (40 ms) when the stop arrives.
        let update = Task { await c.refresh(Self.input(later), foreground: false, now: later) }
        try? await Task.sleep(for: .milliseconds(5))
        await c.stop(Self.input(later), kept: true, now: later.addingTimeInterval(1))
        await update.value
        #expect(api.log == ["update", "end"], "the slow update finishes before the end starts")
    }

    @Test func theLocationPillGoesOnlyWhileAnActivityIsLiveWithAlways() {
        let always = EngineTests.rig(status: .authorizedAlways)
        #expect(always.manager.showsBackgroundLocationIndicator)
        always.engine.setLiveActivityShown(true)
        #expect(!always.manager.showsBackgroundLocationIndicator)
        always.engine.setLiveActivityShown(false)
        #expect(always.manager.showsBackgroundLocationIndicator)

        let whenInUse = EngineTests.rig(status: .authorizedWhenInUse)
        whenInUse.engine.setLiveActivityShown(true)
        #expect(whenInUse.manager.showsBackgroundLocationIndicator, "under When In Use the pill stays")
        whenInUse.engine.authorizationChanged(.authorizedAlways, .fullAccuracy)
        #expect(!whenInUse.manager.showsBackgroundLocationIndicator, "granted Always while live: the pill goes")
    }
}
