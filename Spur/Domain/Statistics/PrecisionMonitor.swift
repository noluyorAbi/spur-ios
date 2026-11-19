import Foundation

/// The "Ungenaue Position" banner while recording (SPEC 14.1). Pure and incremental.
///
/// Rule: the median horizontal accuracy of the fixes of the last 30 s is above 15 m, and that has
/// been true at every evaluation for at least 30 s. It clears at the first evaluation where the
/// median is 15 m or better. Fixes without a known accuracy do not enter the median; a window
/// without any known accuracy keeps the current state (a signal loss is shown by the gap logic).
nonisolated struct PrecisionMonitor: Sendable, Equatable {
    private var window: [(time: Double, accuracy: Double)] = []
    /// Since when the median has been above the limit without interruption.
    private(set) var poorSince: Double?
    /// The median of the window at the last evaluation.
    private(set) var median: Double?

    init() {}

    static func == (a: PrecisionMonitor, b: PrecisionMonitor) -> Bool {
        a.poorSince == b.poorSince && a.median == b.median && a.window.count == b.window.count
    }

    /// Adds one fix. O(1) amortized; call `evaluate` at the UI cadence.
    mutating func add(time: Double, accuracy: Double?) {
        if let accuracy { window.append((time, accuracy)) }
        drop(before: time - StatsConstants.precisionWindow)
    }

    private mutating func drop(before cutoff: Double) {
        var k = 0
        while k < window.count && window[k].time <= cutoff { k += 1 }
        if k > 0 { window.removeFirst(k) }
    }

    /// Re-evaluates at `now` (seconds since 1970, the time of the newest fix) and returns the
    /// median to show in the banner, or nil when no banner is due.
    @discardableResult
    mutating func evaluate(now: Double) -> Double? {
        drop(before: now - StatsConstants.precisionWindow)
        guard let m = Quantile.median(window.map(\.accuracy)) else { return banner(now: now) }
        median = m
        if m > StatsConstants.precisionPoorAccuracy {
            if poorSince == nil { poorSince = now }
        } else {
            poorSince = nil
        }
        return banner(now: now)
    }

    private func banner(now: Double) -> Double? {
        guard let poorSince, let median, now - poorSince >= StatsConstants.precisionHold else { return nil }
        return median
    }

    mutating func reset() { self = PrecisionMonitor() }
}
