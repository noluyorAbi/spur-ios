import Foundation
import Testing
@testable import Spur

struct TripLifecycleTests {
    /// Creates a recording trip with `count` fixes, the newest one at `lastFixAt`.
    static func recordingTrip(in store: TripStore, lastFixAt: Date, count: Int = 30) throws -> TripRecord {
        let lastMs = Int64(lastFixAt.timeIntervalSince1970 * 1000)
        let startMs = lastMs - Int64(count - 1) * 1000
        let fixes = Fixtures.northbound(speeds: Array(repeating: 15, count: count), startMs: startMs)
        let record = TripRecord(startedAt: Date(timeIntervalSince1970: Double(startMs) / 1000), isRecording: true)
        try store.create(record)
        let writer = try store.openWriter(record.id)
        for f in fixes { try writer.append(f) }
        writer.close()
        return record
    }

    let now = Date(timeIntervalSince1970: 1_794_430_000)

    // MARK: Rule 1: stop saves the finished state before the statistics

    @Test func endedRecordIsFinishedWithoutStatistics() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let running = try Self.recordingTrip(in: store, lastFixAt: now)
        // stop(): first save, then the app is killed before the statistics are written.
        try store.save(TripLifecycle.ended(running, at: now))
        let onDisk = try store.load(running.id)
        #expect(onDisk.isRecording == false)
        #expect(onDisk.endedAt == now)
        #expect(onDisk.statistics == nil)
        // Next launch: nothing resumes, the statistics are filled in.
        let recovery = TripLifecycle.recover(store: store, markedId: nil, now: now.addingTimeInterval(60), config: .default)
        #expect(recovery.resume == nil)
        #expect(recovery.repaired == [running.id])
        let repaired = try store.load(running.id)
        #expect(repaired.isRecording == false)
        #expect(repaired.endedAt == now)
        #expect(approx(repaired.statistics?.distance, 29 * 15, 1e-6))
    }

    // MARK: Rule 2: stale resume

    @Test func freshMarkedTripResumes() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.recordingTrip(in: store, lastFixAt: now.addingTimeInterval(-5 * 60))
        let recovery = TripLifecycle.recover(store: store, markedId: r.id, now: now, config: .default)
        #expect(recovery.resume?.record.id == r.id)
        #expect(recovery.resume?.contents.fixes.count == 30)
        #expect(recovery.finalized.isEmpty && !recovery.markedTripFinalized)
        #expect(try store.load(r.id).isRecording)
    }

    @Test func exactlyThirtyMinutesStillResumes() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.recordingTrip(in: store, lastFixAt: now.addingTimeInterval(-30 * 60))
        #expect(TripLifecycle.recover(store: store, markedId: r.id, now: now, config: .default).resume?.record.id == r.id)
    }

    @Test func staleMarkedTripIsFinalizedAtItsLastFix() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let lastFix = now.addingTimeInterval(-31 * 60)
        let r = try Self.recordingTrip(in: store, lastFixAt: lastFix)
        let recovery = TripLifecycle.recover(store: store, markedId: r.id, now: now, config: .default)
        #expect(recovery.resume == nil)
        #expect(recovery.markedTripFinalized)
        #expect(recovery.finalized == [r.id])
        let done = try store.load(r.id)
        #expect(done.isRecording == false)
        #expect(done.endedAt == lastFix)
        #expect(done.statistics?.gps.fixCount == 30)
    }

    @Test func staleTripWithoutFixesEndsAtItsStart() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let start = now.addingTimeInterval(-2 * 3600)
        let r = TripRecord(startedAt: start, isRecording: true)
        try store.create(r)
        let recovery = TripLifecycle.recover(store: store, markedId: r.id, now: now, config: .default)
        #expect(recovery.markedTripFinalized)
        let done = try store.load(r.id)
        #expect(done.isRecording == false && done.endedAt == start)
    }

    @Test func otherRecordingFoldersAreFinalizedNextToTheResumedOne() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let orphan = try Self.recordingTrip(in: store, lastFixAt: now.addingTimeInterval(-60))
        let marked = try Self.recordingTrip(in: store, lastFixAt: now.addingTimeInterval(-10))
        let recovery = TripLifecycle.recover(store: store, markedId: marked.id, now: now, config: .default)
        #expect(recovery.resume?.record.id == marked.id)
        #expect(recovery.finalized == [orphan.id])
        #expect(!recovery.markedTripFinalized)
        #expect(try store.load(orphan.id).isRecording == false)
        #expect(try store.load(marked.id).isRecording == true)
    }

    @Test func recordingFolderWithoutMarkerIsFinalized() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let r = try Self.recordingTrip(in: store, lastFixAt: now.addingTimeInterval(-10))
        let recovery = TripLifecycle.recover(store: store, markedId: nil, now: now, config: .default)
        #expect(recovery.resume == nil)
        #expect(recovery.finalized == [r.id])
        #expect(!recovery.markedTripFinalized)
    }

    @Test func finalizedMergesGapRecordsFromTheFixFile() {
        let fixes = Fixtures.northbound(speeds: Array(repeating: 10, count: 5))
            + Fixtures.shifted(Fixtures.northbound(speeds: Array(repeating: 10, count: 5)), byMs: 20_000)
        let gap = Gap(startMs: fixes[4].timestampMs, endMs: fixes[5].timestampMs, reason: .relaunch)
        let r = TripLifecycle.finalized(
            TripRecord(startedAt: fixes[0].date), contents: FixFile.Contents(fixes: fixes, gaps: [gap]), config: .default
        )
        #expect(r.gaps == [gap])
        #expect(r.endedAt == fixes.last?.date)
        #expect(r.statistics?.segmentCount == 2)
        #expect(r.preview?.count == 2 && r.preview?[0].count == 5)
    }
}
