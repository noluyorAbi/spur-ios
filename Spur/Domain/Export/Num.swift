import Foundation

/// Locale independent number and time formatting for files. Always `.` as decimal separator.
nonisolated enum Num {
    /// Shortest round-trip decimal text without exponent; "null" for nil or non-finite.
    static func json(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "null" }
        return plain(v)
    }

    /// Shortest round-trip decimal text, never in exponent notation.
    static func plain(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let s = "\(v)"
        guard s.contains("e") || s.contains("E") else { return s }
        // Rare: very small or very large values. Print enough digits, then trim zeros.
        var fixed = String(format: "%.17f", v)
        while fixed.hasSuffix("0") { fixed.removeLast() }
        if fixed.hasSuffix(".") { fixed.removeLast() }
        return fixed
    }

    /// Fixed fraction digits, trailing zeros trimmed.
    static func fixed(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    /// Empty string for nil (CSV), else `plain`.
    static func csv(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return plain(v)
    }

    /// ISO 8601 UTC with milliseconds, for example `2026-11-11T08:15:02.250Z`.
    static func iso(ms: Int64) -> String {
        let secs = Int(ms.floorDiv(1000))
        let millis = Int(ms - Int64(secs) * 1000)
        var t = time_t(secs)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
                      Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), millis)
    }

    static func iso(_ date: Date) -> String {
        iso(ms: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

nonisolated extension Int64 {
    /// Division rounding toward negative infinity.
    func floorDiv(_ d: Int64) -> Int64 {
        let q = self / d
        return (self % d != 0 && (self < 0) != (d < 0)) ? q - 1 : q
    }
}
