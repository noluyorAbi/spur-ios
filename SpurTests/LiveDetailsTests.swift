import UIKit
import Foundation
import Testing
@testable import Spur

/// SPEC 17.2, 17.8: the running trip's live details.
@MainActor
struct LiveDetailsTests {
    /// The panel's numbers at Stop equal the trip details' numbers: the same analysis on the same
    /// fixes and gaps.
    @Test func thePanelAtStopEqualsTheTripDetails() async throws {
        let r = EngineTests.rig()
        let settings = Settings(defaults: r.defaults)
        let live = LiveTripDetails(engine: r.engine, settings: settings, store: r.store)
        r.engine.requestStart()
        let id = try #require(r.engine.trip?.id)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Two drives with an 8 s gap between them, stops and speed changes.
        let first = Fixtures.northbound(speeds: (0..<90).map { k in k % 30 < 4 ? 0 : 8 + Double(k % 7) }, startMs: now)
        let second = Fixtures.northbound(speeds: (0..<60).map { _ in 14 }, startMs: (first.last?.timestampMs ?? now) + 8000, lat: first.last!.latitude + 0.0005)
        r.engine.handle(first)
        r.engine.handle(second)
        _ = r.engine.addEvent(.hazard)
        live.viewerAppeared()
        await live.refreshNow()
        let shown = try #require(live.detail?.analysis?.statistics)
        #expect(live.runningTripId == id)
        r.engine.stop()
        try await EngineTests.waitUntilIdle(r.engine)
        live.viewerDisappeared()
        let record = try #require(try? r.store.load(id))
        let details = TripDetailModel(record: record)
        await details.load(store: r.store, config: settings.statsConfig, units: settings.units)
        let final = try #require(details.analysis?.statistics)
        #expect(shown == final)
        #expect(final.gps.gapCount == 1 && final.distance > 0)
        #expect(live.detail?.events.count == details.events.count)
    }

    /// Locked or in the background with the panel open, nothing runs (SPEC 17.4): neither the
    /// statistics loop nor the motion feed's refreshes. Back in front both resume.
    @Test func nothingRunsWhileTheAppIsNotInFront() throws {
        let r = EngineTests.rig()
        let live = LiveTripDetails(engine: r.engine, settings: Settings(defaults: r.defaults), store: r.store)
        r.engine.requestStart()
        live.viewerAppeared()
        r.engine.liveMotion.drain()
        #expect(live.isRefreshing)
        live.setInFront(false)
        r.engine.liveMotion.drain()
        #expect(!live.isRefreshing)
        #expect(!r.engine.liveMotion.isActive)
        live.setInFront(true)
        r.engine.liveMotion.drain()
        #expect(live.isRefreshing)
        live.viewerDisappeared()
        #expect(!live.isRefreshing)
        r.engine.stop()
    }

    /// The cost of one statistics rebuild at 1 h and 8 h of fixes: the analysis off the main actor,
    /// then the display building on it (printed for the 17.4 numbers; debug build).
    @Test func oneRebuildAtOneAndEightHours() async {
        for hours in [1.0, 8.0] {
            let n = Int(hours * 3600)
            let fixes = Fixtures.northbound(speeds: (0..<n).map { k in k % 120 < 10 ? 0 : 12 + Double(k % 9) })
            var record = TripRecord(startedAt: fixes[0].date)
            record.usableAccuracyLimit = 30
            let config = StatsConfig(usableAccuracy: 30)
            let t0 = Date()
            _ = TripAnalyzer.analyze(fixes: fixes, recordedGaps: [], places: [], config: config)
            let analysis = Date().timeIntervalSince(t0)
            let d = TripDetailModel(record: record)
            let t1 = Date()
            await d.refreshLive(fixes: fixes, events: [], record: record, config: config, units: .metric)
            let total = Date().timeIntervalSince(t1)
            print(String(format: "LIVEDETAILS rebuild %.0f h (%d fixes): analysis %.3f s, total %.3f s, main actor (display) about %.3f s",
                         hours, n, analysis, total, max(0, total - analysis)))
            #expect(d.analysis != nil)
        }
    }

    /// The running trip's title and note go through the engine, so its next save keeps them.
    @Test func renamingTheRunningTripSurvivesTheEnginesSaves() throws {
        let r = EngineTests.rig()
        r.engine.requestStart()
        let id = try #require(r.engine.trip?.id)
        let saved = r.engine.updateRunningTrip { $0.customTitle = "Testfahrt"; $0.note = "Notiz" }
        #expect(saved?.customTitle == "Testfahrt")
        r.engine.handle(EngineTests.freshFixes(5))
        r.engine.stop()
        let record = try #require(try? r.store.load(id))
        #expect(record.customTitle == "Testfahrt" && record.note == "Notiz")
    }
}

/// SPEC 17.5: the trip details say why a trip has no sensor data.
struct MissingMotionReasonTests {
    static func record(_ start: TripRecord.MotionStart?, version: String? = "1.3.0", health: MotionHealth? = nil) -> TripRecord {
        var r = TripRecord(startedAt: Date(), isRecording: false)
        r.motionStart = start
        r.context.appVersion = version
        r.motionHealth = health
        return r
    }

    @Test func everyCauseHasItsOwnText() {
        typealias V = TripDetailView
        #expect(V.missingMotionReason(Self.record(.recording), hasFile: true, analyzing: true) == "Wird ausgewertet.")
        #expect(V.missingMotionReason(Self.record(.off), hasFile: false, analyzing: false).hasPrefix("Bewegungssensor war ausgeschaltet"))
        #expect(V.missingMotionReason(Self.record(nil, version: "1.1.0"), hasFile: false, analyzing: false).hasPrefix("Fahrt vor Version 1.2"))
        #expect(V.missingMotionReason(Self.record(nil, version: nil), hasFile: false, analyzing: false).hasPrefix("Fahrt vor Version 1.2"))
        #expect(V.missingMotionReason(Self.record(.unavailable), hasFile: false, analyzing: false).contains("keinen Bewegungssensor"))
        var failed = MotionHealth()
        failed.openFailed = true
        #expect(V.missingMotionReason(Self.record(.recording, health: failed), hasFile: false, analyzing: false).contains("nicht angelegt"))
        var gaveUp = MotionHealth()
        gaveUp.gaveUp = true
        #expect(V.missingMotionReason(Self.record(.recording, health: gaveUp), hasFile: false, analyzing: false).contains("Speicherfehlern"))
        #expect(V.missingMotionReason(Self.record(.recording), hasFile: false, analyzing: false).contains("Datei fehlt"))
        #expect(V.missingMotionReason(Self.record(nil, version: "1.2.0"), hasFile: false, analyzing: false).contains("Version 1.3"))
        #expect(!V.before12("1.2.0") && V.before12("1.1.9") && !V.before12("2.0"))
    }
}

/// SPEC 18.1: Kartenstil, and Automatisch by the sun with hysteresis.
struct AppearanceRuleTests {
    @Test func automaticFollowsTheSunWithoutFlapping() {
        typealias R = AppearanceRule
        #expect(R.isLight(choice: .light, sunElevation: -30, current: false))
        #expect(!R.isLight(choice: .dark, sunElevation: 40, current: true))
        #expect(R.initial(choice: .automatic, sunElevation: 10) && !R.initial(choice: .automatic, sunElevation: -10))
        #expect(!R.initial(choice: .automatic, sunElevation: nil), "no position: dark, the safe choice at night")
        // Inside the band around the horizon nothing changes, either way.
        #expect(R.isLight(choice: .automatic, sunElevation: -0.833, current: true))
        #expect(!R.isLight(choice: .automatic, sunElevation: -0.833, current: false))
        #expect(R.isLight(choice: .automatic, sunElevation: 0.1, current: false), "past the band at sunrise")
        #expect(!R.isLight(choice: .automatic, sunElevation: -1.7, current: true), "past the band at sunset")
        // A dusk that wobbles inside the band keeps one style.
        var light = true
        for e in [-0.5, -1.2, -0.7, -1.5, -0.9] { light = R.isLight(choice: .automatic, sunElevation: e, current: light) }
        #expect(light)
        #expect(R.isLight(choice: .automatic, sunElevation: nil, current: true))
    }
}

/// MapKit resolves overlay colours on its render thread: the adaptive tokens must resolve off the
/// main actor without trapping (crash found by ui-flow, 2026-11-13), to the right value per style.
struct AdaptiveColorThreadTests {
    @Test func tokensResolveOffTheMainThread() async {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let token = UIColor(Theme.adaptive(light: Theme.rgb(0x112233), dark: Theme.rgb(0xAABBCC)))
        let resolved = await Task.detached { () -> (UIColor, UIColor) in
            (token.resolvedColor(with: light), token.resolvedColor(with: dark))
        }.value
        #expect(resolved.0 == Theme.rgb(0x112233))
        #expect(resolved.1 == Theme.rgb(0xAABBCC))
    }
}
