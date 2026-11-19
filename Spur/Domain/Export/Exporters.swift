import Foundation

/// Everything an exporter needs about one trip. Pure input, no I/O.
nonisolated struct TripExportInput: Sendable {
    var record: TripRecord
    var fixes: [Fix]
    var events: [TripEvent]
    var analysis: TripAnalysis
    /// Road details of version 1.1 (`roads.json`), nil before the trip was analyzed.
    var roads: RoadDetails?
    /// Motion analysis of version 1.2 (`motion-analysis.json`), nil without motion data.
    var motion: MotionDetails?
    /// Accepted routes across gaps (SPEC 18.8): exported apart from the raw track.
    var fills: [GapFill] = []

    init(record: TripRecord, fixes: [Fix], events: [TripEvent], config: StatsConfig = .default, roads: RoadDetails? = nil,
         motion: MotionDetails? = nil) {
        self.record = record
        self.fixes = fixes
        self.events = events
        self.motion = record.motion == nil ? nil : motion
        // Way per fix only when it was computed for exactly these fixes.
        self.roads = roads.flatMap { $0.fixWays.count == fixes.count ? $0 : nil }
        self.analysis = TripAnalyzer.analyze(
            fixes: fixes, recordedGaps: record.gaps, places: record.places, config: config
        )
    }

    var statistics: TripStatistics { analysis.statistics }

    /// Finished pauses with the position where each began (the last fix before it), SPEC 18.9.
    var pauseMarks: [(pause: TripPause, at: Fix)] {
        guard let first = fixes.first else { return [] }
        return (record.pauses ?? []).filter { $0.end != nil }.sorted { $0.start < $1.start }.map { p in
            let ms = Int64((p.start.timeIntervalSince1970 * 1000).rounded())
            return (p, fixes.last { $0.timestampMs <= ms } ?? first)
        }
    }

    /// Motion events with a position, in time order (version 1.2).
    var motionEvents: [MotionEvent] {
        (motion?.events ?? []).filter { $0.latitude != nil && $0.longitude != nil }.sorted { $0.peakTime < $1.peakTime }
    }

    /// Title for files and documents.
    var title: String {
        record.customTitle ?? record.placeTitle ?? "Fahrt \(Num.iso(record.startedAt))"
    }

    /// File name stem, ASCII only: `spur-2026-11-11T081502Z`.
    var fileStem: String {
        let iso = Num.iso(record.startedAt)
        let compact = iso.prefix(19).replacingOccurrences(of: ":", with: "") + "Z"
        return "spur-\(compact)"
    }
}

/// CSV of fixes (SPEC section 9), compatible with the parent import.
nonisolated enum CSVExporter {
    static let header = "timestamp,lat,lon,accuracy,speed,heading,altitude,"
        + "altitudeAccuracy,ellipsoidalAltitude,speedAccuracy,headingAccuracy,simulated,accessory,segment,roadType"
        // Version 1.1 (SPEC 14.7), trailing so the parent import, which ignores unknown columns, is unaffected.
        + ",wayId,street,osmCategory"

    static func export(_ input: TripExportInput) -> String {
        let track = input.analysis.track
        let classes = input.analysis.roadClassPerFix
        var out = header + "\n"
        out.reserveCapacity(input.fixes.count * 140)
        for (i, f) in input.fixes.enumerated() {
            var row: [String] = []
            row.reserveCapacity(15)
            row.append(Num.iso(ms: f.timestampMs))
            row.append(Num.plain(f.latitude))
            row.append(Num.plain(f.longitude))
            row.append(Num.csv(f.horizontalAccuracy))
            row.append(Num.csv(f.speed))
            row.append(Num.csv(f.course))
            row.append(Num.csv(f.altitude))
            row.append(Num.csv(f.verticalAccuracy))
            row.append(Num.csv(f.ellipsoidalAltitude))
            row.append(Num.csv(f.speedAccuracy))
            row.append(Num.csv(f.courseAccuracy))
            row.append(f.isSimulatedBySoftware.map { $0 ? "true" : "false" } ?? "")
            row.append(f.isProducedByAccessory.map { $0 ? "true" : "false" } ?? "")
            row.append(String(track.segmentOf[i]))
            row.append(classes[i]?.label ?? "")
            if let (wayId, way) = input.roads?.way(forFix: i) {
                row.append(String(wayId))
                row.append(field(way.street))
                row.append(way.category?.rawValue ?? "")
            } else {
                row.append(contentsOf: ["", "", ""])
            }
            out += row.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    /// RFC 4180 field: quoted when it holds a comma, quote or line break. Free text (street names
    /// from OpenStreetMap, place names, titles, notes) that starts like a spreadsheet formula
    /// (`=`, `+`, `-`, `@`, tab, carriage return) gets a leading apostrophe, so a spreadsheet shows
    /// it as text and never evaluates it. Numbers never pass through here.
    static func field(_ value: String?) -> String {
        guard var s = value else { return "" }
        if let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { s = "'" + s }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

/// GPX 1.1 (SPEC section 9): one `trk`, one `trkseg` per gap-separated segment, markers as `wpt`.
/// Speed, course and accuracies sit in a namespaced `extensions` block whose local names
/// (`speed`, `course`, `accuracy`) the parent importer reads.
nonisolated enum GPXExporter {
    static let namespace = "urn:spur:gpx:1"

    static func export(_ input: TripExportInput) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"Spur\" xmlns=\"http://www.topografix.com/GPX/1/1\""
        out += " xmlns:spur=\"\(namespace)\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        out += "  <metadata>\n"
        out += "    <name>\(escape(input.title))</name>\n"
        if let note = input.record.note, !note.isEmpty { out += "    <desc>\(escape(note))</desc>\n" }
        out += "    <time>\(Num.iso(input.record.startedAt))</time>\n"
        out += "  </metadata>\n"
        for e in input.events.sorted(by: { $0.timestampMs < $1.timestampMs }) {
            out += "  <wpt lat=\"\(Num.plain(e.latitude))\" lon=\"\(Num.plain(e.longitude))\">\n"
            if let ele = e.altitude { out += "    <ele>\(Num.plain(ele))</ele>\n" }
            out += "    <time>\(Num.iso(ms: e.timestampMs))</time>\n"
            out += "    <name>\(escape(e.tag.label))</name>\n"
            if let note = e.note, !note.isEmpty { out += "    <desc>\(escape(note))</desc>\n" }
            out += "    <type>\(escape(e.tag.rawValue))</type>\n"
            out += "  </wpt>\n"
        }
        // Version 1.2: motion events as waypoints, typed `motion.<kind>`.
        for e in input.motionEvents {
            out += "  <wpt lat=\"\(Num.plain(e.latitude!))\" lon=\"\(Num.plain(e.longitude!))\">\n"
            out += "    <time>\(Num.iso(ms: MotionEvent.ms(e.peakTime)))</time>\n"
            out += "    <name>\(escape(e.kind.label))</name>\n"
            out += "    <desc>\(Num.fixed(e.peak, 2)) m/s²</desc>\n"
            out += "    <type>\(e.kind.exportType)</type>\n"
            out += "  </wpt>\n"
        }
        // SPEC 18.9: each pause as a waypoint where it began, typed `pause.manual` or `pause.auto`.
        for (p, f) in input.pauseMarks {
            out += "  <wpt lat=\"\(Num.plain(f.latitude))\" lon=\"\(Num.plain(f.longitude))\">\n"
            out += "    <time>\(Num.iso(p.start))</time>\n"
            out += "    <name>Pause</name>\n"
            out += "    <desc>\(Num.iso(p.start)) bis \(Num.iso(p.end!))\(p.evidence.map { ", \(escape($0))" } ?? "")</desc>\n"
            out += "    <type>pause.\(p.kind.rawValue)</type>\n"
            out += "  </wpt>\n"
        }
        out += "  <trk>\n"
        out += "    <name>\(escape(input.title))</name>\n"
        for segment in input.analysis.track.segments {
            out += "    <trkseg>\n"
            for i in segment {
                let f = input.fixes[i]
                out += "      <trkpt lat=\"\(Num.plain(f.latitude))\" lon=\"\(Num.plain(f.longitude))\">"
                if let ele = f.altitude { out += "<ele>\(Num.plain(ele))</ele>" }
                out += "<time>\(Num.iso(ms: f.timestampMs))</time>"
                var ext = ""
                if let v = f.speed { ext += "<spur:speed>\(Num.plain(v))</spur:speed>" }
                if let v = f.course { ext += "<spur:course>\(Num.plain(v))</spur:course>" }
                if let v = f.horizontalAccuracy { ext += "<spur:accuracy>\(Num.plain(v))</spur:accuracy>" }
                if let v = f.verticalAccuracy { ext += "<spur:altitudeAccuracy>\(Num.plain(v))</spur:altitudeAccuracy>" }
                if let v = f.speedAccuracy { ext += "<spur:speedAccuracy>\(Num.plain(v))</spur:speedAccuracy>" }
                if let v = f.courseAccuracy { ext += "<spur:courseAccuracy>\(Num.plain(v))</spur:courseAccuracy>" }
                if let v = f.ellipsoidalAltitude {
                    ext += "<spur:ellipsoidalAltitude>\(Num.plain(v))</spur:ellipsoidalAltitude>"
                }
                if f.isSimulatedBySoftware == true { ext += "<spur:simulated>true</spur:simulated>" }
                if f.isProducedByAccessory == true { ext += "<spur:accessory>true</spur:accessory>" }
                if !ext.isEmpty { out += "<extensions>\(ext)</extensions>" }
                out += "</trkpt>\n"
            }
            out += "    </trkseg>\n"
        }
        out += "  </trk>\n"
        // SPEC 18.8: accepted gap fills as routes (`rte`), never as track points: readers such as
        // the parent take every `trkpt` as a recorded fix and would invent times for these.
        for fill in input.fills where fill.status == .accepted && fill.coords.count >= 2 {
            out += "  <rte>\n    <name>Ergänzt (Lücke)</name>\n    <type>gapFill</type>\n"
            for p in fill.coords { out += String(format: "    <rtept lat=\"%.7f\" lon=\"%.7f\"></rtept>\n", p.lat, p.lon) }
            out += "  </rte>\n"
        }
        out += "</gpx>\n"
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 forbids most control characters; drop them.
                if u.value < 0x20 && u != "\n" && u != "\t" && u != "\r" { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// GeoJSON (SPEC section 9): a FeatureCollection with one LineString per segment and one Point
/// per marker. A segment of a single fix becomes a Point (a LineString needs two positions,
/// RFC 7946 3.1.4). Positions are `[lon, lat]` or `[lon, lat, h]` with h the height above the
/// WGS 84 ellipsoid (RFC 7946 section 4), so mean sea level altitude is never used there.
nonisolated enum GeoJSONExporter {
    static func export(_ input: TripExportInput) -> String {
        var features: [JSONValue] = []
        let fixes = input.fixes
        for (k, segment) in input.analysis.track.segments.enumerated() {
            let coords: [JSONValue] = segment.map { i in position(fixes[i].longitude, fixes[i].latitude, fixes[i].ellipsoidalAltitude) }
            let geometry: JSONValue = segment.count >= 2
                ? .object([("type", .string("LineString")), ("coordinates", .array(coords))])
                : .object([("type", .string("Point")), ("coordinates", coords[0])])
            var props = tripProperties(input)
            props.append(("segment", .int(Int64(k))))
            props.append(("segmentStart", .string(Num.iso(ms: fixes[segment.lowerBound].timestampMs))))
            props.append(("segmentEnd", .string(Num.iso(ms: fixes[segment.upperBound - 1].timestampMs))))
            props.append(("fixCount", .int(Int64(segment.count))))
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", geometry),
                ("properties", .object(props)),
            ]))
        }
        // Version 1.1: one Point per passed road feature (OpenStreetMap, ODbL).
        for f in input.roads?.passed ?? [] {
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", .object([("type", .string("Point")), ("coordinates", position(f.lon, f.lat, nil))])),
                ("properties", .object([
                    ("kind", .string("roadFeature")),
                    ("type", .string(f.type.rawValue)),
                    ("nodeId", .int(f.nodeId)),
                    ("siteId", f.siteId.map { .int($0) } ?? .null),
                    ("time", .string(Num.iso(ms: f.timeMs))),
                    ("wayId", .int(f.wayId)),
                    ("street", .string(f.street)),
                    ("applies", .bool(f.applies)),
                    ("skewed", f.skewed.map { .bool($0) } ?? .null),
                    ("allWay", f.allWay.map { .bool($0) } ?? .null),
                ])),
            ]))
        }
        for e in input.events.sorted(by: { $0.timestampMs < $1.timestampMs }) {
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", .object([
                    ("type", .string("Point")),
                    ("coordinates", position(e.longitude, e.latitude, e.ellipsoidalAltitude)),
                ])),
                ("properties", .object([
                    ("kind", .string("event")),
                    ("tripId", .string(input.record.id.uuidString)),
                    ("time", .string(Num.iso(ms: e.timestampMs))),
                    ("tag", .string(e.tag.rawValue)),
                    ("label", .string(e.tag.label)),
                    ("note", .str(e.note)),
                ])),
            ]))
        }
        // Version 1.2: one Point per motion event.
        for e in input.motionEvents {
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", .object([("type", .string("Point")), ("coordinates", position(e.longitude!, e.latitude!, nil))])),
                ("properties", .object([
                    ("kind", .string("motionEvent")),
                    ("tripId", .string(input.record.id.uuidString)),
                    ("type", .string(e.kind.exportType)),
                    ("label", .string(e.kind.label)),
                    ("time", .string(Num.iso(ms: MotionEvent.ms(e.peakTime)))),
                    ("start", .string(Num.iso(ms: MotionEvent.ms(e.start)))),
                    ("end", .string(Num.iso(ms: MotionEvent.ms(e.end)))),
                    ("peakMps2", .number((e.peak * 1000).rounded() / 1000)),
                    ("speedMps", .num(e.speed)),
                    ("street", .str(e.street)),
                ])),
            ]))
        }
        // SPEC 18.9: one Point per pause where it began, with its span.
        for (p, f) in input.pauseMarks {
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", .object([("type", .string("Point")), ("coordinates", .array([.number(f.longitude), .number(f.latitude)]))])),
                ("properties", .object([
                    ("kind", .string("pause")),
                    ("tripId", .string(input.record.id.uuidString)),
                    ("pauseKind", .string(p.kind.rawValue)),
                    ("start", .string(Num.iso(p.start))),
                    ("end", .string(Num.iso(p.end!))),
                    ("durationS", .number(p.end!.timeIntervalSince(p.start).rounded())),
                    ("evidence", .str(p.evidence)),
                ])),
            ]))
        }
        // SPEC 18.8: accepted gap fills as separate features, `filled: true`.
        for fill in input.fills where fill.status == .accepted && fill.coords.count >= 2 {
            features.append(.object([
                ("type", .string("Feature")),
                ("geometry", .object([("type", .string("LineString")),
                                      ("coordinates", .array(fill.coords.map { .array([.number($0.lon), .number($0.lat)]) }))])),
                ("properties", .object([
                    ("kind", .string("gapFill")),
                    ("filled", .bool(true)),
                    ("tripId", .string(input.record.id.uuidString)),
                    ("start", .string(Num.iso(ms: fill.startMs))),
                    ("end", .string(Num.iso(ms: fill.endMs))),
                    ("lengthM", .number((fill.lengthM * 10).rounded() / 10)),
                ])),
            ]))
        }
        return JSONValue.object([("type", .string("FeatureCollection")), ("features", .array(features))]).serialized() + "\n"
    }

    static func position(_ lon: Double, _ lat: Double, _ ele: Double?) -> JSONValue {
        var p: [JSONValue] = [.number(lon), .number(lat)]
        if let ele { p.append(.number(ele)) }
        return .array(p)
    }

    static func tripProperties(_ input: TripExportInput) -> [(String, JSONValue)] {
        let r = input.record
        let s = input.statistics
        return [
            ("kind", .string("track")),
            ("tripId", .string(r.id.uuidString)),
            ("title", .string(input.title)),
            ("start", .string(Num.iso(r.startedAt))),
            ("end", .str(r.endedAt.map(Num.iso))),
            ("driver", .str(r.context.driverName)),
            ("vehicle", .str(r.context.vehicleName)),
            ("distanceMeters", .number(s.distance)),
            ("durationSeconds", .number(s.time.totalDuration)),
            ("movingSeconds", .number(s.time.movingTime)),
            ("averageSpeedMps", .num(s.speed.average)),
            ("maxSpeedMps", .num(s.speed.max)),
            ("stadtMeters", .number(s.roadType.stadt.distance)),
            ("landMeters", .number(s.roadType.land.distance)),
            ("autobahnMeters", .number(s.roadType.autobahn.distance)),
            ("roadTypeEstimated", .bool(true)),
        ]
    }
}

/// JSON (SPEC section 9): the full `trip.json` plus freshly computed statistics, gaps and events.
nonisolated enum JSONExporter {
    struct Document: Encodable {
        var format = "spur-trip"
        var version = 1
        var trip: TripRecord
        var statistics: TripStatistics
        var gaps: [Gap]
        var events: [TripEvent]
        /// Version 1.1: the road statistics and every passed feature (OpenStreetMap, ODbL).
        var roads: RoadStatistics?
        var passedFeatures: [Passed]?
        var roadDataAttribution: String?
        /// Version 1.2: the motion events (the summary is `trip.motion`).
        var motionEvents: [MotionEventExport]?
    }

    struct Passed: Encodable {
        var nodeId: Int64
        var type: String
        var siteId: Int64?
        var time: String
        var lat: Double
        var lon: Double
        var wayId: Int64
        var street: String
        var applies: Bool
        var allWay: Bool?
        var skewed: Bool?
    }

    static func export(_ input: TripExportInput) throws -> Data {
        var doc = Document(trip: input.record, statistics: input.statistics, gaps: input.analysis.gaps, events: input.events)
        if let roads = input.record.roads {
            doc.roads = roads
            doc.passedFeatures = (input.roads?.passed ?? []).map {
                Passed(nodeId: $0.nodeId, type: $0.type.rawValue, siteId: $0.siteId, time: Num.iso(ms: $0.timeMs), lat: $0.lat, lon: $0.lon,
                       wayId: $0.wayId, street: $0.street, applies: $0.applies, allWay: $0.allWay, skewed: $0.skewed)
            }
            doc.roadDataAttribution = "Road data (c) OpenStreetMap contributors, ODbL"
        }
        if input.record.motion != nil {
            doc.motionEvents = (input.motion?.events ?? []).sorted { $0.peakTime < $1.peakTime }.map(MotionEventExport.init)
        }
        return try TripStore.encoder().encode(doc)
    }
}

/// `trips.csv` in the all-trips ZIP: one summary row per trip.
nonisolated enum TripsSummaryCSV {
    static let header = "id,title,start,end,distance_m,duration_s,moving_s,average_speed_mps,max_speed_mps,"
        + "stadt_m,land_m,autobahn_m,stops,fixes,gaps,start_place,end_place,driver,vehicle,note"
        // Version 1.1 (SPEC 14.7): road counts from OpenStreetMap, empty before a trip is analyzed.
        + ",signal_sites,stop_signs,all_way_stops,skewed_junctions,stops_at_signal,stops_at_stop_sign,road_coverage"
        // Version 1.2 (SPEC 16.3.4): the motion summary, empty without motion data.
        + MotionSummaryColumns.header

    static func export(_ rows: [(record: TripRecord, statistics: TripStatistics)]) -> String {
        var out = header + "\n"
        for (r, s) in rows {
            let fields: [String] = [
                r.id.uuidString,
                CSVExporter.field(r.customTitle ?? r.placeTitle),
                Num.iso(r.startedAt),
                r.endedAt.map(Num.iso) ?? "",
                Num.fixed(s.distance, 1),
                Num.fixed(s.time.totalDuration, 3),
                Num.fixed(s.time.movingTime, 3),
                s.speed.average.map { Num.fixed($0, 3) } ?? "",
                s.speed.max.map { Num.fixed($0, 3) } ?? "",
                Num.fixed(s.roadType.stadt.distance, 1),
                Num.fixed(s.roadType.land.distance, 1),
                Num.fixed(s.roadType.autobahn.distance, 1),
                String(s.stops.count),
                String(s.gps.fixCount),
                String(s.gps.gapCount),
                CSVExporter.field(s.places.startPlace),
                CSVExporter.field(s.places.endPlace),
                CSVExporter.field(r.context.driverName),
                CSVExporter.field(r.context.vehicleName),
                CSVExporter.field(r.note),
            ] + (r.roads.map { roads in
                [String(roads.counts.signalSites), String(roads.counts.stopSigns), String(roads.counts.allWayStops),
                 String(roads.counts.skewedJunctions), String(roads.stops.signal), String(roads.stops.stopSign),
                 roads.coverage.map { Num.fixed($0, 4) } ?? ""]
            } ?? Array(repeating: "", count: 7)) + MotionSummaryColumns.fields(r.motion)
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }
}
