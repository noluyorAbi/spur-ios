import Foundation

/// The append-only fix file `fixes.jsonl` (SPEC section 3).
///
/// Line 1 is a version header: `{"format":"spur-fixes","version":1}`. Every further line is one
/// JSON object followed by `\n`:
/// - a fix: `{"t":<ms>,"lat":..,"lon":..,"hAcc":..,"alt":..,"ellAlt":..,"vAcc":..,"spd":..,
///   "spdAcc":..,"crs":..,"crsAcc":..,"sim":..,"acc":..}` with `null` for invalid values;
/// - a gap record: `{"type":"gap","start":<ms>,"end":<ms>,"reason":"relaunch"}`, written right
///   before the first fix after the gap.
///
/// A truncated last line (crash mid-write) is skipped on read.
nonisolated enum FixFile {
    static let fileName = "fixes.jsonl"
    static let format = "spur-fixes"
    static let version = 1
    static let header = "{\"format\":\"\(format)\",\"version\":\(version)}\n"

    /// One line for a fix, including the trailing newline.
    static func line(for f: Fix) -> String {
        var s = "{\"t\":\(f.timestampMs)"
        s += ",\"lat\":" + Num.json(f.latitude)
        s += ",\"lon\":" + Num.json(f.longitude)
        s += ",\"hAcc\":" + Num.json(f.horizontalAccuracy)
        s += ",\"alt\":" + Num.json(f.altitude)
        s += ",\"ellAlt\":" + Num.json(f.ellipsoidalAltitude)
        s += ",\"vAcc\":" + Num.json(f.verticalAccuracy)
        s += ",\"spd\":" + Num.json(f.speed)
        s += ",\"spdAcc\":" + Num.json(f.speedAccuracy)
        s += ",\"crs\":" + Num.json(f.course)
        s += ",\"crsAcc\":" + Num.json(f.courseAccuracy)
        s += ",\"sim\":" + bool(f.isSimulatedBySoftware)
        s += ",\"acc\":" + bool(f.isProducedByAccessory)
        s += "}\n"
        return s
    }

    static func line(for g: Gap) -> String {
        "{\"type\":\"gap\",\"start\":\(g.startMs),\"end\":\(g.endMs),\"reason\":\"\(g.reason.rawValue)\"}\n"
    }

    private static func bool(_ b: Bool?) -> String {
        guard let b else { return "null" }
        return b ? "true" : "false"
    }

    struct Contents: Sendable, Equatable {
        var fixes: [Fix] = []
        var gaps: [Gap] = []
        /// Lines that could not be parsed (a truncated last line, for example).
        var skippedLines = 0
        var headerVersion: Int?
    }

    /// Parses a whole fix file. Tolerates a missing trailing newline, a truncated last record and
    /// unknown record types.
    static func parse(_ data: Data) -> Contents {
        var out = Contents()
        var lineIndex = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let n = bytes.count
            while start < n {
                var end = start
                while end < n && bytes[end] != 0x0A { end += 1 }
                if end > start {
                    let lineData = Data(bytes: base + start, count: end - start)
                    parseLine(lineData, index: lineIndex, into: &out)
                    lineIndex += 1
                }
                start = end + 1
            }
        }
        return out
    }

    private static func parseLine(_ data: Data, index: Int, into out: inout Contents) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            out.skippedLines += 1
            return
        }
        if index == 0, obj["format"] as? String == format {
            out.headerVersion = obj["version"] as? Int
            return
        }
        if let type = obj["type"] as? String {
            if type == "gap", let s = int64(obj["start"]), let e = int64(obj["end"]),
               let r = (obj["reason"] as? String).flatMap(Gap.Reason.init(rawValue:)) {
                out.gaps.append(Gap(startMs: s, endMs: e, reason: r))
            } else {
                out.skippedLines += 1
            }
            return
        }
        guard let t = int64(obj["t"]), let lat = double(obj["lat"]), let lon = double(obj["lon"]) else {
            out.skippedLines += 1
            return
        }
        out.fixes.append(Fix(
            timestampMs: t, latitude: lat, longitude: lon,
            horizontalAccuracy: double(obj["hAcc"]),
            altitude: double(obj["alt"]),
            ellipsoidalAltitude: double(obj["ellAlt"]),
            verticalAccuracy: double(obj["vAcc"]),
            speed: double(obj["spd"]),
            speedAccuracy: double(obj["spdAcc"]),
            course: double(obj["crs"]),
            courseAccuracy: double(obj["crsAcc"]),
            isSimulatedBySoftware: obj["sim"] as? Bool,
            isProducedByAccessory: obj["acc"] as? Bool
        ))
    }

    private static func double(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !(v is NSNull) else { return nil }
        return n.doubleValue
    }

    private static func int64(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        return n.int64Value
    }
}

/// Appends records to a fix file. Each record goes to the kernel with one `write` call as soon
/// as it arrives, so terminating the process loses nothing; `sync()` forces it to storage.
nonisolated final class FixFileWriter {
    private let handle: FileHandle
    let url: URL
    private(set) var lastSync = Date.distantPast

    /// Opens an existing fix file for appending, or creates it with the header line.
    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let created = fm.createFile(
                atPath: url.path, contents: Data(FixFile.header.utf8),
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            if !created { throw CocoaError(.fileWriteUnknown) }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // A crash may have left a truncated last record without its newline. Start on a fresh
        // line so the next record stays parseable; the reader skips the broken one.
        if try needsLeadingNewline() {
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }

    private func needsLeadingNewline() throws -> Bool {
        let size = try handle.offset()
        guard size > 0 else { return false }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: size - 1)
        let last = try reader.read(upToCount: 1)
        return last != Data([0x0A])
    }

    func append(_ fix: Fix) throws {
        try handle.write(contentsOf: Data(FixFile.line(for: fix).utf8))
    }

    func append(_ gap: Gap) throws {
        try handle.write(contentsOf: Data(FixFile.line(for: gap).utf8))
    }

    /// Writes raw bytes, for tests that simulate a crash mid-record.
    func appendRaw(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func sync() throws {
        try handle.synchronize()
        lastSync = Date()
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    deinit { try? handle.close() }
}
