import CoreLocation
import Foundation
import Testing
@testable import Spur

/// A source that delivers samples on demand, from a background queue.
nonisolated final class ScriptedMotionSource: MotionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable ([MotionSample]) -> Void)?
    private(set) var startedRate: Int?
    private(set) var stops = 0
    private var t = 1_794_420_000.0

    var isAvailable: Bool { true }

    func start(rateHz: Int, deliver: @escaping @Sendable ([MotionSample]) -> Void) {
        lock.withLock {
            startedRate = rateHz
            self.deliver = deliver
        }
    }

    func stop() { lock.withLock { stops += 1; deliver = nil } }

    /// `n` samples at 100 Hz, delivered off the main thread; returns when delivered.
    func emit(_ n: Int) {
        let (out, batch): ((@Sendable ([MotionSample]) -> Void)?, [MotionSample]) = lock.withLock {
            let b = (0..<n).map { k in
                MotionSample(time: t + Double(k) / 100, userAcceleration: .zero, gravity: SIMD3(0, 0, -1), rotationRate: .zero,
                             attitude: SIMD4(0, 0, 0, 1))
            }
            t += Double(n) / 100
            return (deliver, b)
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            out?(batch)
            done.signal()
        }
        done.wait()
    }
}

/// SPEC 16.3.3: the engine records motion with the trip.
@MainActor
struct MotionEngineTests {
    static func engine(store: TripStore, defaults: UserDefaults, source: ScriptedMotionSource, motion: Bool = true) -> (RecordingEngine, Settings) {
        let settings = Settings(defaults: defaults)
        settings.geocodingEnabled = false
        settings.keepScreenAwake = false
        settings.recordMotion = motion
        let engine = RecordingEngine(store: store, settings: settings, manager: FakeLocationManager(status: .authorizedWhenInUse, accuracy: .fullAccuracy),
                                     makeSession: { FakeSession() }, defaults: defaults, makeMotionSource: { source })
        return (engine, settings)
    }

    static func samples(_ store: TripStore, _ id: UUID) -> Int { MotionFile.read(store.motionURL(id))?.samples.count ?? -1 }

    @Test func aTripRecordsMotionOffTheMainThreadAndAResumeAppends() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let defaults = UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!
        let first = ScriptedMotionSource()
        let (engine, _) = Self.engine(store: store, defaults: defaults, source: first)
        engine.requestStart()
        let id = try #require(engine.trip?.id)
        #expect(first.startedRate == 100)
        first.emit(250)
        #expect(engine.motion.samplesWritten == 250)
        #expect(engine.motion.lastWriteOnMain == false, "motion was written on the main thread")
        // A kill: the next process resumes the trip and appends.
        engine.motion.stop()
        let second = ScriptedMotionSource()
        let (resumed, _) = Self.engine(store: store, defaults: defaults, source: second)
        #expect(resumed.resumeIfNeeded() == id)
        #expect(second.startedRate == 100)
        second.emit(100)
        resumed.stop()
        #expect(second.stops == 1)
        #expect(Self.samples(store, id) == 350)
        #expect(MotionFile.read(store.motionURL(id))?.truncatedBytes == 0)
    }

    @Test func withTheSettingOffNoMotionFileIsWritten() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let source = ScriptedMotionSource()
        let (engine, _) = Self.engine(store: store, defaults: UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!, source: source, motion: false)
        engine.requestStart()
        let id = try #require(engine.trip?.id)
        #expect(source.startedRate == nil)
        engine.stop()
        #expect(!store.hasMotion(id))
    }

    @Test func fiftyHertzIsPassedOnAndTheContextKeepsTheThermalState() throws {
        let store = TripStore(root: Fixtures.tempDir())
        let defaults = UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!
        let source = ScriptedMotionSource()
        let (engine, settings) = Self.engine(store: store, defaults: defaults, source: source)
        settings.motionRateHz = 50
        engine.requestStart()
        #expect(source.startedRate == 50)
        #expect(engine.trip?.context.thermalStateStart != nil)
        engine.stop()
    }

    @Test func coreMotionTimestampsMapToWallClock() {
        // Uptime 100 s at unix 1000 s: a sample stamped 5 s after boot happened at unix 905 s.
        let offset = CoreMotionSource.offset(now: Date(timeIntervalSince1970: 1000), uptime: 100)
        #expect(CoreMotionSource.wallClock(5, offset: offset) == 905)
    }
}
