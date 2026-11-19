import CoreMotion
import os
import Foundation
import simd

/// Where motion samples come from (SPEC 16.3.1): CoreMotion on the phone, a script in tests, the
/// synthetic source in the simulator (Debug). Samples arrive in batches of about a second, on a
/// background queue, never on the main actor.
nonisolated protocol MotionSource: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void)
    func stop()
    /// A recorded fix, for sources that derive motion from the fixes (the synthetic one).
    func observe(_ fix: Fix)
    /// How long a batch collects before delivery: 1 s normally, about 0.1 s while the live
    /// details are on screen (SPEC 17.4: the dot needs about 10 Hz).
    func setBatchSeconds(_ seconds: Double)
}

nonisolated extension MotionSource {
    func observe(_ fix: Fix) {}
    func setBatchSeconds(_ seconds: Double) {}
}

/// Device motion from CoreMotion: `xArbitraryZVertical` (no magnetometer: magnetic phone mounts
/// corrupt it), on its own operation queue, through the app's one `CMMotionManager`.
nonisolated final class CoreMotionSource: MotionSource, @unchecked Sendable {
    /// One motion manager for the app (Apple: more than one degrades the rate).
    nonisolated(unsafe) static let manager = CMMotionManager()
    private static let log = Logger(subsystem: "dev.adatepe.spur", category: "motion")
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "spur.motion.source"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    // Touched only on `queue`.
    private var buffer: [MotionSample] = []
    private var batchSeconds = 1.0
    private var offset: Double?
    private var deliver: (@Sendable ([MotionSample]) -> Void)?

    var isAvailable: Bool { Self.manager.isDeviceMotionAvailable }

    /// Wall-clock unix seconds of a CoreMotion timestamp (seconds since boot). The offset between
    /// the two clocks is taken once per start, so a wall-clock step during the trip never makes
    /// time jump inside the file (the writer keeps the file monotonic across starts).
    static func wallClock(_ timestamp: TimeInterval, offset: Double) -> Double { timestamp + offset }
    static func offset(now: Date, uptime: TimeInterval) -> Double { now.timeIntervalSince1970 - uptime }

    func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) {
        guard Self.manager.isDeviceMotionAvailable else { return }
        queue.addOperation { [self] in
            self.deliver = deliver
            buffer = []
            offset = Self.offset(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        }
        Self.manager.deviceMotionUpdateInterval = 1 / Double(max(1, rateHz))
        Self.manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            if let error { Self.log.error("device motion error: \(error.localizedDescription, privacy: .public)") }
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    private func handle(_ m: CMDeviceMotion) {
        if offset == nil { offset = Self.offset(now: Date(), uptime: ProcessInfo.processInfo.systemUptime) }
        let q = m.attitude.quaternion
        buffer.append(MotionSample(
            time: Self.wallClock(m.timestamp, offset: offset!),
            userAcceleration: SIMD3(Float(m.userAcceleration.x), Float(m.userAcceleration.y), Float(m.userAcceleration.z)),
            gravity: SIMD3(Float(m.gravity.x), Float(m.gravity.y), Float(m.gravity.z)),
            rotationRate: SIMD3(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z)),
            attitude: SIMD4(Float(q.x), Float(q.y), Float(q.z), Float(q.w))))
        if let first = buffer.first, buffer[buffer.count - 1].time - first.time >= batchSeconds { flush() }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        #if DEBUG
        PerfCounters.add("motion.batch")
        #endif
        deliver?(buffer)
        buffer = []
    }

    func setBatchSeconds(_ seconds: Double) {
        queue.addOperation { [self] in batchSeconds = seconds }
    }

    func stop() {
        Self.manager.stopDeviceMotionUpdates()
        queue.addOperation { [self] in
            flush()
            deliver = nil
        }
        queue.waitUntilAllOperationsAreFinished()
    }
}

/// What went wrong while recording motion (SPEC 16.3.1, review item 16), kept in trip.json.
nonisolated struct MotionHealth: Codable, Sendable, Equatable {
    /// Delivery restarted after a stall.
    var restarts = 0
    /// Batches that could not be written (each rolled back).
    var writeFailures = 0
    /// The file could not be opened: the trip has no motion.
    var openFailed = false
    /// Motion stopped after repeated write failures.
    var gaveUp = false

    var isClean: Bool { restarts == 0 && writeFailures == 0 && !openFailed && !gaveUp }
}

/// Writes the samples of the running trip to its `motion.bin`, on its own serial queue: appends
/// each batch, syncs at least every 10 s and whenever asked (app state changes). A failed write is
/// rolled back and counted; after three in a row motion stops for the trip. A delivery that stalls
/// for 15 s while recording is restarted.
nonisolated final class MotionRecorder: @unchecked Sendable {
    static let maxConsecutiveFailures = 3
    static let stallSeconds = 15.0
    private static let log = Logger(subsystem: "dev.adatepe.spur", category: "motion")

    private let queue = DispatchQueue(label: "spur.motion.writer", qos: .userInitiated)
    // Touched only on `queue`.
    private var writer: MotionFileWriter?
    private var lastSync = Date.distantPast
    private var written = 0
    private var failuresInARow = 0
    private var health = MotionHealth()
    private var source: MotionSource?
    private var rate = 100
    /// The live estimator's feed (SPEC 17.4): every batch is forked to it after it is handed to
    /// the writer's queue, so the write never waits for it.
    var live: LiveMotionFeed?
    private let fastLock = NSLock()
    private var fast = false
    // Watchdog state, main actor side.
    private var watchedCount = 0
    private var watchedSince = Date()

    /// True while a trip's motion is being recorded.
    private(set) var isRecording = false
    /// Samples written since the start (tests).
    var samplesWritten: Int { queue.sync { written } }
    /// Whether the last batch was written on the main thread (tests: it never is).
    var lastWriteOnMain: Bool? { queue.sync { writeOnMain } }
    private var writeOnMain: Bool?
    /// What went wrong so far in this trip.
    var currentHealth: MotionHealth { queue.sync { health } }
    /// Called (on the writer queue) when motion recording fails in a way the person should know:
    /// the file could not be opened, or writes keep failing.
    var onProblem: (@Sendable (String) -> Void)?

    /// Starts recording into `url`. A resumed trip keeps the rate in the file's header. Returns
    /// false when the file could not be opened (reported through `onProblem` as well).
    @discardableResult
    func start(url: URL, rateHz: Int, source: MotionSource, now: Date = Date()) -> Bool {
        stop()
        guard source.isAvailable else { return false }
        let opened: Int? = queue.sync {
            health = MotionHealth()
            failuresInARow = 0
            written = 0
            lastSync = Date()
            do {
                let w = try MotionFileWriter(url: url, rateHz: rateHz)
                writer = w
                return w.rateHz
            } catch {
                Self.log.error("motion file could not be opened: \(error.localizedDescription, privacy: .public)")
                health.openFailed = true
                onProblem?("Bewegungssensor: Datei konnte nicht angelegt werden, diese Fahrt ohne Sensordaten.")
                return nil
            }
        }
        guard let rate = opened else { return false }
        self.rate = rate
        self.source = source
        isRecording = true
        watchedCount = 0
        watchedSince = now
        startDelivery(source)
        return true
    }

    private func startDelivery(_ source: MotionSource) {
        source.start(rateHz: rate) { [weak self] batch in
            guard let self else { return }
            self.queue.async { self.write(batch) }
            self.live?.ingest(batch)
        }
        source.setBatchSeconds(fastLock.withLock { fast } ? 0.1 : 1)
    }

    /// Short batches while the live details are on screen, else 1 s ones.
    func setFastBatches(_ on: Bool) {
        fastLock.withLock { fast = on }
        source?.setBatchSeconds(on ? 0.1 : 1)
    }

    private func write(_ batch: [MotionSample]) {
        guard let writer else { return }
        do {
            try writer.append(batch)
            written += batch.count
            failuresInARow = 0
            writeOnMain = Thread.isMainThread
        } catch {
            health.writeFailures += 1
            failuresInARow += 1
            Self.log.error("motion batch not written: \(error.localizedDescription, privacy: .public)")
            if failuresInARow >= Self.maxConsecutiveFailures {
                health.gaveUp = true
                writer.close()
                self.writer = nil
                onProblem?("Bewegungssensor: Speichern fehlgeschlagen, Aufzeichnung der Sensordaten gestoppt.")
            }
            return
        }
        if Date().timeIntervalSince(lastSync) >= 10 {
            try? writer.sync()
            lastSync = Date()
        }
    }

    func observe(_ fix: Fix) { source?.observe(fix) }

    /// Tests: makes the next writes fail part-way.
    func setWriteHookForTesting(_ hook: ((FileHandle, Data) throws -> Void)?) {
        queue.sync { writer?.writeHook = hook }
    }

    func sync() {
        queue.async { [self] in
            try? writer?.sync()
            lastSync = Date()
        }
    }

    /// The watchdog, called with every sync (about every 10 s): when no sample arrived for 15 s
    /// while recording, delivery is restarted. Returns true when it restarted.
    @discardableResult
    func checkStall(now: Date = Date()) -> Bool {
        guard isRecording, let source else { return false }
        let (count, open) = queue.sync { (written, writer != nil) }
        guard open else { return false }
        if count != watchedCount {
            watchedCount = count
            watchedSince = now
            return false
        }
        guard now.timeIntervalSince(watchedSince) >= Self.stallSeconds else { return false }
        Self.log.error("motion delivery stalled for \(Int(now.timeIntervalSince(self.watchedSince))) s, restarting")
        source.stop()
        startDelivery(source)
        queue.sync { health.restarts += 1 }
        watchedSince = now
        return true
    }

    func stop() {
        source?.stop()
        source = nil
        isRecording = false
        queue.sync {
            writer?.close()
            writer = nil
        }
    }
}

#if DEBUG
/// Debug only: motion derived from the recorded fixes, so the whole pipeline runs in the
/// simulator, which has no motion hardware (`-SpurSynthMotion YES`).
nonisolated final class SyntheticMotionSource: MotionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable ([MotionSample]) -> Void)?
    private var last: Fix?
    private var rate = 100.0
    private var noise = MotionSynth.Noise(state: 42)
    private let mount = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)

    var isAvailable: Bool { true }

    func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) {
        lock.withLock {
            self.deliver = deliver
            rate = Double(rateHz)
            last = nil
        }
    }

    func observe(_ fix: Fix) {
        let (batch, out): ([MotionSample], (@Sendable ([MotionSample]) -> Void)?) = lock.withLock {
            defer { last = fix }
            guard let a = last else { return ([], nil) }
            return (MotionSynth.between(a, fix, rateHz: rate, mount: mount, noise: &noise), deliver)
        }
        if !batch.isEmpty { out?(batch) }
    }

    func stop() {
        lock.withLock { deliver = nil }
    }
}
#endif
