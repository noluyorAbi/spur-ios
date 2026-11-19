import Foundation

/// A pause of a running trip (SPEC 18.9). A manual pause writes no fixes and no motion (it may be
/// for privacy) and ends only by "Fortsetzen" or Stop.
nonisolated struct TripPause: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case manual
        /// Detected break (SPEC 18.9, automatic pause).
        case auto
    }

    var start: Date
    /// Nil while the pause lasts.
    var end: Date?
    var kind: Kind
    /// What showed it was a break (automatic pauses).
    var evidence: String?

    func seconds(until now: Date) -> Double { max(0, (end ?? now).timeIntervalSince(start)) }
}

extension TripRecord {
    /// Pause time of the trip, the running pause up to `now`.
    nonisolated func pauseSeconds(now: Date = Date()) -> Double {
        (pauses ?? []).reduce(0) { $0 + $1.seconds(until: endedAt ?? now) }
    }

    /// The pause that lasts, if any.
    nonisolated var openPause: TripPause? { pauses?.last.flatMap { $0.end == nil ? $0 : nil } }
}
