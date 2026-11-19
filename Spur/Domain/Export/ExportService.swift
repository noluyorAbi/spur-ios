import Foundation

/// Writes export files (SPEC section 9). Content comes from the pure exporters; this type only
/// names, writes, zips and copies files.
nonisolated enum ExportService {
    enum Format: String, CaseIterable, Sendable, Identifiable {
        case gpx, csv, geojson, json
        var id: String { rawValue }
        var fileExtension: String { rawValue }
        var label: String {
            switch self {
            case .gpx: "GPX"
            case .csv: "CSV"
            case .geojson: "GeoJSON"
            case .json: "JSON"
            }
        }
    }

    enum ExportError: Error { case tripNotFound, zipFailed }

    /// File name and content of one format for one trip.
    static func file(_ format: Format, for input: TripExportInput, stem: String? = nil) throws -> (name: String, data: Data) {
        let base = stem ?? input.fileStem
        let data: Data
        switch format {
        case .gpx: data = Data(GPXExporter.export(input).utf8)
        case .csv: data = Data(CSVExporter.export(input).utf8)
        case .geojson: data = Data(GeoJSONExporter.export(input).utf8)
        case .json: data = try JSONExporter.export(input)
        }
        return ("\(base).\(format.fileExtension)", data)
    }

    /// The four files of one trip.
    static func files(for input: TripExportInput, stem: String? = nil) throws -> [(name: String, data: Data)] {
        try Format.allCases.map { try file($0, for: input, stem: stem) }
    }

    static func input(for id: UUID, store: TripStore, config: StatsConfig) throws -> TripExportInput {
        guard let record = try? store.load(id) else { throw ExportError.tripNotFound }
        let contents = store.loadFixes(id)
        var r = record
        for g in contents.gaps where !r.gaps.contains(g) { r.gaps.append(g) }
        let effective = StatsConfig(usableAccuracy: record.usableAccuracyLimit ?? config.usableAccuracy)
        var input = TripExportInput(record: r, fixes: contents.fixes, events: store.loadEvents(id), config: effective,
                                    roads: store.loadRoadDetails(id), motion: record.motion == nil ? nil : store.loadMotionDetails(id))
        input.fills = store.loadGapFills(id).accepted
        return input
    }

    /// The bundled description of `motion.bin`, copied into the all-trips ZIP.
    static var motionFormatDoc: URL? { Bundle.main.url(forResource: "MOTION-FORMAT", withExtension: "md") }

    /// A fresh temporary folder for one share. Earlier share folders are removed here, since a
    /// share target may still read them while the sheet is open.
    private static func freshShareDir(_ temp: URL) throws -> URL {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("share-") {
            try? fm.removeItem(at: temp.appendingPathComponent(name))
        }
        let dir = temp.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// "Sensordaten (CSV)" (SPEC 16.3.4): every motion sample at full rate with the vehicle frame,
    /// read from the mapped file (no copy), written into a share folder and hard-linked into
    /// `Documents/Exports`. `progress` gets the share done and returns false to cancel.
    static func exportMotionCSV(
        _ id: UUID, store: TripStore, documents: URL = appDocuments, temp: URL = FileManager.default.temporaryDirectory,
        progress: (Double) -> Bool = { _ in true }
    ) throws -> URL {
        guard let record = try? store.load(id), let source = MappedMotionFile(url: store.motionURL(id), window: record.motionWindow) else {
            throw ExportError.tripNotFound
        }
        let fixes = store.loadFixes(id).fixes
        let stem = TripExportInput(record: record, fixes: [], events: []).fileStem
        let name = "\(stem)-sensordaten.csv"
        let url = try freshShareDir(temp).appendingPathComponent(name)
        try MotionCSVExporter.write(source: source, fixes: fixes, to: url, progress: progress)
        let exports = exportsFolder(documents: documents)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try linkOrCopy(url, to: exports.appendingPathComponent(name))
        return url
    }

    /// The size of a trip's sensor CSV, estimated from its sample count.
    static func motionCSVBytes(_ id: UUID, store: TripStore) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: store.motionURL(id).path)[.size] as? Int) ?? 0
        let rows = max(0, size - MotionFile.headerSize) / MotionFile.recordSize
        return Int64(rows * MotionCSVExporter.bytesPerRow)
    }

    /// A hard link (no second copy on disk), else a copy; an existing file is replaced.
    static func linkOrCopy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.linkItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// The all-trips ZIP's size before it is made: the trips' files plus their raw motion data
    /// (the ZIP compresses, so this is an upper bound).
    static func estimatedAllTripsBytes(store: TripStore) -> Int64 {
        store.bytesUsed()
    }

    /// Bytes in `Documents/Exports`.
    static func exportsBytes(documents: URL = appDocuments) -> Int64 {
        let folder = exportsFolder(documents: documents)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.reduce(Int64(0)) { sum, name in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
        }
    }

    /// `Documents/Exports`, visible in the Files app.
    static func exportsFolder(documents: URL) -> URL {
        documents.appendingPathComponent("Exports", isDirectory: true)
    }

    static var appDocuments: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Writes the chosen formats of one trip into a fresh temporary folder for sharing and copies
    /// them into `Documents/Exports`. Returns the temporary URLs.
    static func exportTrip(
        _ id: UUID, formats: [Format] = Format.allCases, store: TripStore, config: StatsConfig,
        documents: URL = appDocuments, temp: URL = FileManager.default.temporaryDirectory
    ) throws -> [URL] {
        let input = try input(for: id, store: store, config: config)
        let fm = FileManager.default
        let shareDir = try freshShareDir(temp)
        let exports = exportsFolder(documents: documents)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        var urls: [URL] = []
        for format in formats {
            let f = try file(format, for: input)
            let url = shareDir.appendingPathComponent(f.name)
            try write(f.data, to: url)
            try write(f.data, to: exports.appendingPathComponent(f.name))
            urls.append(url)
        }
        return urls
    }

    /// "Alle Fahrten exportieren": one ZIP with a folder per trip (its four files, plus `motion.bin`
    /// when the trip has motion data, version 1.2) and `trips.csv` (plus `MOTION-FORMAT.md` when
    /// any trip carries `motion.bin`), zipped by Foundation (`NSFileCoordinator` with `.forUploading`, no dependency).
    /// The ZIP is copied into `Documents/Exports`; that URL is returned.
    static func exportAll(
        store: TripStore, config: StatsConfig, now: Date = Date(),
        documents: URL = appDocuments, temp: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let fm = FileManager.default
        let stamp = Num.iso(now).prefix(19).replacingOccurrences(of: ":", with: "") + "Z"
        let name = "spur-alle-fahrten-\(stamp)"
        let staging = temp.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var rows: [(record: TripRecord, statistics: TripStatistics)] = []
        var usedStems = Set<String>()
        var anyMotion = false
        for record in store.index().filter({ !$0.isRecording }).reversed() {
            let input = try input(for: record.id, store: store, config: config)
            var stem = input.fileStem
            if usedStems.contains(stem) { stem += "-\(record.id.uuidString.prefix(8).lowercased())" }
            usedStems.insert(stem)
            let folder = root.appendingPathComponent(stem, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for f in try files(for: input, stem: stem) {
                try write(f.data, to: folder.appendingPathComponent(f.name))
            }
            if store.hasMotion(record.id) {
                // A hard link: the raw data is not copied into the staging folder.
                try linkOrCopy(store.motionURL(record.id), to: folder.appendingPathComponent(MotionFile.fileName))
                anyMotion = true
            }
            rows.append((input.record, input.statistics))
        }
        try write(Data(TripsSummaryCSV.export(rows).utf8), to: root.appendingPathComponent("trips.csv"))
        if anyMotion, let doc = motionFormatDoc {
            try fm.copyItem(at: doc, to: root.appendingPathComponent("MOTION-FORMAT.md"))
        }

        let exports = exportsFolder(documents: documents)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        let destination = exports.appendingPathComponent("\(name).zip")
        try? fm.removeItem(at: destination)
        // Older all-trips ZIPs are superseded by this one.
        for old in (try? fm.contentsOfDirectory(atPath: exports.path)) ?? [] where old.hasPrefix("spur-alle-fahrten-") && old.hasSuffix(".zip") {
            try? fm.removeItem(at: exports.appendingPathComponent(old))
        }

        var coordinationError: NSError?
        var copyError: Error?
        // The zipped URL is only valid inside the accessor, so it is moved (or copied) out there.
        NSFileCoordinator().coordinate(readingItemAt: root, options: [.forUploading], error: &coordinationError) { zipped in
            do {
                try fm.moveItem(at: zipped, to: destination)
            } catch {
                do { try fm.copyItem(at: zipped, to: destination) } catch { copyError = error }
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard fm.fileExists(atPath: destination.path) else { throw ExportError.zipFailed }
        return destination
    }
}
