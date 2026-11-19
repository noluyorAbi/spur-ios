import Foundation

/// A tiny ordered JSON tree with deterministic, locale independent output.
nonisolated indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    /// Keys keep their insertion order.
    case object([(String, JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool { a.serialized() == b.serialized() }

    static func num(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }
    static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }

    func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += Num.json(d)
        case .int(let i): out += String(i)
        case .string(let s): JSONValue.escape(s, into: &out)
        case .array(let items):
            out += "["
            for (k, item) in items.enumerated() {
                if k > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (k, pair) in pairs.enumerated() {
                if k > 0 { out += "," }
                JSONValue.escape(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    static func escape(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
