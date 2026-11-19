import Foundation
import Testing
@testable import Spur

/// SPEC 18.9: the manual pause.
struct PauseTests {
    typealias Rig = EngineTests

    static func fixes(_ count: Int, after seconds: Double, speed: Double = 15) -> [Fix] {
        let start = Int64(Date().timeIntervalSince1970 * 1000) + Int64(seconds * 1000)
        return Fixtures.northbound(speeds: Array(repeating: speed, count: count), startMs: start)
    }

    @Test func aManualPauseWritesNothingAndResumesOnlyByHand() throws {
        let r = Rig.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        r.engine.handle(Self.fixes(10, after: 0))
        let before = try Data(contentsOf: r.store.fixesURL(id))
        let count = r.engine.fixes.count
        #expect(r.engine.pauseTrip())
        #expect(r.engine.isPaused)
        #expect(!r.engine.pauseTrip(), "a second pause does nothing")
        // Driving during the pause: nothing written, and after 30 s at 5 m/s or more the hint.
        r.engine.handle(Self.fixes(40, after: 20, speed: 12))
        #expect(r.engine.fixes.count == count)
        #expect(try Data(contentsOf: r.store.fixesURL(id)) == before, "the fix file is byte-identical during the pause")
        #expect(r.engine.drivingWhilePaused)
        #expect(r.engine.isPaused, "never resumes by itself")
        // Standing again clears the hint.
        r.engine.handle(Self.fixes(3, after: 70, speed: 0))
        #expect(!r.engine.drivingWhilePaused)
        // Fortsetzen: the next fixes are written, the gap is a pause, the pause has its end.
        #expect(r.engine.resumeTrip())
        r.engine.handle(Self.fixes(5, after: 120))
        #expect(r.engine.fixes.count == count + 5)
        let stored = try r.store.load(id)
        #expect(stored.pauses?.count == 1 && stored.pauses?.first?.end != nil && stored.pauses?.first?.kind == .manual)
        #expect(r.engine.trip?.gaps.last?.reason == .pause)
    }

    @Test func stoppingWhilePausedEndsThePause() async throws {
        let r = Rig.rig()
        r.engine.requestStart()
        let id = r.engine.trip!.id
        r.engine.handle(Self.fixes(10, after: 0))
        #expect(r.engine.pauseTrip())
        r.engine.stop()
        try await Rig.waitUntilIdle(r.engine)
        let stored = try r.store.load(id)
        #expect(stored.pauses?.count == 1)
        #expect(stored.openPause == nil)
        #expect(stored.pauseSeconds() >= 0)
        #expect(!r.engine.drivingWhilePaused)
    }

    @Test func theLiveActivitySaysPaused() {
        let input = LiveActivityInput(tripId: UUID(), startedAt: Date(), distance: 1000, lastFix: nil, userPaused: true)
        #expect(LiveActivityState.content(input, now: Date()).status == .userPaused)
        var driving = input
        driving.drivingWhilePaused = true
        #expect(LiveActivityState.content(driving, now: Date()).status == .pausedDriving)
        #expect(SpurActivityText.status(LiveActivityState.content(driving, now: Date()), stale: false) == "Pausiert, du fährst: in Spur fortsetzen")
    }

    @Test func pauseTimeCountsOnlyThePauses() {
        var r = TripRecord(startedAt: Date(timeIntervalSince1970: 1_000), isRecording: false)
        r.endedAt = Date(timeIntervalSince1970: 5_000)
        r.pauses = [TripPause(start: Date(timeIntervalSince1970: 2_000), end: Date(timeIntervalSince1970: 2_600), kind: .manual),
                    TripPause(start: Date(timeIntervalSince1970: 4_000), end: nil, kind: .manual)]
        #expect(r.pauseSeconds() == 600 + 1_000, "an open pause runs to the end of the trip")
        TripLifecycle.closePause(&r, at: Date(timeIntervalSince1970: 4_500))
        #expect(r.openPause == nil && r.pauseSeconds() == 1_100)
    }
}

/// SPEC 18.9 part 2b: the automatic pause through the real engine (location only since 2026-11-17).
struct AutoPauseEngineTests {
    typealias Rig = EngineTests

    static func fixes(_ speeds: [Double], from seconds: Double, base: Int64) -> [Fix] {
        Fixtures.northbound(speeds: speeds, startMs: base + Int64(seconds * 1000))
    }

    @Test func aBreakPausesFromTheStopAndTheCarResumesIt() throws {
        let r = Rig.rig()
        r.engine.settings.autoPauseMinutes = 3
        r.engine.requestStart()
        let id = r.engine.trip!.id
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        // A car park: off every road.
        r.engine.placeOverride = .offRoad
        r.engine.handle(Self.fixes(Array(repeating: 12, count: 60), from: 0, base: base))
        // Parked: a break of 5 min.
        for k in 0..<300 { r.engine.handle(Self.fixes([0.3], from: 60 + Double(k), base: base)) }
        #expect(r.engine.isAutoPaused, "a stop of 3 min or more off the road is a break")
        let paused = try #require(r.engine.trip?.openPause)
        #expect(paused.kind == .auto && paused.evidence == "abseits der Straße")
        #expect(abs(paused.start.timeIntervalSince1970 - (Double(base) / 1000 + 60)) <= 2, "from the stop's start")
        let during = r.engine.fixes.count
        #expect(during >= 60 + 300, "an automatic pause keeps writing fixes")
        // Back in the car and away.
        r.engine.handle(Self.fixes(Array(repeating: 12, count: 30), from: 360, base: base))
        #expect(!r.engine.isAutoPaused)
        let stored = try r.store.load(id)
        let p = try #require(stored.pauses?.first)
        #expect(p.end != nil && abs(p.end!.timeIntervalSince1970 - (Double(base) / 1000 + 360)) <= 2, "until the movement's start")
        // The pause counts in neither driving nor stop time.
        let all = r.engine.fixes
        let with = TripAnalyzer.analyze(fixes: all, pauses: stored.pauses ?? []).statistics.time
        let without = TripAnalyzer.analyze(fixes: all).statistics.time
        #expect(without.stoppedTime - with.stoppedTime >= 290)
    }

    @Test func aLongStopOnAMajorRoadNeverPauses() {
        let r = Rig.rig()
        r.engine.settings.autoPauseMinutes = 3
        r.engine.requestStart()
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        r.engine.placeOverride = .majorRoad
        r.engine.handle(Self.fixes(Array(repeating: 12, count: 30), from: 0, base: base))
        for k in 0..<900 { r.engine.handle(Self.fixes([0.2], from: 30 + Double(k), base: base)) }
        #expect(!r.engine.isAutoPaused)
        #expect(r.engine.trip?.pauses == nil)
    }

    /// The place is looked up once per stop through the app's lookup and reaches the detector.
    @MainActor
    @Test func thePlaceIsLookedUpOncePerStop() async throws {
        let r = Rig.rig()
        r.engine.settings.autoPauseMinutes = 3
        var asked = 0
        r.engine.placeLookup = { _ in
            asked += 1
            return .minorRoad
        }
        r.engine.requestStart()
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        r.engine.handle(Self.fixes(Array(repeating: 12, count: 30), from: 0, base: base))
        r.engine.handle(Self.fixes([0.2], from: 30, base: base))
        for _ in 0..<20 { await Task.yield() }
        for k in 1..<300 { r.engine.handle(Self.fixes([0.2], from: 30 + Double(k), base: base)) }
        #expect(asked == 1, "one lookup for one stop")
        #expect(r.engine.trip?.openPause?.evidence == "geparkt an einer Nebenstraße")
    }

    @Test func turnedOffNothingPauses() {
        let r = Rig.rig()
        r.engine.settings.autoPause = false
        r.engine.settings.autoPauseMinutes = 3
        r.engine.requestStart()
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        r.engine.placeOverride = .offRoad
        for k in 0..<400 { r.engine.handle(Self.fixes([0.2], from: Double(k), base: base)) }
        #expect(!r.engine.isAutoPaused)
    }
}
