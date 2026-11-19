import Foundation

/// File layout of all trips: `Application Support/Spur/Trips/<tripId>/`.
///
/// - `trip.json`: `TripRecord` (metadata and cached statistics), schema versioned
/// - `fixes.jsonl`: raw fixes, append only (`FixFile`)
/// - `events.json`: markers
/// - `thumb.png`: cached map snapshot for the history list
///
/// Every file and folder uses `completeUntilFirstUserAuthentication`, so writes keep working
/// while the phone is locked during a trip.
nonisolated final class TripStore: @unchecked Sendable {
    static let tripFile = "trip.json"
    static let eventsFile = "events.json"
    static let thumbFile = "thumb.png"
    /// The light map's thumbnail (SPEC 18.1); `thumb.png` stays the dark one.
    static let thumbLightFile = "thumb-light.png"
    /// Road details of version 1.1 (passed features, way per fix), see `RoadDetails`.
    static let roadsFile = "roads.json"
    /// Driven edges and directions of version 1.2 (SPEC 15), see `TripCoverage`. Written by every
    /// road analysis, also when empty.
    static let coverageFile = "coverage.json"
    /// Decisions on suggested routes across gaps (SPEC 18.8); the raw files stay untouched.
    static let gapFillsFile = "gap-fills.json"

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// The app's store in Application Support.
    static func appDefault() -> TripStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TripStore(root: base.appendingPathComponent("Spur/Trips", isDirectory: true))
    }

    static var protection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    func ensureRoot() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: TripStore.protection)
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func tripURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(TripStore.tripFile) }
    func fixesURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(FixFile.fileName) }
    func eventsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(TripStore.eventsFile) }
    func thumbURL(_ id: UUID, light: Bool = false) -> URL {
        folder(id).appendingPathComponent(light ? TripStore.thumbLightFile : TripStore.thumbFile)
    }
    func roadsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(TripStore.roadsFile) }

    // MARK: Coding

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Num.iso(date))
        }
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    // MARK: Trips

    /// Creates the folder, `trip.json` and an empty fix file with its header.
    func create(_ record: TripRecord) throws {
        try ensureRoot()
        try fm.createDirectory(at: folder(record.id), withIntermediateDirectories: true, attributes: TripStore.protection)
        try save(record)
        if !fm.fileExists(atPath: fixesURL(record.id).path) {
            fm.createFile(atPath: fixesURL(record.id).path, contents: Data(FixFile.header.utf8), attributes: TripStore.protection)
        }
    }

    /// Atomically rewrites `trip.json`.
    func save(_ record: TripRecord) throws {
        let data = try TripStore.encoder().encode(record)
        try data.write(to: tripURL(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Loads the newest `trip.json`, applies `change` and saves it. Returns the saved record.
    @discardableResult
    func update(_ id: UUID, _ change: (inout TripRecord) -> Void) throws -> TripRecord {
        var record = try load(id)
        change(&record)
        try save(record)
        return record
    }

    func load(_ id: UUID) throws -> TripRecord {
        try TripStore.decoder().decode(TripRecord.self, from: Data(contentsOf: tripURL(id)))
    }

    /// Rebuilds the trip index from the folders: reads only each `trip.json`. Newest first.
    /// Folders without a readable `trip.json` are skipped.
    func index() -> [TripRecord] {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = TripStore.decoder()
        var out: [TripRecord] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            guard let data = try? Data(contentsOf: tripURL(id)),
                  let record = try? decoder.decode(TripRecord.self, from: data) else { continue }
            out.append(record)
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    func loadFixes(_ id: UUID) -> FixFile.Contents {
        guard let data = try? Data(contentsOf: fixesURL(id)) else { return FixFile.Contents() }
        return FixFile.parse(data)
    }

    func openWriter(_ id: UUID) throws -> FixFileWriter {
        try FixFileWriter(url: fixesURL(id))
    }

    func loadEvents(_ id: UUID) -> [TripEvent] {
        guard let data = try? Data(contentsOf: eventsURL(id)) else { return [] }
        return (try? TripStore.decoder().decode([TripEvent].self, from: data)) ?? []
    }

    func saveEvents(_ events: [TripEvent], for id: UUID) throws {
        let data = try TripStore.encoder().encode(events)
        try data.write(to: eventsURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadRoadDetails(_ id: UUID) -> RoadDetails? {
        guard let data = try? Data(contentsOf: roadsURL(id)) else { return nil }
        return try? JSONDecoder().decode(RoadDetails.self, from: data)
    }

    func saveRoadDetails(_ details: RoadDetails, for id: UUID) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(details).write(to: roadsURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func coverageURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(TripStore.coverageFile) }

    func hasCoverage(_ id: UUID) -> Bool { fm.fileExists(atPath: coverageURL(id).path) }

    /// Raw motion samples (SPEC 16.3.1, `docs/MOTION-FORMAT.md`).
    func motionURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(MotionFile.fileName) }
    /// The full motion analysis (events, stretches, chart series).
    func motionAnalysisURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("motion-analysis.json") }

    func hasMotion(_ id: UUID) -> Bool { fm.fileExists(atPath: motionURL(id).path) }

    /// Bytes used by every trip's `motion.bin`.
    func motionBytes() -> Int64 {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            total += Int64((try? motionURL(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func loadMotionDetails(_ id: UUID) -> MotionDetails? {
        guard let data = try? Data(contentsOf: motionAnalysisURL(id)) else { return nil }
        return try? JSONDecoder().decode(MotionDetails.self, from: data)
    }

    func saveMotionDetails(_ details: MotionDetails, for id: UUID) throws {
        try JSONEncoder().encode(details).write(to: motionAnalysisURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadCoverage(_ id: UUID) -> TripCoverage? {
        guard let data = try? Data(contentsOf: coverageURL(id)) else { return nil }
        return try? JSONDecoder().decode(TripCoverage.self, from: data)
    }

    func saveCoverage(_ coverage: TripCoverage, for id: UUID) throws {
        try JSONEncoder().encode(coverage).write(to: coverageURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func gapFillsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(TripStore.gapFillsFile) }

    func loadGapFills(_ id: UUID) -> GapFillFile {
        guard let data = try? Data(contentsOf: gapFillsURL(id)), let f = try? JSONDecoder().decode(GapFillFile.self, from: data) else { return GapFillFile() }
        return f
    }

    func saveGapFills(_ file: GapFillFile, for id: UUID) throws {
        try JSONEncoder().encode(file).write(to: gapFillsURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete(_ id: UUID) throws {
        try fm.removeItem(at: folder(id))
    }

    func deleteAll() throws {
        guard fm.fileExists(atPath: root.path) else { return }
        for name in try fm.contentsOfDirectory(atPath: root.path) where UUID(uuidString: name) != nil {
            try fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Bytes used by all trips.
    func bytesUsed() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
