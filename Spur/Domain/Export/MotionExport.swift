import Foundation

/// Version 1.2 (SPEC 16.3.4): the motion sensor in the exports.

nonisolated extension MotionEvent.Kind {
    /// German name, as on the map and in GPX waypoints.
    var label: String {
        switch self {
        case .hardBraking: "Starke Bremsung"
        case .hardAcceleration: "Starke Beschleunigung"
        case .lateralLeft: "Starke Querbeschleunigung links"
        case .lateralRight: "Starke Querbeschleunigung rechts"
        case .bump: "Stoß"
        }
    }

    /// The GPX `type` and GeoJSON `type` of a motion event.
    var exportType: String { "motion.\(rawValue)" }
}

nonisolated extension MotionEvent {
    static func ms(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }
}

/// "Sensordaten (CSV)": every sample of `motion.bin` at full rate, the raw channels plus the
/// vehicle frame of the analysis (`MotionAnalyzer.vehicleFrame`). Empty `long_mps2` and
/// `lat_mps2` mean the sample's mount segment is not aligned (`aligned` = 0). `vert_mps2` is the
/// physical vertical acceleration, + up, gravity removed (the raw `user_*` columns keep
/// CoreMotion's sign, which is minus the physical acceleration).
nonisolated enum MotionCSVExporter {
    static let header = "time_s,user_ax_g,user_ay_g,user_az_g,gravity_x_g,gravity_y_g,gravity_z_g,"
        + "rotation_x_rad_s,rotation_y_rad_s,rotation_z_rad_s,attitude_qx,attitude_qy,attitude_qz,attitude_qw,"
        + "long_mps2,lat_mps2,vert_mps2,aligned,handling"
    /// About this many bytes per row (157 measured on an 8 hour synthetic file, real values carry
    /// more digits), for the size shown before an export: about 60 MB per hour at 100 Hz.
    static let bytesPerRow = 165

    /// The whole CSV as a string (tests, short trips).
    static func export(samples: [MotionSample], fixes: [Fix]) -> String {
        var out: [UInt8] = []
        let frame = MotionAnalyzer.vehicleFrame(source: samples, fixes: fixes)
        out.append(contentsOf: Array((header + "\n").utf8))
        rows(samples, frame, 0..<samples.count, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    static func write(samples: [MotionSample], fixes: [Fix], to url: URL) throws {
        try write(source: samples, fixes: fixes, to: url)
    }

    /// Writes the CSV to `url` in chunks of about a megabyte: an hour at 100 Hz is about 70 MB of
    /// text. `progress` gets the share done and returns false to cancel (the file is removed).
    static func write<S: MotionSampleSource>(source: S, fixes: [Fix], to url: URL,
                                             progress: (Double) -> Bool = { _ in true }) throws {
        let frame = MotionAnalyzer.vehicleFrame(source: source, fixes: fixes)
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: url) }
        }
        try handle.write(contentsOf: Data((header + "\n").utf8))
        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 20 + 4096)
        var start = 0
        let chunk = 5000
        while start < source.count {
            let end = min(source.count, start + chunk)
            rows(source, frame, start..<end, into: &buffer)
            try handle.write(contentsOf: Data(buffer))
            buffer.removeAll(keepingCapacity: true)
            start = end
            guard progress(Double(start) / Double(max(1, source.count))) else { throw CancellationError() }
        }
        finished = true
    }

    private static func rows<S: MotionSampleSource>(_ source: S, _ frame: MotionAnalyzer.VehicleFrame, _ range: Range<Int>,
                                                    into out: inout [UInt8]) {
        let comma = UInt8(ascii: ",")
        for i in range {
            let s = source.sample(i)
            FastNum.append(s.time, 6, to: &out)
            for v in [s.userAcceleration.x, s.userAcceleration.y, s.userAcceleration.z,
                      s.gravity.x, s.gravity.y, s.gravity.z,
                      s.rotationRate.x, s.rotationRate.y, s.rotationRate.z,
                      s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w] {
                out.append(comma)
                FastNum.append(Double(v), 6, to: &out)
            }
            let long = i < frame.long.count ? frame.long[i] : .nan
            let lat = i < frame.lat.count ? frame.lat[i] : .nan
            out.append(comma)
            if !long.isNaN { FastNum.append(Double(long), 3, to: &out) }
            out.append(comma)
            if !lat.isNaN { FastNum.append(Double(lat), 3, to: &out) }
            out.append(comma)
            if i < frame.vert.count { FastNum.append(Double(frame.vert[i]), 3, to: &out) }
            out.append(comma)
            out.append(!long.isNaN ? UInt8(ascii: "1") : UInt8(ascii: "0"))
            out.append(comma)
            out.append(i < frame.handling.count && frame.handling[i] ? UInt8(ascii: "1") : UInt8(ascii: "0"))
            out.append(UInt8(ascii: "\n"))
        }
    }
}

/// `Num.fixed` without `String(format:)`: rounds to `digits` decimals, drops trailing zeros, never
/// "-0", nothing for a non-finite value. Fast enough for a few million numbers.
nonisolated enum FastNum {
    private static let scale: [Double] = [1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8]

    static func string(_ v: Double, _ digits: Int) -> String {
        var out: [UInt8] = []
        append(v, digits, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    static func append(_ v: Double, _ digits: Int, to out: inout [UInt8]) {
        guard v.isFinite else { return }
        let scaled = (abs(v) * scale[digits]).rounded()
        guard scaled < 9e15 else {
            out.append(contentsOf: Array(Num.fixed(v, digits).utf8))
            return
        }
        let n = Int64(scaled)
        if n == 0 {
            out.append(UInt8(ascii: "0"))
            return
        }
        if v < 0 { out.append(UInt8(ascii: "-")) }
        let p = Int64(scale[digits])
        appendInteger(n / p, to: &out)
        var frac = n % p
        guard frac > 0 else { return }
        var places = digits
        while frac % 10 == 0 {
            frac /= 10
            places -= 1
        }
        out.append(UInt8(ascii: "."))
        let at = out.count
        for _ in 0..<places {
            out.append(UInt8(ascii: "0") + UInt8(frac % 10))
            frac /= 10
        }
        out[at...].reverse()
    }

    private static func appendInteger(_ n: Int64, to out: inout [UInt8]) {
        if n == 0 {
            out.append(UInt8(ascii: "0"))
            return
        }
        let at = out.count
        var m = n
        while m > 0 {
            out.append(UInt8(ascii: "0") + UInt8(m % 10))
            m /= 10
        }
        out[at...].reverse()
    }
}

/// A motion event in the JSON export.
nonisolated struct MotionEventExport: Encodable {
    var type: String
    var label: String
    var start: String
    var end: String
    var peakTime: String
    /// m/s², signed as in the vehicle frame (braking negative, left positive, bump as |vert|).
    var peak: Double
    var peakG: Double
    var lat: Double?
    var lon: Double?
    var speed: Double?
    var street: String?

    init(_ e: MotionEvent) {
        type = e.kind.exportType
        label = e.kind.label
        start = Num.iso(ms: MotionEvent.ms(e.start))
        end = Num.iso(ms: MotionEvent.ms(e.end))
        peakTime = Num.iso(ms: MotionEvent.ms(e.peakTime))
        peak = (e.peak * 1000).rounded() / 1000
        peakG = (e.peak / MotionConstants.g * 1000).rounded() / 1000
        lat = e.latitude
        lon = e.longitude
        speed = e.speed.map { ($0 * 100).rounded() / 100 }
        street = e.street
    }
}

/// Trailing `trips.csv` columns of version 1.2, empty for a trip without motion data.
nonisolated enum MotionSummaryColumns {
    /// `max_braking_mps2` and `max_lateral_right_mps2` are negative (braking, right); the event
    /// counts that need alignment are empty, not 0, when no segment is aligned.
    static let header = ",motion_coverage,motion_aligned_share,motion_alignment_good,motion_r_long,motion_r_lat,"
        + "max_braking_mps2,max_acceleration_mps2,max_lateral_left_mps2,max_lateral_right_mps2,"
        + "hard_brakings,very_hard_brakings,hard_accelerations,lateral_events,bumps"
    static let count = 14

    static func fields(_ m: MotionSummary?) -> [String] {
        guard let m else { return Array(repeating: "", count: count) }
        let aligned = m.isAligned
        func n(_ v: Int) -> String { aligned ? String(v) : "" }
        return [
            m.coverage.map { Num.fixed($0, 4) } ?? "",
            m.alignedShare.map { Num.fixed($0, 4) } ?? "",
            aligned ? (m.alignmentGood ? "true" : "false") : "",
            m.rLong.map { Num.fixed($0, 3) } ?? "",
            m.rLat.map { Num.fixed($0, 3) } ?? "",
            m.maxBraking.map { Num.fixed($0, 2) } ?? "",
            m.maxAcceleration.map { Num.fixed($0, 2) } ?? "",
            m.maxLateralLeft.map { Num.fixed($0, 2) } ?? "",
            m.maxLateralRight.map { Num.fixed($0, 2) } ?? "",
            n(m.counts.hardBraking),
            n(m.counts.veryHardBraking),
            n(m.counts.hardAcceleration),
            n(m.counts.lateralLeft + m.counts.lateralRight),
            String(m.counts.bumps),
        ]
    }
}
