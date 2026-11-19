import Foundation
import Testing
@testable import Spur

/// 17.4b: in the background the observed live state does not change per fix; the truth keeps
/// going (recording, Live Activity, speed-limit accounting), and the return shows the newest
/// values in one update.
struct DisplayGateTests {
    typealias Rig = EngineTests

    /// Fixes after the first three (10 s later, so the engine takes them as new).
    static func laterFixes(_ count: Int) -> [Fix] {
        let start = Int64(Date().timeIntervalSince1970 * 1000) + 10_000
        return Fixtures.northbound(speeds: Array(repeating: 15, count: count), startMs: start)
    }

    @Test func noMutationsOfTheObservedLiveStateInTheBackground() {
        let r = Rig.rig()
        r.engine.requestStart()
        r.engine.handle(Rig.freshFixes(3))
        r.engine.forcePublishForTesting()
        let shown = r.engine.live
        r.engine.setDisplayActive(false)
        let before = r.engine.displayMutations
        let fixes = Self.laterFixes(40)
        for f in fixes {
            r.engine.handle([f])
            r.engine.forcePublishForTesting()
        }
        #expect(r.engine.displayMutations == before, "N fixes in the background, 0 mutations")
        #expect(r.engine.live == shown)
        #expect(r.engine.current.revision > shown.revision, "the truth kept going")
        #expect(r.engine.current.lastFix?.time == r.engine.fixes.last?.time)

        // Back in front: the newest values in one update.
        r.engine.setDisplayActive(true)
        #expect(r.engine.live == r.engine.current)
        #expect(r.engine.live.lastFix?.time == fixes.last?.time)
        #expect(r.engine.displayMutations - before <= 2, "one assignment of the live state (plus the banner, if it changed)")
    }

    @Test func roadCountersHoldStillInTheBackgroundAndCatchUp() {
        let store = TripStore(root: Fixtures.tempDir())
        let settings = Settings(defaults: UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!)
        let roads = RoadService(store: store, settings: settings, pack: nil,
                                cache: RoadTileCache(directory: Fixtures.tempDir()), client: nil)
        roads.setDisplayActive(false)
        let before = roads.displayMutations
        for k in 1...30 {
            var c = LiveRoadCounts()
            c.limitSeconds = ["50": Double(k)]
            roads.setCurrentCountsForTesting(c)
        }
        #expect(roads.displayMutations == before)
        #expect(roads.counts == LiveRoadCounts())
        #expect(roads.currentCounts.limitSeconds["50"] == 30)
        roads.setDisplayActive(true)
        #expect(roads.counts.limitSeconds["50"] == 30)
        #expect(roads.displayMutations == before + 1)
    }

    /// The Live Activity's input comes from the truth, so it keeps updating in the background.
    @Test func theLiveActivityKeepsUpdatingInTheBackground() {
        let r = Rig.rig()
        let roads = RoadService(store: r.store, settings: r.engine.settings, pack: nil,
                                cache: RoadTileCache(directory: Fixtures.tempDir()), client: nil)
        r.engine.requestStart()
        r.engine.handle(Rig.freshFixes(3))
        r.engine.forcePublishForTesting()
        r.engine.setDisplayActive(false)
        roads.setDisplayActive(false)
        let first = AppModel.activityInput(engine: r.engine, roads: roads, settings: r.engine.settings, now: Date())
        r.engine.handle(Self.laterFixes(30))
        r.engine.forcePublishForTesting()
        let later = AppModel.activityInput(engine: r.engine, roads: roads, settings: r.engine.settings, now: Date())
        #expect(first != nil && later != nil)
        #expect((later?.distance ?? 0) > (first?.distance ?? 0), "distance grows while the display holds still")
        #expect(later?.lastFix?.time == r.engine.fixes.last?.time)
    }
}
