import Foundation

/// One device-motion sample as CoreMotion delivers it (SPEC 16.3.1), stored raw.
nonisolated struct MotionSample: Sendable, Equatable {
    /// Wall-clock time, unix seconds.
    var time: Double
    /// `userAcceleration` in g, device axes.
    var userAcceleration: SIMD3<Float>
    /// `gravity` in g, device axes (points toward the earth).
    var gravity: SIMD3<Float>
    /// `rotationRate` in rad/s, device axes, right-hand rule.
    var rotationRate: SIMD3<Float>
    /// `attitude.quaternion` as x, y, z, w.
    var attitude: SIMD4<Float>
}

/// The append-only motion file `motion.bin` next to the fixes (SPEC 16.3.1,
/// `docs/MOTION-FORMAT.md`). Little-endian.
///
/// Header, 32 bytes: magic `SPURMOT\0` (8), format version UInt16, record size UInt16, nominal
/// rate in Hz UInt16, reference frame UInt8 (1 = CoreMotion `xArbitraryZVertical`), reserved
/// UInt8, creation time Float64 (unix s), 8 reserved zero bytes.
///
/// Record, 60 bytes: time Float64 (unix s), then 13 Float32: userAcceleration x y z (g), gravity
/// x y z (g), rotationRate x y z (rad/s), attitude quaternion x y z w. Nothing filtered or
/// downsampled. A truncated last record (crash mid-write) is ignored on read and cut off before
/// the next append, so records stay aligned.
nonisolated enum MotionFile {
    static let fileName = "motion.bin"
    static let magic: [UInt8] = Array("SPURMOT".utf8) + [0]
    static let version: UInt16 = 1
    static let headerSize = 32
    static let recordSize = 60
    static let frameXArbitraryZVertical: UInt8 = 1

    struct Header: Sendable, Equatable {
        var version: UInt16
        var recordSize: UInt16
        var rateHz: UInt16
        var frame: UInt8
        var created: Double
    }

    struct Contents: Sendable {
        var header: Header?
        var samples: [MotionSample] = []
        /// Bytes after the last whole record.
        var truncatedBytes = 0
    }

    static func header(rateHz: Int, created: Double) -> Data {
        var d = Data(magic)
        d.appendLE(version)
        d.appendLE(UInt16(recordSize))
        d.appendLE(UInt16(clamping: rateHz))
        d.append(frameXArbitraryZVertical)
        d.append(0)
        d.appendLE(created.bitPattern)
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return d
    }

    static func append(_ s: MotionSample, to d: inout Data) {
        d.appendLE(s.time.bitPattern)
        for v in [s.userAcceleration.x, s.userAcceleration.y, s.userAcceleration.z,
                  s.gravity.x, s.gravity.y, s.gravity.z,
                  s.rotationRate.x, s.rotationRate.y, s.rotationRate.z,
                  s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w] {
            d.appendLE(v.bitPattern)
        }
    }

    static func encode(_ samples: [MotionSample]) -> Data {
        var d = Data(capacity: samples.count * recordSize)
        for s in samples { append(s, to: &d) }
        return d
    }

    static func parse(_ data: Data) -> Contents {
        var out = Contents()
        guard data.count >= headerSize else {
            out.truncatedBytes = data.count
            return out
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard Array(raw[0..<8]) == magic else { return }
            let header = Header(version: raw.loadLE(UInt16.self, at: 8), recordSize: raw.loadLE(UInt16.self, at: 10),
                                rateHz: raw.loadLE(UInt16.self, at: 12), frame: raw[14],
                                created: Double(bitPattern: raw.loadLE(UInt64.self, at: 16)))
            out.header = header
            let size = Int(header.recordSize)
            guard header.version == version, size >= recordSize else { return }
            let body = raw.count - headerSize
            let count = body / size
            out.truncatedBytes = body - count * size
            out.samples.reserveCapacity(count)
            for k in 0..<count {
                let o = headerSize + k * size
                func f(_ i: Int) -> Float { Float(bitPattern: raw.loadLE(UInt32.self, at: o + 8 + 4 * i)) }
                out.samples.append(MotionSample(
                    time: Double(bitPattern: raw.loadLE(UInt64.self, at: o)),
                    userAcceleration: SIMD3(f(0), f(1), f(2)), gravity: SIMD3(f(3), f(4), f(5)),
                    rotationRate: SIMD3(f(6), f(7), f(8)), attitude: SIMD4(f(9), f(10), f(11), f(12))))
            }
        }
        return out
    }

    static func read(_ url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return parse(data)
    }

    /// Bytes per hour at a rate, header excluded.
    static func bytesPerHour(rateHz: Int) -> Int { rateHz * 3600 * recordSize }

    /// The header of an existing file, nil when it has none.
    static func header(of url: URL) -> Header? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: headerSize), d.count == headerSize else { return nil }
        return parse(d).header
    }
}

/// Samples by index without materializing them (SPEC 16.3.2 memory): the analysis and the sensor
/// CSV read through this, so an 8 hour file is never copied into 80-byte structs.
nonisolated protocol MotionSampleSource {
    var count: Int { get }
    func time(_ i: Int) -> Double
    /// `userAcceleration`, g.
    func user(_ i: Int) -> SIMD3<Double>
    /// `gravity`, g.
    func gravity(_ i: Int) -> SIMD3<Double>
    /// `rotationRate`, rad/s.
    func rotation(_ i: Int) -> SIMD3<Double>
    func sample(_ i: Int) -> MotionSample
}

nonisolated extension Array: MotionSampleSource where Element == MotionSample {
    func time(_ i: Int) -> Double { self[i].time }
    func user(_ i: Int) -> SIMD3<Double> { SIMD3<Double>(self[i].userAcceleration) }
    func gravity(_ i: Int) -> SIMD3<Double> { SIMD3<Double>(self[i].gravity) }
    func rotation(_ i: Int) -> SIMD3<Double> { SIMD3<Double>(self[i].rotationRate) }
    func sample(_ i: Int) -> MotionSample { self[i] }
}

/// `motion.bin` memory-mapped (clean, evictable pages, not the app's footprint). Records that are
/// implausible are skipped: outside the trip's time window, or not later than the record before
/// (a misaligned tail after a failed write, a clock step). Only then is an index list kept.
nonisolated final class MappedMotionFile: MotionSampleSource, @unchecked Sendable {
    let header: MotionFile.Header
    /// Bytes after the last whole record.
    let truncatedBytes: Int
    /// Whole records skipped as implausible.
    let rejected: Int
    let count: Int
    private let data: NSData
    private let base: UnsafeRawPointer
    private let stride: Int
    private let index: [Int32]?

    init?(url: URL, window: ClosedRange<Double>? = nil) {
        guard let data = try? NSData(contentsOf: url, options: .alwaysMapped), data.length >= MotionFile.headerSize else { return nil }
        let head = MotionFile.parse(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: data.bytes), count: MotionFile.headerSize, deallocator: .none))
        guard let header = head.header, header.version == MotionFile.version, Int(header.recordSize) >= MotionFile.recordSize else { return nil }
        self.data = data
        self.header = header
        base = data.bytes
        stride = Int(header.recordSize)
        let body = data.length - MotionFile.headerSize
        let records = body / stride
        truncatedBytes = body - records * stride
        var kept: [Int32] = []
        var skipping = false
        var last = -Double.infinity
        for k in 0..<records {
            let t = Double(bitPattern: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: MotionFile.headerSize + k * stride, as: UInt64.self)))
            let ok = t.isFinite && t > last && (window?.contains(t) ?? true)
            if ok { last = t }
            if !ok && !skipping {
                skipping = true
                kept = (0..<k).map { Int32($0) }
            }
            if skipping && ok { kept.append(Int32(k)) }
        }
        index = skipping ? kept : nil
        count = skipping ? kept.count : records
        rejected = records - count
    }

    @inline(__always) private func offset(_ i: Int) -> Int {
        MotionFile.headerSize + (index.map { Int($0[i]) } ?? i) * stride
    }

    @inline(__always) private func float(_ o: Int, _ k: Int) -> Float {
        Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o + 8 + 4 * k, as: UInt32.self)))
    }

    func time(_ i: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset(i), as: UInt64.self)))
    }

    func user(_ i: Int) -> SIMD3<Double> {
        let o = offset(i)
        return SIMD3(Double(float(o, 0)), Double(float(o, 1)), Double(float(o, 2)))
    }

    func gravity(_ i: Int) -> SIMD3<Double> {
        let o = offset(i)
        return SIMD3(Double(float(o, 3)), Double(float(o, 4)), Double(float(o, 5)))
    }

    func rotation(_ i: Int) -> SIMD3<Double> {
        let o = offset(i)
        return SIMD3(Double(float(o, 6)), Double(float(o, 7)), Double(float(o, 8)))
    }

    func sample(_ i: Int) -> MotionSample {
        let o = offset(i)
        return MotionSample(time: time(i), userAcceleration: SIMD3(float(o, 0), float(o, 1), float(o, 2)),
                            gravity: SIMD3(float(o, 3), float(o, 4), float(o, 5)),
                            rotationRate: SIMD3(float(o, 6), float(o, 7), float(o, 8)),
                            attitude: SIMD4(float(o, 9), float(o, 10), float(o, 11), float(o, 12)))
    }
}

/// Appends records to a motion file; owned by one queue (the motion queue). Records go to the
/// kernel in batches; `sync()` forces them to storage.
///
/// A failed write is rolled back to the last whole batch, so a partly written batch never shifts
/// the records after it. Times are kept strictly increasing per file: a batch that would start at
/// or before the last written time (a wall-clock step, a resume) is shifted after it, with its
/// spacing kept.
nonisolated final class MotionFileWriter {
    let url: URL
    /// The file's own rate: a resumed trip keeps it, whatever the setting says now.
    let rateHz: Int
    private let handle: FileHandle
    private var goodOffset: UInt64
    private var lastTime = -Double.infinity
    private(set) var lastSync = Date.distantPast
    /// Tests: replaces the write of a batch, to fail part-way.
    var writeHook: ((FileHandle, Data) throws -> Void)?

    /// Opens an existing motion file for appending (cutting a truncated last record), or creates
    /// it with the header. A file shorter than the header (a crash while creating it) is rewritten.
    init(url: URL, rateHz: Int, created: Double = Date().timeIntervalSince1970) throws {
        self.url = url
        let fm = FileManager.default
        let existing = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let header = existing.flatMap { $0 >= MotionFile.headerSize ? MotionFile.header(of: url) : nil }
        if existing == nil || header == nil {
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: MotionFile.header(rateHz: rateHz, created: created),
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        self.rateHz = header.map { Int($0.rateHz) } ?? rateHz
        handle = try FileHandle(forUpdating: url)
        let size = Int(try handle.seekToEnd())
        let body = max(0, size - MotionFile.headerSize)
        let aligned = MotionFile.headerSize + body / MotionFile.recordSize * MotionFile.recordSize
        if aligned != size {
            try handle.truncate(atOffset: UInt64(aligned))
            try handle.seekToEnd()
        }
        goodOffset = UInt64(aligned)
        if aligned > MotionFile.headerSize {
            try handle.seek(toOffset: UInt64(aligned - MotionFile.recordSize))
            if let d = try handle.read(upToCount: 8), d.count == 8 {
                lastTime = d.withUnsafeBytes { Double(bitPattern: $0.loadLE(UInt64.self, at: 0)) }
            }
            try handle.seekToEnd()
        }
    }

    /// Writes the batch, or rolls the file back to the last whole batch and throws.
    func append(_ samples: [MotionSample]) throws {
        guard !samples.isEmpty else { return }
        var batch = samples
        if let first = batch.first?.time, first <= lastTime {
            let step = batch.count > 1 ? max(1e-4, (batch[batch.count - 1].time - first) / Double(batch.count - 1)) : 1 / Double(max(1, rateHz))
            let shift = lastTime + step - first
            for k in batch.indices { batch[k].time += shift }
        }
        for k in batch.indices.dropFirst() where batch[k].time <= batch[k - 1].time {
            batch[k].time = batch[k - 1].time + 1e-4
        }
        let data = MotionFile.encode(batch)
        do {
            if let writeHook { try writeHook(handle, data) } else { try handle.write(contentsOf: data) }
        } catch {
            try? handle.truncate(atOffset: goodOffset)
            _ = try? handle.seekToEnd()
            throw error
        }
        goodOffset += UInt64(data.count)
        lastTime = batch[batch.count - 1].time
    }

    /// Raw bytes, for tests that simulate a crash mid-record.
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

nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

nonisolated extension UnsafeRawBufferPointer {
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}

nonisolated extension TripRecord {
    /// Motion records outside this window are implausible: the trip's time with a minute of
    /// slack on each side.
    var motionWindow: ClosedRange<Double> {
        let start = startedAt.timeIntervalSince1970 - 60
        let end = (endedAt ?? Date()).timeIntervalSince1970 + 60
        return start...max(start, end)
    }
}
