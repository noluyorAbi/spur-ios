import Foundation

/// On-device cache of road tiles fetched from Overpass (SPEC 14.2): `Application Support/Spur/OSM/`,
/// one LZFSE-compressed file per tile in the parsed compact form (only the tags Spur reads).
///
/// - TTL 30 days. An expired tile is still served (old road data beats none) but reported as
///   expired, so the provider refreshes it when the internet setting allows.
/// - Size cap 300 MB, least recently used tiles are evicted first. The last access is the file's
///   modification date, the fetch time its creation date, so the index is rebuilt from a
///   directory listing without reading any tile.
/// - Written with `completeUntilFirstUserAuthentication`, so tiles can be stored while the phone
///   is locked during a trip.
nonisolated final class RoadTileCache: @unchecked Sendable {
    static let defaultTTL: TimeInterval = 30 * 24 * 3600
    static let defaultCapBytes = 300 * 1024 * 1024
    static let fileExtension = "tile"

    struct Meta: Equatable, Sendable {
        var fetchedAt: Date
        var lastAccess: Date
        var size: Int
    }

    struct Hit: Sendable {
        var elements: OSMElements
        var fetchedAt: Date
        var isExpired: Bool
    }

    let directory: URL
    let ttl: TimeInterval
    let capBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var index: [TileKey: Meta]?
    private let fm = FileManager.default

    init(directory: URL, ttl: TimeInterval = RoadTileCache.defaultTTL, capBytes: Int = RoadTileCache.defaultCapBytes,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.ttl = ttl
        self.capBytes = capBytes
        self.now = now
    }

    static func appDefault() -> RoadTileCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RoadTileCache(directory: base.appendingPathComponent("Spur/OSM", isDirectory: true))
    }

    private func url(_ key: TileKey) -> URL {
        directory.appendingPathComponent(key.fileStem).appendingPathExtension(Self.fileExtension)
    }

    /// The index, rebuilt from the directory on first use. Call with the lock held.
    private func loadedIndex() -> [TileKey: Meta] {
        if let index { return index }
        var out: [TileKey: Meta] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for file in files where file.pathExtension == Self.fileExtension {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let key = TileKey(z: parts[0], x: parts[1], y: parts[2])
            out[key] = Meta(fetchedAt: values.creationDate ?? .distantPast,
                            lastAccess: values.contentModificationDate ?? .distantPast,
                            size: values.fileSize ?? 0)
        }
        index = out
        return out
    }

    var totalBytes: Int {
        lock.withLock { loadedIndex().values.reduce(0) { $0 + $1.size } }
    }

    var count: Int { lock.withLock { loadedIndex().count } }

    var keys: [TileKey] { lock.withLock { loadedIndex().keys.sorted() } }

    func meta(_ key: TileKey) -> Meta? { lock.withLock { loadedIndex()[key] } }

    func contains(_ key: TileKey) -> Bool { meta(key) != nil }

    func isExpired(_ key: TileKey) -> Bool {
        guard let m = meta(key) else { return true }
        return now().timeIntervalSince(m.fetchedAt) > ttl
    }

    /// Reads a tile and marks it as used now.
    func read(_ key: TileKey) -> Hit? {
        lock.lock()
        defer { lock.unlock() }
        var idx = loadedIndex()
        guard var m = idx[key] else { return nil }
        guard let blob = try? Data(contentsOf: url(key)),
              let raw = try? (blob as NSData).decompressed(using: .lzfse) as Data,
              let elements = try? JSONDecoder().decode(OSMElements.self, from: raw) else {
            // Unreadable: drop it, the provider fetches it again.
            try? fm.removeItem(at: url(key))
            idx[key] = nil
            index = idx
            return nil
        }
        let t = now()
        m.lastAccess = t
        idx[key] = m
        index = idx
        try? fm.setAttributes([.modificationDate: t], ofItemAtPath: url(key).path)
        return Hit(elements: elements, fetchedAt: m.fetchedAt, isExpired: t.timeIntervalSince(m.fetchedAt) > ttl)
    }

    /// Stores a tile (replacing an older copy) and evicts least recently used tiles above the cap.
    func write(_ key: TileKey, elements: OSMElements, fetchedAt: Date? = nil) throws {
        let raw = try JSONEncoder().encode(elements)
        guard let blob = try? (raw as NSData).compressed(using: .lzfse) as Data else { return }
        lock.lock()
        defer { lock.unlock() }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: TripStore.protection)
        let t = fetchedAt ?? now()
        let target = url(key)
        try blob.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? fm.setAttributes([.creationDate: t, .modificationDate: now()], ofItemAtPath: target.path)
        var idx = loadedIndex()
        idx[key] = Meta(fetchedAt: t, lastAccess: now(), size: blob.count)
        index = idx
        evictLocked(keeping: key)
    }

    /// Least recently used first, until the total is at most the cap. The tile just written stays.
    private func evictLocked(keeping keep: TileKey?) {
        var idx = loadedIndex()
        var total = idx.values.reduce(0) { $0 + $1.size }
        guard total > capBytes else { return }
        for (key, m) in idx.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) where key != keep {
            try? fm.removeItem(at: url(key))
            idx[key] = nil
            total -= m.size
            if total <= capBytes { break }
        }
        index = idx
    }

    /// "Straßendaten-Cache leeren".
    func clear() {
        lock.withLock {
            for key in loadedIndex().keys { try? fm.removeItem(at: url(key)) }
            index = [:]
        }
    }
}
