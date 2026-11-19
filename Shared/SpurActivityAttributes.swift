import ActivityKit
import CoreText
import Foundation
import UIKit

/// The Live Activity of a recording trip (SPEC 16.4). Compiled into the app and the widget
/// extension. No push, no App Group: the app starts, updates and ends it.
nonisolated struct SpurActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        enum Status: String, Codable, Sendable {
            /// Fixes arrive and are accurate enough.
            case recording
            /// No fix for more than 5 s.
            case gap
            /// Location access is missing; the trip waits.
            case paused
            /// The "Ungenaue Position" banner is due.
            case poorAccuracy
            /// The person paused the trip (SPEC 18.9); nothing is recorded.
            case userPaused
            /// Paused, and the phone sees driving: "Pausiert, du fährst".
            case pausedDriving
            /// A break was detected (SPEC 18.9); it ends by itself when the car drives.
            case autoPaused
            /// The trip was stopped: the final state.
            case ended
        }

        var status: Status
        /// Meters driven, rounded to 10 m.
        var distanceMeters: Double
        /// m/s of the last fix, nil when unknown or during a gap.
        var speedMps: Double?
        /// Horizontal accuracy of the last fix in m, whole meters.
        var accuracyMeters: Double?
        /// The road type the HUD shows now ("Stadt", "Land", "Autobahn" or the OSM category).
        var roadType: String?
        /// The speed limit the HUD shows, nil when none is shown.
        var limit: Limit?
        /// km and km/h, else mi and mph.
        var metric: Bool
        /// Set in the final state.
        var endedAt: Date?
        /// When the app built this state: a stale view stops its timer here.
        var updatedAt: Date?

        nonisolated struct Limit: Codable, Hashable, Sendable {
            var value: Int
            /// The sign's own unit: an mph sign stays mph in a metric display, as in the HUD.
            var mph: Bool
        }
    }

    var tripId: UUID
    var startedAt: Date
}

/// German text of the Live Activity (decimal comma), the same rules as the app's `Format`. Pure,
/// shared by the widget extension and the app's tests.
nonisolated enum SpurActivityText {
    static let metersPerMile = 1609.344
    private static let locale = Locale(identifier: "de_DE")

    static func number(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    static func distanceUnit(metric: Bool) -> String { metric ? "km" : "mi" }
    static func speedUnit(metric: Bool) -> String { metric ? "km/h" : "mph" }

    /// 2 digits below 10, 1 below 100, else none (as `Format.distance`).
    static func distance(_ meters: Double, metric: Bool) -> String {
        let v = metric ? meters / 1000 : meters / metersPerMile
        return number(v, digits: v < 10 ? 2 : (v < 100 ? 1 : 0))
    }

    static func speed(_ mps: Double?, metric: Bool) -> String {
        guard let mps else { return "-" }
        return number(metric ? mps * 3.6 : mps * 3600 / metersPerMile, digits: 0)
    }

    /// "± 4 m", as the GPS chip of the HUD; "GPS" without an accuracy.
    static func accuracy(_ meters: Double?) -> String {
        meters.map { "± \(Int($0.rounded())) m" } ?? "GPS"
    }

    /// `30 s`, `14 min 04 s`, `1 h 03 min` (as `Format.duration`).
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d h %02d min", h, m) : String(format: "%d min %02d s", m, sec)
    }

    /// The final line: "Fahrt beendet · 12,4 km · 23 min".
    static func ended(_ state: SpurActivityAttributes.ContentState, startedAt: Date) -> String {
        let end = state.endedAt ?? startedAt
        let minutes = max(0, Int((end.timeIntervalSince(startedAt) / 60).rounded(.down)))
        let duration = minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
        return "Fahrt beendet · \(distance(state.distanceMeters, metric: state.metric)) \(distanceUnit(metric: state.metric)) · \(duration)"
    }

    /// The status as words, for VoiceOver on the island's compact and minimal views.
    static func spoken(_ state: SpurActivityAttributes.ContentState, stale: Bool) -> String {
        if state.status == .ended { return ended(state, startedAt: state.endedAt ?? Date()) }
        let what = status(state, stale: stale) ?? "Spur zeichnet auf"
        return "\(what), \(distance(state.distanceMeters, metric: state.metric)) \(distanceUnit(metric: state.metric))"
    }

    /// The status line under the numbers, nil while recording normally.
    static func status(_ state: SpurActivityAttributes.ContentState, stale: Bool) -> String? {
        if stale && state.status != .ended { return "Keine Aktualisierung" }
        switch state.status {
        case .recording: return nil
        case .gap: return "Kein GPS-Signal"
        case .paused: return "Pausiert, Standortzugriff fehlt"
        case .poorAccuracy: return "Ungenaue Position"
        case .userPaused: return "Pausiert, es wird nichts aufgezeichnet"
        case .pausedDriving: return "Pausiert, du fährst: in Spur fortsetzen"
        case .autoPaused: return "Automatisch pausiert"
        case .ended: return nil
        }
    }

    /// GPS quality as the HUD chip: up to 5 m good, up to 15 m fair, else poor.
    enum Quality: Equatable { case good, fair, poor, none }

    static func quality(_ meters: Double?) -> Quality {
        guard let meters else { return .none }
        return meters <= 5 ? .good : (meters <= 15 ? .fair : .poor)
    }
}

/// The optional UI typeface: the first font file bundled from `Spur/Resources/Fonts/` (kept
/// out of git, copied in by `scripts/install-font.sh`), registered at launch. Without one, the
/// app and the extension use the system font.
nonisolated enum SpurFont {
    static let postScriptName: String? = register()

    private static func register() -> String? {
        let urls = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let name = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }) else { continue }
            // Already registered (a second call, or the system has it) is fine.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if UIFont(name: name, size: 12) != nil { return name }
        }
        return nil
    }
}
