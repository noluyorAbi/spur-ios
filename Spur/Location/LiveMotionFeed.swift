import Foundation
import Observation

/// What the panel shows of the motion sensor (SPEC 17.2a), built off the main actor at most once
/// per second.
nonisolated struct LiveMotionSnapshot: Sendable, Equatable {
    /// The analysis of the trip so far (maxima, counts, roughness, alignment), nil before the
    /// first refresh.
    var summary: MotionSummary?
    /// Events and roughness stretches so far (the chart series left out).
    var details: MotionDetails?
    /// The last finished 100 m stretch's class (0 glatt to 3 sehr uneben).
    var lastStretchClass: Int? { details?.stretches.last?.roughness }
    /// The rolling 60 s of the 2 Hz longitudinal, seconds before now and m/s².
    var chart: [ChartPoint] = []
    var state: LiveMotionEstimator.State = .waiting
    /// Why values are hidden (SPEC 18.10a), nil when they are not or the reason is another.
    var hidden: LiveMotionEstimator.Hidden?
    /// When the snapshot was built (sensor time, unix seconds).
    var time: Double = 0
    /// The refresh after opening is running: the panel shows "wird berechnet" for its seconds
    /// (review round 2, M2: nothing is refreshed while nobody looks).
    var computing = false

    struct ChartPoint: Sendable, Equatable {
        var age: Double
        var long: Double
    }
}

/// The live estimator's place in the app (SPEC 17.4): fed from the one CoreMotion stream (the
/// recorder forks each batch here after handing it to the writer, so the write never waits) and
/// from the engine's fixes, on its own serial queue. It always senses (cheap: the swivel and
/// remount gates must remember what happened while nobody looked); refreshes and publishing happen
/// only while it is active (a panel or the running trip's details on screen, app in front).
nonisolated final class LiveMotionFeed: @unchecked Sendable {
    /// The dot: at most this often.
    static let readingInterval = 1.0 / 12
    /// Everything else: at most once per second.
    static let snapshotInterval = 1.0

    private let queue = DispatchQueue(label: "spur.motion.live", qos: .utility)
    /// Refreshes run here, on a copy of the estimator, so carrying samples and publishing the dot
    /// on `queue` never wait for one (review round 3, R1: a full refresh at 8 h takes about 10 s
    /// on a phone).
    private let refreshQueue = DispatchQueue(label: "spur.motion.live.refresh", qos: .utility)
    /// What arrived while a refresh ran, replayed onto its result in order.
    private enum Pending {
        case samples([MotionSample])
        case fix(Fix)
    }
    // Touched only on `queue`.
    private var refreshing = false
    private var pending: [Pending] = []
    /// Bumped by `begin` and `end`: a refresh of an earlier trip is dropped.
    private var generation = 0
    /// Tests: an extra delay inside each refresh, as a long trip on a phone.
    var refreshDelayForTesting: TimeInterval = 0
    private var estimator = LiveMotionEstimator()
    private var fixes: [Fix] = []
    private var url: URL?
    private var active = false
    private var lastRefresh: Double?
    private var lastDuration = 0.0
    private var lastReadingSent = -Double.infinity
    private var lastSnapshotSent = -Double.infinity
    private var refreshCount = 0
    private var samplesSeen = 0

    /// Called on the feed's queue; the receiver hops to the main actor.
    var onReading: (@Sendable (LiveMotionEstimator.Reading) -> Void)?
    var onSnapshot: (@Sendable (LiveMotionSnapshot) -> Void)?
    /// Asks the motion source for short batches while active (the dot needs about 10 Hz).
    var onActiveChanged: (@Sendable (Bool) -> Void)?

    /// Tests.
    var refreshes: Int { queue.sync { refreshCount } }
    var samples: Int { queue.sync { samplesSeen } }
    var isActive: Bool { queue.sync { active } }
    var isRefreshing: Bool { queue.sync { refreshing } }

    /// A trip starts or resumes: `url` is its `motion.bin`, `fixes` what it recorded so far.
    func begin(url: URL, fixes: [Fix]) {
        queue.async { [self] in
            generation += 1
            refreshing = false
            pending = []
            estimator = LiveMotionEstimator()
            estimator.quiet = !active
            self.url = url
            self.fixes = fixes
            lastRefresh = nil
            lastDuration = 0
            lastReadingSent = -.infinity
            lastSnapshotSent = -.infinity
            for f in fixes.suffix(32) { estimator.append(fix: f) }
        }
    }

    func end() {
        queue.async { [self] in
            generation += 1
            refreshing = false
            pending = []
            url = nil
            fixes = []
            estimator = LiveMotionEstimator()
        }
    }

    /// From the recorder's delivery closure: returns at once.
    func ingest(_ batch: [MotionSample]) {
        queue.async { [self] in
            guard url != nil else { return }
            estimator.append(batch)
            samplesSeen += batch.count
            if refreshing { pending.append(.samples(batch)) }
            guard active, let last = batch.last else { return }
            if !refreshing, estimator.refreshDue(now: last.time, lastRefresh: lastRefresh, lastDuration: lastDuration) {
                startRefresh(last.time)
            }
            publish(at: last.time)
        }
    }

    func ingest(fix: Fix) {
        queue.async { [self] in
            guard url != nil else { return }
            fixes.append(fix)
            estimator.append(fix: fix)
            if refreshing { pending.append(.fix(fix)) }
        }
    }

    /// The panel or the running trip's details appeared (and the app is in front), or went away.
    /// Turning on refreshes at once and publishes.
    func setActive(_ on: Bool) {
        queue.async { [self] in
            guard on != active else { return }
            active = on
            estimator.quiet = !on
            onActiveChanged?(on)
            guard on, url != nil else { return }
            let now = estimator.reading?.time ?? Date().timeIntervalSince1970
            var waiting = LiveMotionSnapshot()
            waiting.computing = true
            waiting.state = estimator.state
            waiting.time = now
            onSnapshot?(waiting)
            lastReadingSent = -.infinity
            // No snapshot until the refresh is in: "wird berechnet" stays up meanwhile.
            lastSnapshotSent = .infinity
            if !refreshing { startRefresh(now) }
        }
    }

    /// Waits for the ingest queue only, not for a refresh in flight (tests).
    func flush() { queue.sync {} }

    /// Waits for everything queued, including a refresh in flight and its hand-over (tests).
    func drain() {
        queue.sync {}
        refreshQueue.sync {}
        queue.sync {}
    }

    /// On `queue`: a copy of the estimator goes to the refresh queue; the live one keeps carrying
    /// samples. The result is adopted on `queue` with what arrived meanwhile replayed onto it.
    private func startRefresh(_ now: Double) {
        guard let url else { return }
        refreshing = true
        pending = []
        var copy = estimator
        let allFixes = fixes
        let gen = generation
        let delay = refreshDelayForTesting
        refreshQueue.async { [self] in
            let start = Date()
            let source = MappedMotionFile(url: url)
            if let source { copy.refresh(source: source, allFixes: allFixes, now: Date()) }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let duration = Date().timeIntervalSince(start)
            queue.async { [self] in
                guard gen == generation else { return }
                refreshing = false
                guard source != nil else {
                    pending = []
                    if lastSnapshotSent == .infinity { lastSnapshotSent = -.infinity }
                    return
                }
                for p in pending {
                    switch p {
                    case .samples(let b): copy.append(b)
                    case .fix(let f): copy.append(fix: f)
                    }
                }
                pending = []
                estimator = copy
                estimator.quiet = !active
                lastDuration = duration
                lastRefresh = now
                refreshCount += 1
                if lastSnapshotSent == .infinity { lastSnapshotSent = -.infinity }
                publish(at: estimator.reading?.time ?? now)
            }
        }
    }

    private func publish(at now: Double) {
        if let reading = estimator.reading, now - lastReadingSent >= Self.readingInterval {
            lastReadingSent = now
            onReading?(reading)
        }
        guard now - lastSnapshotSent >= Self.snapshotInterval else { return }
        lastSnapshotSent = now
        let output = estimator.solution?.output
        var details = output?.details
        details?.seriesTime = []
        details?.seriesMin = []
        details?.seriesMax = []
        // One point per 0.5 s (120 for the minute): a 110 pt chart shows no more, and Charts' cost
        // grows with the points it lays out every second (17.4).
        var chart: [LiveMotionSnapshot.ChartPoint] = []
        var lastKept = -Double.infinity
        for p in estimator.chart(now: now) where p.time - lastKept >= 0.5 {
            lastKept = p.time
            chart.append(LiveMotionSnapshot.ChartPoint(age: now - p.time, long: p.long))
        }
        onSnapshot?(LiveMotionSnapshot(summary: output?.summary, details: details, chart: chart, state: estimator.state,
                                       hidden: estimator.hidden, time: now))
    }
}

/// The panel's motion values on the main actor, read only by the panel and the running trip's
/// details (never by the map or the HUD, so nothing else re-evaluates at sensor rate).
@MainActor @Observable
final class LiveMotionModel {
    private(set) var reading: LiveMotionEstimator.Reading?
    /// The reading's state, set only when it changes (views that need only it do not follow the
    /// 12 Hz reading).
    private(set) var state: LiveMotionEstimator.State?
    private(set) var snapshot = LiveMotionSnapshot()
    /// The last 2 s of signed readings, for the g circle's trail.
    private(set) var trail: [LiveMotionEstimator.Reading] = []
    static let trailSeconds = 2.0
    @ObservationIgnored let feed: LiveMotionFeed
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var inFront = true

    init(feed: LiveMotionFeed) {
        self.feed = feed
        feed.onReading = { [weak self] r in Task { @MainActor in self?.receive(r) } }
        feed.onSnapshot = { [weak self] s in Task { @MainActor in self?.snapshot = s } }
    }

    private func receive(_ r: LiveMotionEstimator.Reading) {
        reading = r
        if state != r.state { state = r.state }
        if r.long != nil || r.lat != nil { trail.append(r) }
        trail.removeAll { r.time - $0.time > Self.trailSeconds }
    }

    /// A view that shows these values appeared or disappeared.
    func viewerAppeared() {
        viewers += 1
        update()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        update()
    }

    /// The app moved to the front or away from it.
    func setInFront(_ front: Bool) {
        inFront = front
        update()
    }

    /// A new trip: forget the last one's values.
    func reset() {
        reading = nil
        state = nil
        snapshot = LiveMotionSnapshot()
        trail = []
    }

    private func update() { feed.setActive(viewers > 0 && inFront) }
}
