import Foundation
import Testing
@testable import Spur

/// SPEC 17.4: the live estimator's data path.
struct LiveMotionFeedTests {
    typealias Suite = MotionPhysicsSuiteTests

    nonisolated final class Received: @unchecked Sendable {
        let lock = NSLock()
        var readings: [LiveMotionEstimator.Reading] = []
        var snapshots: [LiveMotionSnapshot] = []
        var actives: [Bool] = []
    }

    /// Streams a drive as the app does: 1 s batches into `motion.bin` (the writer) and the feed,
    /// fixes as they come; `activeFrom` (seconds from the start) turns the feed on.
    static func stream(_ sc: Suite.Scenario, activeFrom: Double, batch: Double = 1) throws -> (LiveMotionFeed, Received) {
        let url = Fixtures.tempDir().appendingPathComponent("motion.bin")
        let writer = try MotionFileWriter(url: url, rateHz: 100)
        let feed = LiveMotionFeed()
        let got = Received()
        feed.onReading = { r in got.lock.withLock { got.readings.append(r) } }
        feed.onSnapshot = { s in got.lock.withLock { got.snapshots.append(s) } }
        feed.onActiveChanged = { on in got.lock.withLock { got.actives.append(on) } }
        feed.begin(url: url, fixes: [])
        let t0 = sc.samples[0].time
        var nextFix = 0
        var i = 0
        var activated = false
        while i < sc.samples.count {
            var j = i
            while j < sc.samples.count && sc.samples[j].time - sc.samples[i].time < batch { j += 1 }
            let b = Array(sc.samples[i..<j])
            try writer.append(b)
            feed.ingest(b)
            while nextFix < sc.fixes.count && sc.fixes[nextFix].time <= b.last!.time {
                feed.ingest(fix: sc.fixes[nextFix])
                nextFix += 1
            }
            if !activated && b.last!.time - t0 >= activeFrom {
                activated = true
                feed.setActive(true)
            }
            feed.drain()
            i = j
        }
        writer.close()
        return (feed, got)
    }

    @Test func nothingIsRefreshedOrPublishedWhileInactive() throws {
        let sc = Suite.build(Suite.standard())
        let (feed, got) = try Self.stream(sc, activeFrom: .infinity)
        #expect(feed.refreshes == 0)
        #expect(feed.samples == sc.samples.count, "it still senses every sample")
        #expect(got.readings.isEmpty && got.snapshots.isEmpty && got.actives.isEmpty)
    }

    @Test func activeItRefreshesFromTheFileAndPublishesAtItsRates() throws {
        let sc = Suite.build(Suite.standard())
        let (feed, got) = try Self.stream(sc, activeFrom: 20, batch: 0.1)
        #expect(got.actives == [true])
        #expect(got.snapshots.first?.computing == true, "opening shows wird berechnet first")
        #expect(got.snapshots.dropFirst().allSatisfy { !$0.computing })
        #expect(feed.refreshes >= 5)
        let readings = got.readings, snapshots = got.snapshots
        #expect(readings.count > 100)
        for (a, b) in zip(readings, readings.dropFirst()) { #expect(b.time - a.time >= LiveMotionFeed.readingInterval - 1e-6) }
        let computed = snapshots.filter { !$0.computing }
        for (a, b) in zip(computed, computed.dropFirst()) { #expect(b.time - a.time >= LiveMotionFeed.snapshotInterval - 1e-6) }
        // The last snapshot carries the analysis of the drive so far: the final 6 m/s² stop.
        let last = try #require(snapshots.last?.summary)
        #expect(last.isAligned && (last.maxBraking ?? 0) < -5 && last.counts.hardBraking == 1)
        #expect(snapshots.last?.chart.contains { $0.long < -5 && $0.age <= 60 } == true)
    }

    /// The gates keep sensing while nobody looks: a swivel before the panel opens is not shown in
    /// the old orientation after it opens.
    @Test func aSwivelWhileInactiveIsRememberedWhenThePanelOpens() throws {
        let d = LiveMotionTests.drives().first { $0.name == "swivel 45 in 1.5 s" }!
        let noRemount = Suite.standard(remount: [])
        let tMid = Suite.dur(Array(noRemount[..<(noRemount.firstIndex { $0.bump }! + 2)]))
        // The panel opens only 2 s after the swivel: nothing was refreshed before it.
        let sc = d.scenario
        let (_, got) = try Self.stream(sc, activeFrom: tMid + 2)
        let time = sc.samples.map(\.time)
        let truLong = MotionAnalyzer.smooth(sc.truthLong.map { Float($0) }, time: time)
        var wrong = 0
        for r in got.readings {
            guard let l = r.long else { continue }
            let k = LiveMotionTests.index(time, r.time - 0.125)
            if abs(l) >= 0.3 && abs(truLong[k]) >= 0.3 && (l > 0) != (truLong[k] > 0) { wrong += 1 }
            #expect(abs(l - Double(truLong[k])) < 0.6, "at \(r.time - time[0]) s: \(l) against \(truLong[k])")
        }
        #expect(wrong == 0)
    }

    /// The recorder forks every batch to the feed after queueing the write; short batches follow
    /// the panel.
    @Test @MainActor func theRecorderForksEveryBatchToTheFeed() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let defaults = UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!
        let source = BatchRecordingSource()
        let settings = Settings(defaults: defaults)
        settings.geocodingEnabled = false
        settings.keepScreenAwake = false
        settings.recordMotion = true
        let engine = RecordingEngine(store: store, settings: settings, manager: FakeLocationManager(status: .authorizedWhenInUse, accuracy: .fullAccuracy),
                                     makeSession: { FakeSession() }, defaults: defaults, makeMotionSource: { source })
        engine.requestStart()
        source.emit(250)
        engine.liveMotion.drain()
        #expect(engine.motion.samplesWritten == 250)
        #expect(engine.liveMotion.samples == 250)
        engine.liveMotion.setActive(true)
        engine.liveMotion.drain()
        #expect(source.batchSeconds == 0.1)
        engine.liveMotion.setActive(false)
        engine.liveMotion.drain()
        #expect(source.batchSeconds == 1)
        // Opening and closing the panel (feed on and off, batch length switched)
        // between batches loses no sample, neither in motion.bin nor in the feed.
        for k in 0..<6 {
            engine.liveMotion.setActive(k % 2 == 0)
            source.emit(37)
        }
        engine.liveMotion.setActive(false)
        engine.liveMotion.drain()
        #expect(engine.motion.samplesWritten == 250 + 6 * 37)
        #expect(engine.liveMotion.samples == 250 + 6 * 37)
        let id = try #require(engine.trip?.id)
        engine.stop()
        #expect(MotionFile.read(store.motionURL(id))?.samples.count == 250 + 6 * 37)
    }
}

extension LiveMotionFeedTests {
    /// Review round 3, R1: a refresh runs off the ingest queue, so the dot keeps moving while a
    /// slow one (2 s here, as a long trip on a phone) is in flight, and what arrived meanwhile is
    /// carried onto its result.
    @Test func theDotKeepsMovingDuringASlowRefresh() throws {
        let sc = Suite.build(Suite.standard())
        let url = Fixtures.tempDir().appendingPathComponent("motion.bin")
        let writer = try MotionFileWriter(url: url, rateHz: 100)
        let feed = LiveMotionFeed()
        let got = Received()
        feed.onReading = { r in got.lock.withLock { got.readings.append(r) } }
        feed.onSnapshot = { s in got.lock.withLock { got.snapshots.append(s) } }
        feed.begin(url: url, fixes: [])
        let t0 = sc.samples[0].time
        var nextFix = 0
        var i = 0
        func feedUntil(_ seconds: Double) throws {
            while i < sc.samples.count && sc.samples[i].time - t0 < seconds {
                var j = i
                while j < sc.samples.count && sc.samples[j].time - sc.samples[i].time < 0.1 { j += 1 }
                let b = Array(sc.samples[i..<j])
                try writer.append(b)
                feed.ingest(b)
                while nextFix < sc.fixes.count && sc.fixes[nextFix].time <= b.last!.time {
                    feed.ingest(fix: sc.fixes[nextFix])
                    nextFix += 1
                }
                feed.flush()
                i = j
            }
        }
        try feedUntil(60)
        feed.refreshDelayForTesting = 2
        feed.setActive(true)
        feed.flush()
        let start = Date()
        let before = got.lock.withLock { got.readings.count }
        try feedUntil(70)
        let during = got.lock.withLock { got.readings.count } - before
        #expect(feed.isRefreshing, "the refresh is still in flight")
        #expect(during >= 50, "\(during) readings while it ran")
        #expect(Date().timeIntervalSince(start) < 1.5, "ingesting never waited for the refresh")
        feed.drain()
        #expect(!feed.isRefreshing && feed.refreshes == 1)
        // After the hand-over the estimator has every sample: its reading is the newest.
        let last = got.lock.withLock { got.readings.last }
        #expect(abs((last?.time ?? 0) - sc.samples[i - 1].time) < 0.2)
        #expect(got.lock.withLock { got.snapshots.last?.summary } != nil)
        writer.close()
    }
}

/// `ScriptedMotionSource` that also records the batch length asked for.
nonisolated final class BatchRecordingSource: MotionSource, @unchecked Sendable {
    let inner = ScriptedMotionSource()
    private let lock = NSLock()
    private var seconds = 1.0
    var batchSeconds: Double { lock.withLock { seconds } }
    var isAvailable: Bool { true }
    func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) { inner.start(rateHz: rateHz, deliver: deliver) }
    func stop() { inner.stop() }
    func setBatchSeconds(_ s: Double) { lock.withLock { seconds = s } }
    func emit(_ n: Int) { inner.emit(n) }
}
