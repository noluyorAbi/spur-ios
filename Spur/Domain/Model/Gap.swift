import Foundation

/// A stretch of more than `StatsConstants.gapThreshold` seconds between two consecutive fixes.
nonisolated struct Gap: Codable, Sendable, Equatable, Hashable {
    enum Reason: String, Codable, Sendable, CaseIterable {
        /// The app was in the background and fixes stopped arriving.
        case background
        /// The app was terminated and the trip resumed on the next launch.
        case relaunch
        /// No fix arrived for another reason (tunnel, weak signal).
        case signal
        /// The person paused the trip (SPEC 18.9): no fixes on purpose.
        case pause
    }

    /// Time of the last fix before the gap, in ms since 1970.
    var startMs: Int64
    /// Time of the first fix after the gap, in ms since 1970.
    var endMs: Int64
    var reason: Reason

    var duration: Double { Double(endMs - startMs) / 1000 }
}
