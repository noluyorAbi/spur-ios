import Foundation

/// The bundled offline road pack (SPEC 14.2): one file with one LZFSE-compressed Overpass JSON
/// answer per z13 tile, so pack tiles and live tiles go through the same parser.
///
/// Layout, all integers little endian:
///
///     "SPURPACK"                      8 bytes magic
///     UInt32 headerLength             then the header as JSON (`RoadPackHeader`)
///     index, tileCount entries of 24 bytes:
///         Int32 x, Int32 y, UInt64 offset (from the start of the blobs), UInt32 compressed, UInt32 raw
///     blobs
///
/// Road data © OpenStreetMap contributors, ODbL.
nonisolated struct RoadPackHeader: Codable, Sendable, Equatable {
    var version: Int = 1
    var zoom: Int = TileKey.zoom
    /// Human readable area, shown in Settings ("Dallas").
    var area: String
    /// Where the extract came from.
    var source: String
    /// Date of the OSM extract (the download), ISO 8601.
    var sourceDate: String
    /// When the pack was built, ISO 8601.
    var createdAt: String
    var bbox: BBox
    var tileCount: Int
    var compression: String = "lzfse"
    var format: String = "overpass-json"
    /// Sum of the uncompressed tile answers in bytes.
    var rawBytes: Int64 = 0
}

nonisolated enum RoadPackError: Error, Equatable {
    case badMagic
    case truncated
    case unsupportedVersion(Int)
    case decompressionFailed(TileKey)
}

nonisolated struct RoadPack: Sendable {
    static let magic = Data("SPURPACK".utf8)
    static let entrySize = 24
    /// File name of the bundled pack (gitignored like the font; the app works without it).
    static let bundledName = "roads"
    static let bundledExtension = "spurpack"

    struct Entry: Sendable, Equatable {
        var offset: UInt64
        var compressed: UInt32
        var raw: UInt32
    }

    let header: RoadPackHeader
    let fileSize: Int
    private let data: Data
    private let blobStart: Int
    private let index: [TileKey: Entry]

    var tiles: [TileKey] { index.keys.sorted() }

    func covers(_ key: TileKey) -> Bool { index[key] != nil }

    /// A pack tile entirely inside the extract's box (the header box). A tile crossing the edge
    /// holds only the roads inside the box: it is served, but also listed as missing and fetched
    /// live when allowed, and the cached live copy then wins.
    func isComplete(_ key: TileKey) -> Bool { covers(key) && RoadPackCoverage.isComplete(key, extract: header.bbox) }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        guard data.count >= 12, data.prefix(8) == RoadPack.magic else { throw RoadPackError.badMagic }
        let base = data.startIndex
        let headerLength = Int(data.readUInt32(at: base + 8))
        guard data.count >= 12 + headerLength else { throw RoadPackError.truncated }
        let header = try JSONDecoder().decode(RoadPackHeader.self, from: data.subdata(in: (base + 12)..<(base + 12 + headerLength)))
        guard header.version == 1 else { throw RoadPackError.unsupportedVersion(header.version) }
        let indexStart = 12 + headerLength
        let blobStart = indexStart + header.tileCount * RoadPack.entrySize
        guard data.count >= blobStart else { throw RoadPackError.truncated }
        var index: [TileKey: Entry] = [:]
        index.reserveCapacity(header.tileCount)
        for k in 0..<header.tileCount {
            let p = base + indexStart + k * RoadPack.entrySize
            let key = TileKey(z: header.zoom, x: Int(Int32(bitPattern: data.readUInt32(at: p))), y: Int(Int32(bitPattern: data.readUInt32(at: p + 4))))
            let entry = Entry(offset: data.readUInt64(at: p + 8), compressed: data.readUInt32(at: p + 16), raw: data.readUInt32(at: p + 20))
            guard blobStart + Int(entry.offset) + Int(entry.compressed) <= data.count else { throw RoadPackError.truncated }
            index[key] = entry
        }
        self.header = header
        self.data = data
        self.blobStart = blobStart
        self.index = index
        self.fileSize = data.count
    }

    /// The tile's Overpass JSON, decompressed. nil when the pack does not cover the tile.
    func json(for key: TileKey) throws -> Data? {
        guard let e = index[key] else { return nil }
        let start = data.startIndex + blobStart + Int(e.offset)
        let blob = data.subdata(in: start..<(start + Int(e.compressed)))
        guard let raw = try? (blob as NSData).decompressed(using: .lzfse) as Data, raw.count == Int(e.raw) else {
            throw RoadPackError.decompressionFailed(key)
        }
        return raw
    }

    /// The tile's elements, parsed. nil when the pack does not cover the tile.
    func elements(for key: TileKey) throws -> OSMElements? {
        guard let json = try json(for: key) else { return nil }
        return try OverpassParser.parse(json)
    }

    /// The bundled pack, if the build included one.
    static func bundled(in bundle: Bundle = .main) -> RoadPack? {
        guard let url = bundle.url(forResource: bundledName, withExtension: bundledExtension) else { return nil }
        return try? RoadPack(url: url)
    }
}

/// Writes a pack: blobs stream into a temporary file, `finish` puts header and index in front.
/// Which pack tiles are complete: those entirely inside the extract's box. A tile that crosses the
/// edge holds only the roads inside the box (`RoadPack.isComplete`).
nonisolated enum RoadPackCoverage {
    static func isComplete(_ key: TileKey, extract: BBox) -> Bool {
        extract.contains(key.bbox)
    }
}

nonisolated final class RoadPackWriter {
    private let blobURL: URL
    private let handle: FileHandle
    private var entries: [(TileKey, RoadPack.Entry)] = []
    private var offset: UInt64 = 0
    private(set) var rawBytes: Int64 = 0

    init(scratch: URL) throws {
        blobURL = scratch
        FileManager.default.createFile(atPath: scratch.path, contents: nil)
        handle = try FileHandle(forWritingTo: scratch)
    }

    /// Adds one tile's Overpass JSON.
    func add(_ key: TileKey, json: Data) throws {
        guard let blob = try? (json as NSData).compressed(using: .lzfse) as Data else { throw RoadPackError.decompressionFailed(key) }
        try handle.write(contentsOf: blob)
        entries.append((key, RoadPack.Entry(offset: offset, compressed: UInt32(blob.count), raw: UInt32(json.count))))
        offset += UInt64(blob.count)
        rawBytes += Int64(json.count)
    }

    var count: Int { entries.count }

    /// Writes the finished pack to `url` and removes the scratch file.
    func finish(to url: URL, header: RoadPackHeader) throws {
        try handle.close()
        var h = header
        h.tileCount = entries.count
        h.rawBytes = rawBytes
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let headerData = try enc.encode(h)
        var front = Data()
        front.append(RoadPack.magic)
        front.appendUInt32(UInt32(headerData.count))
        front.append(headerData)
        for (key, e) in entries.sorted(by: { $0.0 < $1.0 }) {
            front.appendUInt32(UInt32(bitPattern: Int32(key.x)))
            front.appendUInt32(UInt32(bitPattern: Int32(key.y)))
            front.appendUInt64(e.offset)
            front.appendUInt32(e.compressed)
            front.appendUInt32(e.raw)
        }
        FileManager.default.createFile(atPath: url.path, contents: front)
        let out = try FileHandle(forWritingTo: url)
        try out.seekToEnd()
        let input = try FileHandle(forReadingFrom: blobURL)
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try input.close()
        try out.close()
        try? FileManager.default.removeItem(at: blobURL)
    }
}

nonisolated extension Data {
    func readUInt32(at i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(self[i + k]) << (8 * UInt32(k)) }
        return v
    }

    func readUInt64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[i + k]) << (8 * UInt64(k)) }
        return v
    }

    mutating func appendUInt32(_ v: UInt32) {
        for k in 0..<4 { append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) }
    }

    mutating func appendUInt64(_ v: UInt64) {
        for k in 0..<8 { append(UInt8((v >> (8 * UInt64(k))) & 0xFF)) }
    }
}
