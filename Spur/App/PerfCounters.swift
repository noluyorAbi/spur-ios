#if DEBUG
import Foundation
import os

/// Debug-only work counters for `scripts/live-perf.sh` (PERF_COUNTS=1): how much work a run did,
/// so two runs of one build can be compared by work and not only by CPU time. Off unless the
/// launch defaults say `SpurPerfCounters`; then the counts go to Library/Caches/perf-counts.json
/// every 15 s.
nonisolated enum PerfCounters {
    static let enabled = UserDefaults.standard.bool(forKey: "SpurPerfCounters")
    private static let state = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func add(_ key: String, _ n: Int = 1) {
        guard enabled else { return }
        state.withLock { $0[key, default: 0] += n }
    }

    static func startIfWanted() {
        guard enabled else { return }
        Thread.detachNewThread {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("perf-counts.json")
            while true {
                var snapshot = state.withLock { $0 }
                snapshot["t"] = Int(Date().timeIntervalSince1970)
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                    try? data.write(to: url, options: .atomic)
                }
                Thread.sleep(forTimeInterval: 15)
            }
        }
    }
}
#endif
