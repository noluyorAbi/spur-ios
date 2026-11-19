import Foundation

/// Ending, finalizing and launch-time recovery of trips. Pure decisions plus store I/O; the
/// clock is a parameter so the rules are testable.
nonisolated enum TripLifecycle {
    /// A trip marked as recording whose newest fix (or start, without fixes) is older than this
    /// is finalized at launch instead of resumed.
    static let staleAfter: TimeInterval = 30 * 60

    /// The record as it must be on disk the moment the user stops: no longer recording, with its
    /// end time. Statistics follow later.
    /// Ends an open pause (SPEC 18.9) at `date`.
    static func closePause(_ r: inout TripRecord, at date: Date) {
        guard var list = r.pauses, var last = list.last, last.end == nil else { return }
        last.end = max(date, last.start)
        list[list.count - 1] = last
        r.pauses = list
    }

    static func ended(_ record: TripRecord, at date: Date, context: TripContext? = nil) -> TripRecord {
        var r = record
        r.isRecording = false
        r.endedAt = date
        if let context { r.context = context }
        closePause(&r, at: date)
        return r
    }

    /// Completes a record from its fix file: merges the gap records, sets the end time when
    /// missing (newest fix, else start), clears the recording flag and computes the statistics.
    static func finalized(_ record: TripRecord, contents: FixFile.Contents, config: StatsConfig) -> TripRecord {
        var r = record
        for gap in contents.gaps where !r.gaps.contains(gap) { r.gaps.append(gap) }
        r.gaps.sort { $0.startMs < $1.startMs }
        r.isRecording = false
        if r.endedAt == nil { r.endedAt = contents.fixes.last?.date ?? r.startedAt }
        // A pause still open when the trip ended (a stop while paused, or a kill) ends with it.
        closePause(&r, at: max(r.endedAt ?? r.startedAt, r.openPause?.start ?? .distantPast))
        let effective = StatsConfig(usableAccuracy: r.usableAccuracyLimit ?? config.usableAccuracy)
        r.statistics = TripAnalyzer.analyze(
            fixes: contents.fixes, recordedGaps: r.gaps, places: r.places, config: effective, pauses: r.pauses ?? []
        ).statistics
        r.preview = TrailGeometry.preview(contents.fixes, config: effective)
        return r
    }

    /// Time of the last sign of life of a trip: its newest fix, else its start.
    static func lastActivity(_ record: TripRecord, contents: FixFile.Contents) -> Date {
        contents.fixes.last?.date ?? record.startedAt
    }

    static func isStale(_ record: TripRecord, contents: FixFile.Contents, now: Date) -> Bool {
        now.timeIntervalSince(lastActivity(record, contents: contents)) > staleAfter
    }

    struct Recovery: Sendable {
        /// The marked trip to continue recording, with its fix file.
        var resume: (record: TripRecord, contents: FixFile.Contents)?
        /// Trips that were still marked as recording and were finalized now.
        var finalized: [UUID] = []
        /// True when the marked trip itself was stale and got finalized ("Letzte Fahrt wurde beendet").
        var markedTripFinalized = false
        /// Finished trips whose missing statistics were computed now (killed while stopping).
        var repaired: [UUID] = []
    }

    /// Launch-time recovery of the marked trip only (fast, synchronous): it resumes when its last
    /// activity is at most 30 minutes old, else it is finalized (end time = newest fix).
    static func recoverMarked(
        store: TripStore, markedId: UUID?, now: Date, config: StatsConfig
    ) -> (resume: (record: TripRecord, contents: FixFile.Contents)?, finalized: Bool) {
        guard let markedId, let record = try? store.load(markedId), record.isRecording else { return (nil, false) }
        let contents = store.loadFixes(markedId)
        if !isStale(record, contents: contents, now: now) { return ((record, contents), false) }
        let done = finalized(record, contents: contents, config: config)
        return (nil, (try? store.save(done)) != nil)
    }

    /// Cleanup of every other folder (meant to run off the main actor): a folder that still says
    /// recording and is not the resumed trip is finalized; a finished trip without statistics
    /// (killed while stopping) gets them.
    static func cleanUp(store: TripStore, except resumed: UUID?, config: StatsConfig) -> (finalized: [UUID], repaired: [UUID]) {
        var finalizedIds: [UUID] = []
        var repaired: [UUID] = []
        for record in store.index() where record.id != resumed {
            if record.isRecording {
                let done = finalized(record, contents: store.loadFixes(record.id), config: config)
                if (try? store.save(done)) != nil { finalizedIds.append(record.id) }
            } else if record.statistics == nil {
                let done = finalized(record, contents: store.loadFixes(record.id), config: config)
                if (try? store.save(done)) != nil { repaired.append(record.id) }
            }
        }
        return (finalizedIds, repaired)
    }

    /// Both steps of the launch-time recovery, in order:
    /// - the marked trip resumes when its last activity is at most 30 minutes old, else it is
    ///   finalized (end time = newest fix);
    /// - every other folder that still says recording is finalized;
    /// - a finished trip without statistics gets them.
    static func recover(store: TripStore, markedId: UUID?, now: Date, config: StatsConfig) -> Recovery {
        var out = Recovery()
        let marked = recoverMarked(store: store, markedId: markedId, now: now, config: config)
        out.resume = marked.resume
        out.markedTripFinalized = marked.finalized
        if marked.finalized, let markedId { out.finalized.append(markedId) }
        let rest = cleanUp(store: store, except: marked.resume?.record.id, config: config)
        out.finalized.append(contentsOf: rest.finalized)
        out.repaired = rest.repaired
        return out
    }
}
