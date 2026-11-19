import Foundation

/// Display units. Internally everything is SI.
nonisolated enum UnitSystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case metric, imperial

    var id: String { rawValue }

    static let metersPerMile = 1609.344
    static let feetPerMeter = 1 / 0.3048

    var label: String {
        switch self {
        case .metric: "km und km/h"
        case .imperial: "mi und mph"
        }
    }

    var speedUnit: String { self == .metric ? "km/h" : "mph" }
    var distanceUnit: String { self == .metric ? "km" : "mi" }
    var elevationUnit: String { self == .metric ? "m" : "ft" }

    /// Display speed units per m/s: 3.6 for km/h, 3600 / 1609.344 for mph.
    var unitsPerMps: Double { self == .metric ? 3.6 : 3600 / UnitSystem.metersPerMile }

    /// m/s to km/h or mph.
    func speed(_ mps: Double) -> Double {
        self == .metric ? mps * 3.6 : mps * 3600 / UnitSystem.metersPerMile
    }

    /// Meters to km or mi.
    func distance(_ meters: Double) -> Double {
        self == .metric ? meters / 1000 : meters / UnitSystem.metersPerMile
    }

    /// Meters to m or ft.
    func elevation(_ meters: Double) -> Double {
        self == .metric ? meters : meters * UnitSystem.feetPerMeter
    }
}

/// German display formatting (decimal comma). Files never use this.
nonisolated enum Format {
    static let locale = Locale(identifier: "de_DE")

    static func number(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// Distance with sensible precision: 2 digits below 10, 1 digit below 100, else none.
    static func distance(_ meters: Double, _ units: UnitSystem) -> String {
        let v = units.distance(meters)
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        return number(v, digits: digits)
    }

    static func speed(_ mps: Double?, _ units: UnitSystem) -> String {
        guard let mps else { return "-" }
        return number(units.speed(mps), digits: 0)
    }

    /// Duration as `h:mm:ss` or `m:ss`.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The one duration format of the UI, always with units: `30 s`, `14 min 04 s`, `1 h 03 min`.
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d h %02d min", h, m) : String(format: "%d min %02d s", m, sec)
    }

    /// Whole percentages that add up to exactly 100 (largest remainder method), for shares that
    /// are shown side by side. All zero when the shares sum to zero.
    static func wholePercents(_ shares: [Double]) -> [Int] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return shares.map { _ in 0 } }
        let exact = shares.map { $0 / total * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(floors[$0])) > (exact[$1] - Double(floors[$1])) }
        for k in order.prefix(100 - floors.reduce(0, +)) { floors[k] += 1 }
        return floors
    }

    /// File sizes in German ("12,3 MB"); nothing is "leer".
    static func bytes(_ count: Int64) -> String {
        guard count > 0 else { return "leer" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        let text = f.string(fromByteCount: count)
        // The formatter follows the device language; the UI is German, so the decimal comma is set here.
        return text.replacingOccurrences(of: ".", with: ",")
    }

    static func percent(_ share: Double, digits: Int = 0) -> String {
        number(share * 100, digits: digits) + " %"
    }
}
