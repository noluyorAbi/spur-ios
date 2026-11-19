import Foundation

/// Where a tile came from (SPEC 14.2 source chain).
nonisolated enum RoadTileSource: String, Codable, Sendable, CaseIterable {
    /// On-device cache of tiles fetched from Overpass earlier.
    case cache
    /// The bundled offline pack.
    case pack
    /// Fetched from Overpass during this call.
    case live
}

/// Synchronous lookups in the cache and the pack (no network): what the trip analysis reads off
/// the main actor. Thread safe: the cache locks, the pack is immutable.
nonisolated struct LocalTiles: Sendable {
    let cache: RoadTileCache
    let pack: RoadPack?

    func tile(_ key: TileKey) -> (OSMElements, RoadTileSource)? {
        if let hit = cache.read(key) { return (hit.elements, .cache) }
        if let pack, let e = try? pack.elements(for: key) { return (e, .pack) }
        return nil
    }

    /// True when a complete copy of the tile is on the device: in the cache, or a pack tile
    /// entirely inside the extract.
    func isComplete(_ key: TileKey) -> Bool {
        cache.contains(key) || (pack?.isComplete(key) ?? false)
    }

    /// The merged elements of the tiles available locally, their sources, and the tiles missing.
    /// A partial pack tile (at the extract's edge, not yet cached) is used and also listed as missing.
    func lookup(_ keys: [TileKey]) -> RoadTileProvider.Lookup {
        var parts: [OSMElements] = []
        var sources: [TileKey: RoadTileSource] = [:]
        var missing: [TileKey] = []
        for key in Set(keys).sorted() {
            if let (e, s) = tile(key) {
                parts.append(e)
                sources[key] = s
                if s == .pack, !(pack?.isComplete(key) ?? true) { missing.append(key) }
            } else {
                missing.append(key)
            }
        }
        return RoadTileProvider.Lookup(elements: .merged(parts), sources: sources, missing: missing)
    }
}

/// The source chain for road tiles, first hit wins: (1) on-device cache, (2) bundled offline pack,
/// (3) live Overpass, the last only for tiles the pack does not cover and only while the setting
/// "Straßendaten aus dem Internet laden" is on. Live fetches run in the background, one at a
/// time; failures are silent and retried later. Nothing here ever blocks recording.
actor RoadTileProvider {
    struct Lookup: Sendable {
        var elements: OSMElements
        var sources: [TileKey: RoadTileSource]
        /// Tiles with no data from any source yet.
        var missing: [TileKey]
    }

    struct PreloadResult: Sendable, Equatable {
        var total: Int
        var available: Int
        var failed: Int
        var cancelled: Bool
    }

    nonisolated let cache: RoadTileCache
    nonisolated let pack: RoadPack?
    nonisolated var local: LocalTiles { LocalTiles(cache: cache, pack: pack) }
    private let client: OverpassClient?
    private(set) var liveEnabled: Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var queue: [TileKey] = []
    private var queued: Set<TileKey> = []
    private var retryAfter: [TileKey: Date] = [:]
    private var attempts: [TileKey: Int] = [:]
    private var loop: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<TileKey>.Continuation] = [:]
    /// Tiles whose live fetch failed; asked for again once their back-off ends.
    private var failed: Set<TileKey> = []
    private var retryLoop: Task<Void, Never>?

    init(cache: RoadTileCache, pack: RoadPack?, client: OverpassClient?, liveEnabled: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.cache = cache
        self.pack = pack
        self.client = client
        self.liveEnabled = liveEnabled
        self.now = now
        self.sleep = sleep
    }

    func setLiveEnabled(_ on: Bool) {
        liveEnabled = on
        if on {
            startLoop()
            scheduleRetry()
        } else {
            // Turning the setting off stops the request in flight too, not only the next one: the
            // cancelled tile goes back into the queue without a penalty, for when it is on again.
            loop?.cancel()
            retryLoop?.cancel()
        }
    }

    /// New tiles as they arrive from Overpass.
    func updates() -> AsyncStream<TileKey> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TileKey>.makeStream(bufferingPolicy: .bufferingNewest(256))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: Lookup without network

    // No parsed tiles are kept in memory here: every reader (the analysis, the live matcher)
    // reads the cache and the pack through `local`, so a copy here would only hold tens of MB.

    /// One tile from the cache or the pack, never from the network.
    func local(_ key: TileKey) -> (OSMElements, RoadTileSource)? {
        local.tile(key)
    }

    /// The merged elements of the tiles that are available locally, which source each came from,
    /// and which are missing.
    func lookup(_ keys: [TileKey]) -> Lookup {
        local.lookup(keys)
    }

    func isAvailable(_ key: TileKey) -> Bool {
        local.isComplete(key)
    }

    // MARK: Live

    /// True when Overpass is the only way to get (or refresh) this tile.
    func needsLive(_ key: TileKey) -> Bool {
        if pack?.isComplete(key) ?? false { return false }
        return !cache.contains(key) || cache.isExpired(key)
    }

    /// Asks for these tiles in the background (the tile under the car and its neighbours, or the
    /// tiles a finished trip still misses). Returns at once.
    func want(_ keys: [TileKey]) {
        guard liveEnabled, client != nil else { return }
        let t = now()
        for key in keys where needsLive(key) && !queued.contains(key) && (retryAfter[key] ?? .distantPast) <= t {
            queue.append(key)
            queued.insert(key)
        }
        startLoop()
    }

    private func startLoop() {
        guard loop == nil, liveEnabled, client != nil, !queue.isEmpty else { return }
        loop = Task { await self.drain() }
    }

    private func drain() async {
        while liveEnabled, !queue.isEmpty, !Task.isCancelled {
            let key = queue.removeFirst()
            queued.remove(key)
            _ = await fetchLive(key)
        }
        loop = nil
        // A `want` that arrived while the last fetch was finishing.
        if liveEnabled, !queue.isEmpty { startLoop() }
    }

    /// One live fetch with silent failure. Returns true when the tile is now stored.
    private func fetchLive(_ key: TileKey) async -> Bool {
        guard let client else { return false }
        do {
            let elements = try await client.fetch(key)
            try cache.write(key, elements: elements)
            retryAfter[key] = nil
            attempts[key] = nil
            failed.remove(key)
            for c in listeners.values { c.yield(key) }
            return true
        } catch is CancellationError {
            // The setting was turned off mid-request: no back-off, asked for again when it is on.
            if !queued.contains(key) {
                queue.insert(key, at: 0)
                queued.insert(key)
            }
            return false
        } catch OverpassClientError.coolingDown(let until) {
            retryAfter[key] = until
        } catch OverpassClientError.unavailable(let until) {
            retryAfter[key] = until
        } catch {
            let n = (attempts[key] ?? 0) + 1
            attempts[key] = n
            retryAfter[key] = now().addingTimeInterval(min(600, 30 * pow(2, Double(n - 1))))
        }
        // Silent, and retried later (SPEC 14.2): the tile goes back into the queue after its back-off.
        failed.insert(key)
        scheduleRetry()
        return false
    }

    private func scheduleRetry() {
        guard retryLoop == nil, liveEnabled, client != nil, !failed.isEmpty else { return }
        retryLoop = Task { await self.retryFailed() }
    }

    /// Waits until the earliest back-off of a failed tile ends, then asks for every tile that is due.
    private func retryFailed() async {
        while liveEnabled, !failed.isEmpty, !Task.isCancelled {
            let next = failed.compactMap { retryAfter[$0] }.min() ?? now()
            try? await sleep(max(1, next.timeIntervalSince(now())))
            let t = now()
            let due = failed.filter { (retryAfter[$0] ?? .distantPast) <= t }
            guard !due.isEmpty else { continue }
            failed.subtract(due)
            want(Array(due))
        }
        retryLoop = nil
        if !failed.isEmpty { scheduleRetry() }
    }

    // MARK: For a radius (SPEC 18.4)

    /// Loads the tiles among `keys` that only Overpass can give, at most `limit`, nearest first,
    /// one at a time through the same client. Returns how many were loaded and how many failed or
    /// were left over.
    func loadMissing(_ keys: [TileKey], limit: Int,
                     progress: (@Sendable (_ done: Int, _ of: Int) -> Void)? = nil) async -> (loaded: Int, missing: Int) {
        let needed = keys.filter { needsLive($0) }
        guard liveEnabled, client != nil else { return (0, needed.count) }
        var loaded = 0
        let batch = Array(needed.prefix(limit))
        progress?(0, batch.count)
        for (k, key) in batch.enumerated() {
            if Task.isCancelled { break }
            if await fetchLive(key) { loaded += 1 }
            progress?(k + 1, batch.count)
        }
        return (loaded, needed.count - loaded)
    }

    // MARK: Gebiet vorladen

    /// Loads every tile within `radius` meters (default 15 km) of a point, nearest first, through
    /// the same client (one request at a time, spacing and backoff). Cancel the calling task to stop.
    func preload(lat: Double, lon: Double, radius: Double = 15_000,
                 progress: @Sendable (Int, Int) -> Void) async -> PreloadResult {
        let keys = TileKey.within(radius: radius, ofLat: lat, lon: lon)
        var available = 0
        var failed = 0
        for (k, key) in keys.enumerated() {
            if Task.isCancelled {
                return PreloadResult(total: keys.count, available: available, failed: failed, cancelled: true)
            }
            if !needsLive(key) {
                available += 1
            } else if liveEnabled, client != nil {
                // Waits for a cool-down instead of skipping, so a busy server only slows the preload.
                var ok = await fetchLive(key)
                if !ok, liveEnabled, !Task.isCancelled, let until = retryAfter[key], until > now() {
                    try? await Task.sleep(for: .seconds(min(120, until.timeIntervalSince(now()))))
                    // The setting may have been turned off (or the preload cancelled) while waiting.
                    if liveEnabled, !Task.isCancelled {
                        retryAfter[key] = nil
                        ok = await fetchLive(key)
                    }
                }
                if ok { available += 1 } else { failed += 1 }
            } else {
                failed += 1
            }
            progress(k + 1, keys.count)
        }
        return PreloadResult(total: keys.count, available: available, failed: failed, cancelled: Task.isCancelled)
    }

    /// "Straßendaten-Cache leeren".
    func clearCache() {
        cache.clear()
        retryAfter = [:]
        attempts = [:]
    }
}
