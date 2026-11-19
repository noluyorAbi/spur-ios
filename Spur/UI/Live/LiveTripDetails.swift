import Foundation
import Observation

/// The running trip's details (SPEC 17.2, 17.8): one model that the live panel and the running
/// trip's "Fahrt-Details" both read, so they show the same numbers at the same moment. The
/// statistics come from the same analysis as the trip details, on the engine's fixes so far, off
/// the main actor, at most every 5 s and only while someone looks; the sensor values from the
/// live motion feed (SPEC 17.3, 17.4).
@Observable
final class LiveTripDetails {
    /// At most this often the statistics are rebuilt.
    static let interval: Duration = .seconds(5)
    /// And never sooner than this many times the last rebuild took.
    static let costFactor = 10.0

    /// The running trip's detail model, nil while nothing records.
    private(set) var detail: TripDetailModel?
    let motion: LiveMotionModel
    @ObservationIgnored private let engine: RecordingEngine
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let store: TripStore
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var inFront = true
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var built: (id: UUID, fixes: Int, events: Int, record: TripRecord)?

    init(engine: RecordingEngine, settings: Settings, store: TripStore) {
        self.engine = engine
        self.settings = settings
        self.store = store
        motion = LiveMotionModel(feed: engine.liveMotion)
    }

    /// The running trip's id, nil while nothing records.
    var runningTripId: UUID? { engine.isRecording ? engine.trip?.id : nil }

    /// A view showing the live details appeared or went away.
    func viewerAppeared() {
        viewers += 1
        motion.viewerAppeared()
        updateLoop()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        motion.viewerDisappeared()
        updateLoop()
    }

    /// The app moved to the front or away (a locked phone keeps the views on screen, so this, not
    /// their disappearing, stops the work; SPEC 17.4). Back in front the loop restarts with an
    /// immediate rebuild.
    func setInFront(_ front: Bool) {
        inFront = front
        motion.setInFront(front)
        updateLoop()
    }

    /// Whether the statistics loop runs (tests).
    var isRefreshing: Bool { loop != nil }

    private func updateLoop() {
        if viewers > 0 && inFront {
            startLoop()
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    /// Rebuilds now if anything changed (tests, and the first appearance).
    func refreshNow() async {
        #if DEBUG
        PerfCounters.add("stats.rebuild")
        #endif
        guard let trip = engine.trip, engine.isRecording else {
            if detail != nil { detail = nil }
            built = nil
            return
        }
        let fixes = engine.fixes
        let events = engine.events
        if let b = built, b.id == trip.id, b.fixes == fixes.count, b.events == events.count, b.record == trip { return }
        let d: TripDetailModel
        if let existing = detail, existing.record.id == trip.id {
            d = existing
        } else {
            d = TripDetailModel(record: trip)
            motion.reset()
            detail = d
        }
        await d.refreshLive(fixes: fixes, events: events, record: trip, config: settings.statsConfig, units: settings.units)
        built = (trip.id, fixes.count, events.count, trip)
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let start = Date()
                await self?.refreshNow()
                // A long trip stretches the cadence: at most a tenth of the time rebuilding (an
                // 8 h trip's rebuild takes seconds).
                let took = Date().timeIntervalSince(start)
                try? await Task.sleep(for: max(Self.interval, .seconds(Self.costFactor * took)))
            }
        }
    }
}
