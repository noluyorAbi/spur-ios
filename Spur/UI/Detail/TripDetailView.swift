import Charts
import MapKit
import SwiftUI

/// "Fahrt-Details": map of the whole trip and every statistic with its definition (SPEC 7.3).
struct TripDetailView: View {
    var tripId: UUID
    /// `.panel`: inside the live panel over the live map (no map, no colouring, no actions).
    var style: Style = .standard

    enum Style { case standard, panel }

    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(RoadService.self) private var roads
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TripDetailModel?
    /// Suggested routes across the gaps and the decisions (SPEC 18.8).
    @State private var gaps = GapFillModel()
    @State private var coloring: TripDetailModel.Coloring = .speed
    @State private var showFeatures = true
    @State private var showMotionEvents = true
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var editingNote = false
    @State private var confirmDelete = false
    @State private var exporter = ExportRunner()
    @State private var notFound = false
    @State private var watchingLive = false

    private var units: UnitSystem { settings.units }

    /// The running trip (SPEC 17.8): its details come from the one live model the panel reads.
    private var isLive: Bool { model.live.runningTripId == tripId }
    private var current: TripDetailModel? { isLive ? model.live.detail : detail }

    var body: some View {
        Group {
            if let current {
                content(current)
            } else if notFound {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.Text.tertiary)
                    Text("Fahrt nicht gefunden")
                        .font(Typography.headline)
                        .foregroundStyle(Theme.Text.primary)
                    Text("Sie wurde gelöscht oder enthielt keine Positionen.")
                        .font(Typography.callout)
                        .foregroundStyle(Theme.Text.secondary)
                }
            } else {
                ProgressView().tint(Theme.accentLight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(current?.record.displayTitle ?? "Fahrt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onChange(of: model.trips.first(where: { $0.id == tripId })) { _, fresh in
            // A later save (for example the end place after the geocode, or a road analysis) shows up here.
            guard let fresh, let detail else { return }
            let newAnalysis = fresh.roads?.analyzedAt != detail.record.roads?.analyzedAt
                || fresh.motion?.analyzedAt != detail.record.motion?.analyzedAt
            detail.record = fresh
            if newAnalysis { Task { await detail.loadRoads(store: model.store) } }
        }
        .task(id: tripId) { if !isLive { await load() } }
        .onAppear { if isLive { model.live.viewerAppeared(); watchingLive = true } }
        .onDisappear { if watchingLive { model.live.viewerDisappeared(); watchingLive = false } }
        // The trip stops while it is open: the same screen becomes the finished trip's details.
        .onChange(of: isLive) { _, live in
            guard !live else { return }
            if watchingLive {
                model.live.viewerDisappeared()
                watchingLive = false
            }
            Task { await load() }
        }
        .exportPresentation(exporter)
        .alert("Fahrt umbenennen", isPresented: $renaming) {
            TextField("Titel", text: $newTitle)
            Button("Sichern") { saveTitle() }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(isPresented: $editingNote) {
            if let current {
                NoteEditor(text: current.record.note ?? "") { saveNote($0) }
            }
        }
        .confirmationDialog("Fahrt löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                model.delete(tripId)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Fahrt und alle ihre Positionen werden von diesem iPhone entfernt.")
        }
    }

    private func load() async {
        guard let record = model.trips.first(where: { $0.id == tripId }) ?? (try? model.store.load(tripId)) else {
            notFound = true
            return
        }
        let d = TripDetailModel(record: record)
        detail = d
        await d.load(store: model.store, config: settings.statsConfig, units: units)
        // Trips recorded before version 1.1 get their road data the first time they are opened.
        if record.roads == nil && !record.isRecording { roads.analyze(tripId, first: true) }
        // SPEC 18.8: suggestions for the gaps, after the trip itself is on screen.
        if !record.isRecording && style == .standard {
            await gaps.load(trip: tripId, ends: d.gapEnds, store: model.store, roads: roads)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: Theme.Space.xs) {
                Text(current?.record.displayTitle ?? (notFound ? "" : "Fahrt"))
                    .font(Typography.font(17, relativeTo: .headline))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                // The running trip says it is live (review U5); at Stop the chip goes with the
                // hand-over to the finished trip.
                if isLive, let started = current?.record.startedAt {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.Status.bad).frame(width: 7, height: 7)
                        Text("Läuft · ") + Text(started, style: .timer)
                    }
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Text.primary)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Capsule().fill(Theme.Text.primary.opacity(0.08)))
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detail.running")
                }
            }
            .animation(Theme.Motion.state, value: isLive)
        }
        if current != nil && style == .standard {
            actionsMenu
        }
    }

    @ToolbarContentBuilder private var actionsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // A running trip is not exported (it is not finished) and not deleted (SPEC 17.8).
                if !isLive {
                Section("Teilen") {
                    Button {
                        exporter.exportTrip(tripId, formats: ExportService.Format.allCases, store: model.store, config: settings.statsConfig)
                    } label: { Label("Alle vier Dateien", systemImage: "square.and.arrow.up") }
                    ForEach(ExportService.Format.allCases) { format in
                        Button(format.label) {
                            exporter.exportTrip(tripId, formats: [format], store: model.store, config: settings.statsConfig)
                        }
                    }
                    if current?.record.motion != nil {
                        Button {
                            model.exporter.exportMotionCSV(tripId, store: model.store)
                        } label: {
                            Label("Sensordaten (CSV, etwa \(Format.bytes(ExportService.motionCSVBytes(tripId, store: model.store))))",
                                  systemImage: "waveform.path")
                        }
                        .disabled(model.exporter.busy)
                    }
                }
                }
                Button {
                    newTitle = current?.record.customTitle ?? current?.record.displayTitle ?? ""
                    renaming = true
                } label: { Label("Umbenennen", systemImage: "pencil") }
                Button {
                    editingNote = true
                } label: { Label("Notiz", systemImage: "note.text") }
                if !isLive {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: { Label("Löschen", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .accessibilityLabel("Aktionen")
        }
    }

    /// Read-modify-write of the title only, so data saved meanwhile (the end place) survives.
    private func saveTitle() {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = model.update(trip: tripId, { $0.customTitle = t.isEmpty ? nil : t }) { current?.record = saved }
    }

    private func saveNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = model.update(trip: tripId, { $0.note = t.isEmpty ? nil : t }) { current?.record = saved }
    }

    // MARK: Content

    private func content(_ d: TripDetailModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if style == .standard {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            DetailMap(detail: d, coloring: coloring, units: units, showFeatures: $showFeatures, showMotionEvents: $showMotionEvents,
                                      livePosition: isLive ? d.fixes.last?.coordinate : nil, gapFills: isLive ? [] : gaps.items)
                                .floatsOverMap(settings.mapType)
                                .frame(height: 340)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            if showFeatures && !d.mapFeatures.isEmpty { OSMAttribution().padding(.leading, Theme.Space.xxs) }
                        }
                        .id("karte")
                        Picker("Färbung", selection: $coloring) {
                            ForEach(TripDetailModel.Coloring.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if !isLive && !gaps.items.isEmpty { gapSection(d).id("luecken") }
                    }
                    // The running trip: the sensor live at the top (SPEC 17.2a, b).
                    if isLive && liveMotion {
                        LiveMotionSection(model: model.live.motion, units: units, compact: style == .panel).id("dynamik")
                        LiveRoadSurfaceCard(motion: model.live.motion, units: units).id("fahrbahn")
                    }
                    if let s = d.analysis?.statistics {
                        overview(s, d).id("uebersicht")
                        roadType(s).id("streckenart")
                        if isLive {
                            LiveRoadsCard(roads: roads, street: d.record.places.last?.street).id("strassendaten")
                        } else {
                            RoadsSection(record: d.record, analyzing: roads.analyzing.contains(d.record.id), units: units,
                                         online: settings.roadDataOnline) {
                                roads.analyze(d.record.id, first: true)
                            }
                            .id("strassendaten")
                        }
                        speed(s, d).id("geschwindigkeit")
                        elevation(s, d).id("hoehe")
                        stops(s).id("stopps")
                        // With motion data the sensor sections, else the GPS approximation as before.
                        if isLive {
                            if !liveMotion { dynamics(s).id("dynamik") }
                        } else if let m = d.record.motion {
                            MotionDynamicsSection(summary: m, bands: d.motionBands, events: d.motionDetails?.events ?? [], units: units,
                                                  health: d.record.motionHealth)
                                .id("dynamik")
                            // Nothing aligned: the GPS approximation still gives braking values.
                            if !m.isAligned { dynamics(s) }
                            RoadSurfaceSection(summary: m, details: d.motionDetails, units: units).id("fahrbahn")
                        } else {
                            // SPEC 17.5: why there is no sensor data, then the GPS approximation.
                            section(MotionDynamicsSection.title) {
                                Text(Self.missingMotionReason(d.record, hasFile: model.store.hasMotion(d.record.id),
                                                              analyzing: roads.analyzing.contains(d.record.id)))
                                    .font(Typography.callout)
                                    .foregroundStyle(Theme.Text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("detail.motion.reason")
                            }
                            .id("dynamik")
                            dynamics(s)
                        }
                        dayNight(s).id("tagnacht")
                        gps(s).id("gps")
                        // The cached statistics follow later saves (the end place arrives after
                        // the stop), the load-time analysis does not.
                        places(d.record.statistics ?? s).id("orte")
                        context(d.record).id("geraet")
                        eventsSection(d).id("ereignisse")
                        noteSection(d.record).id("notiz")
                    } else {
                        ProgressView().tint(Theme.accentLight).frame(maxWidth: .infinity)
                    }
                }
                .padding(Theme.Space.m)
            }
            .onChange(of: d.loaded) { _, loaded in
                #if DEBUG
                if loaded, let target = AppEnvironment.detailScroll {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                #endif
            }
        }
    }

    /// Why a finished trip has no sensor section (SPEC 17.5).
    static func missingMotionReason(_ r: TripRecord, hasFile: Bool, analyzing: Bool) -> String {
        if r.motionHealth?.openFailed == true || r.motionStart == .failed {
            return "Keine Sensordaten: die Datei konnte nicht angelegt werden."
        }
        if hasFile {
            if r.motionHealth?.gaveUp == true && !analyzing {
                return "Sensordaten unvollständig: die Aufzeichnung wurde nach wiederholten Speicherfehlern gestoppt. Wird ausgewertet."
            }
            return "Wird ausgewertet."
        }
        if r.motionHealth?.gaveUp == true { return "Keine Sensordaten: die Aufzeichnung wurde nach wiederholten Speicherfehlern gestoppt." }
        switch r.motionStart {
        case .off: return "Bewegungssensor war ausgeschaltet (Einstellungen › Bewegungssensor)."
        case .unavailable: return "Keine Sensordaten: dieses Gerät liefert keinen Bewegungssensor."
        case .recording: return "Keine Sensordaten: die Datei fehlt."
        case .failed: return "Keine Sensordaten: die Datei konnte nicht angelegt werden."
        case nil:
            if Self.before12(r.context.appVersion) { return "Fahrt vor Version 1.2 aufgenommen: damals gab es noch keinen Bewegungssensor." }
            return "Keine Sensordaten. Den Grund zeichnet erst Version 1.3 auf."
        }
    }

    /// "1.1.0" and older, or unknown, is before version 1.2.
    static func before12(_ version: String?) -> Bool {
        guard let v = version else { return true }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        return major < 1 || (major == 1 && (parts.count > 1 ? parts[1] : 0) < 2)
    }

    /// The running trip records motion (else its live sensor sections are left out).
    private var liveMotion: Bool { model.engine.motion.isRecording }

    private func section<Content: View>(_ title: String, info: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: title, info: info)
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: Theme.Space.m) { content() }
    }

    private var limit: String { Num.fixed(detail?.record.usableAccuracyLimit ?? settings.usableAccuracy, 0) }

    /// SPEC 18.8: each gap with its suggestion and the owner's decision.
    private func gapSection(_ d: TripDetailModel) -> some View {
        section("Lücken", info: "Wo GPS fehlte, schlägt Spur den wahrscheinlichen Weg über das Straßennetz vor: legal befahrbar, passend zur verstrichenen Zeit. Übernommen zählt er zur Strecke („davon ergänzt“), zur Abdeckung und zur Häufigkeit, nie zu Geschwindigkeit, Zeiten, Fahrdynamik oder Ereignissen. Die aufgezeichneten Positionen bleiben unverändert.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(gaps.items) { item in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(GapFillModel.text(item)).font(Typography.body).foregroundStyle(Theme.Text.primary)
                            .accessibilityIdentifier("gap.text")
                        if item.fill != nil {
                            switch item.status {
                            case .accepted:
                                HStack {
                                    Label("Ergänzt", systemImage: "checkmark.circle").font(Typography.label).foregroundStyle(Theme.Status.good)
                                    Spacer()
                                    Button("Ergänzung entfernen") { decide { gaps.undo(item, trip: d.record.id, store: model.store) } }
                                        .font(Typography.label).accessibilityIdentifier("gap.undo")
                                }
                            case .rejected:
                                HStack {
                                    Text("Verworfen").font(Typography.label).foregroundStyle(Theme.Text.secondary)
                                    Spacer()
                                    Button("Doch vorschlagen") { decide { gaps.undo(item, trip: d.record.id, store: model.store) } }
                                        .font(Typography.label).accessibilityIdentifier("gap.undo")
                                }
                            case nil:
                                HStack(spacing: Theme.Space.s) {
                                    Button { decide { gaps.accept(item, trip: d.record.id, store: model.store) } } label: {
                                        Text("Übernehmen").font(Typography.label).foregroundStyle(.white)
                                            .frame(maxWidth: .infinity, minHeight: 44).background(Theme.accent, in: Capsule())
                                    }
                                    .buttonStyle(PressableStyle())
                                    .accessibilityIdentifier("gap.accept")
                                    Button { decide { gaps.reject(item, trip: d.record.id, store: model.store) } } label: {
                                        Text("Verwerfen").font(Typography.label).foregroundStyle(Theme.Text.primary)
                                            .frame(maxWidth: .infinity, minHeight: 44).background(Theme.Text.ink(0.08), in: Capsule())
                                    }
                                    .buttonStyle(PressableStyle())
                                    .accessibilityIdentifier("gap.reject")
                                }
                            }
                        }
                    }
                }
                if let bucket = gaps.filledFeatures {
                    Text("Auf ergänzten Strecken: \(bucket) (nicht in den gemessenen Zahlen)")
                        .font(Typography.caption).foregroundStyle(Theme.Text.secondary)
                }
            }
        }
    }

    private func decide(_ change: () -> Void) {
        withAnimation(Theme.Motion.state) { change() }
        model.reloadTrips()
    }

    private func overview(_ s: TripStatistics, _ d: TripDetailModel) -> some View {
        section("Übersicht") {
            grid {
                Metric(label: "Strecke", value: Format.distance(s.distance, units), unit: units.distanceUnit, size: 30,
                       info: "Summe der Großkreisabstände (Haversine) zwischen aufeinanderfolgenden brauchbaren Positionen innerhalb eines Abschnitts, nie über eine Lücke hinweg. Brauchbar heißt: Genauigkeit bekannt und höchstens \(limit) m. Meldet eine Position eine gültige Geschwindigkeit unter 1 m/s, rückt sie nicht vor, so zählt Stillstandsrauschen nicht.")
                Metric(label: "Dauer", value: Format.duration(s.time.totalDuration), size: 30,
                       info: "Von der ersten bis zur letzten Position, Lücken eingeschlossen.")
                Metric(label: "Fahrzeit", value: Format.duration(s.time.movingTime), size: 22,
                       info: "Summe aller Intervalle zwischen zwei Positionen mit mindestens 1 m/s. Die Geschwindigkeit eines Intervalls ist die gemeldete der späteren Position, ohne gültige Meldung Abstand durch Zeit.")
                Metric(label: "Standzeit", value: Format.duration(s.time.stoppedTime), size: 22,
                       info: "Summe aller Intervalle unter 1 m/s.")
                // SPEC 18.9: pauses count in neither driving time nor stop time.
                if !(d.record.pauses ?? []).isEmpty {
                    Metric(label: "Pausenzeit", value: Format.duration(d.record.pauseSeconds()), size: 22,
                           info: "Summe der Pausen dieser Fahrt. In einer Pause wird nichts aufgezeichnet; sie zählt weder zur Fahrzeit noch zur Standzeit, nur zur Dauer.")
                }
                Metric(label: "Start", value: d.record.startedAt.formatted(.dateTime.locale(Format.locale).hour().minute()), size: 22,
                       info: "Zeitpunkt, an dem Start gedrückt wurde.")
                if gaps.acceptedMeters > 0 {
                    Metric(label: "Ergänzt", value: Format.distance(gaps.acceptedMeters, units), unit: units.distanceUnit, size: 22,
                           info: "Übernommene Wege über GPS-Lücken. Sie zählen zur Strecke, nicht zu Geschwindigkeit oder Zeiten: Strecke mit Ergänzung \(Format.distance(s.distance + gaps.acceptedMeters, units)) \(units.distanceUnit), davon ergänzt \(Format.distance(gaps.acceptedMeters, units)) \(units.distanceUnit).")
                        .accessibilityIdentifier("gap.filledMetric")
                }
                Metric(label: "Lücken", value: "\(s.gps.gapCount)", size: 22,
                       info: "Mehr als 5 s zwischen zwei aufeinanderfolgenden Positionen. Statistik und GPX-Abschnitte werden dort getrennt.")
            }
        }
    }

    private func roadType(_ s: TripStatistics) -> some View {
        section("Streckenart (geschätzt)", info: "Offline aus dem Geschwindigkeitsprofil geschätzt, ohne Kartenabgleich: gleitendes Fenster der letzten 60 s, Median der bewegten Positionen. Autobahn ab 85 km/h, Land 50 bis 85 km/h, Stadt unter 50 km/h oder mehr als 2 Stopps je km im Fenster (ab 250 m Fensterstrecke). Eine neue Klasse muss 30 s halten, bevor sie die alte ablöst. Die Straßenkategorien laut OpenStreetMap stehen unter „Kreuzungen und Verkehrszeichen“; diese Schätzung bleibt für Strecken ohne Straßendaten.") {
            RoadShareBar(stats: s.roadType, height: 10)
            VStack(spacing: Theme.Space.s) {
                ForEach(RoadClass.allCases) { c in
                    HStack {
                        Circle().fill(c.color).frame(width: 10, height: 10)
                        Text(c.label).font(Typography.body).foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Text("\(Format.distance(s.roadType[c].distance, units)) \(units.distanceUnit)")
                            .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.primary)
                        Text(Format.duration(s.roadType[c].time))
                            .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                            .frame(width: 84, alignment: .trailing)
                        Text(Format.percent(s.roadType.distanceShare(c)))
                            .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func axisStyle() -> some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel().font(Typography.label).foregroundStyle(Theme.Text.secondary)
        }
    }

    private func timeAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel(format: .dateTime.hour().minute()).font(Typography.label).foregroundStyle(Theme.Text.secondary)
        }
    }

    private func axisTitle(_ text: String) -> some View {
        Text(text).font(Typography.label).foregroundStyle(Theme.Text.secondary)
    }

    private func speed(_ s: TripStatistics, _ d: TripDetailModel) -> some View {
        section("Geschwindigkeit") {
            grid {
                Metric(label: "Ø gesamt", value: Format.speed(s.speed.average, units), unit: units.speedUnit,
                       info: "Strecke geteilt durch Dauer.")
                Metric(label: "Ø Fahrt", value: Format.speed(s.speed.movingAverage, units), unit: units.speedUnit,
                       info: "Strecke geteilt durch Fahrzeit.")
                Metric(label: "Max", value: Format.speed(s.speed.max, units), unit: units.speedUnit,
                       info: "Höchste gemeldete Geschwindigkeit. Nur Positionen mit einer Geschwindigkeitsgenauigkeit von höchstens 2 m/s, wenn bekannt.")
                Metric(label: "p85", value: Format.speed(s.speed.p85, units), unit: units.speedUnit,
                       info: "85. Perzentil (Rangmethode) der gemeldeten Geschwindigkeiten bewegter Positionen (mindestens 1 m/s), gleicher Filter wie Max.")
            }
            if !d.speedSeries.isEmpty {
                Chart(d.speedSeries) { p in
                    LineMark(x: .value("Zeit", p.date), y: .value(units.speedUnit, p.value))
                        .foregroundStyle(Theme.accentLight)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartYAxisLabel { axisTitle(units.speedUnit) }
                .chartXAxis { timeAxis() }
                .chartYAxis { axisStyle() }
                .frame(height: 160)
                .accessibilityLabel("Geschwindigkeit über die Zeit")
            }
            HStack(spacing: 4) {
                Text("Verteilung").eyebrow()
                InfoButton(title: "Verteilung", text: "Fahrzeit je 10 \(units.speedUnit) Klasse, nach der Geschwindigkeit jedes Intervalls.")
            }
            Chart(d.histogram) { bin in
                BarMark(x: .value(units.speedUnit, bin.lower), y: .value("Minuten", bin.seconds / 60), width: .ratio(0.8))
                    .foregroundStyle(Theme.accent)
            }
            .chartXAxisLabel { axisTitle("\(units.speedUnit) (10er-Klassen)") }
            .chartYAxisLabel { axisTitle("min") }
            .chartXAxis { axisStyle() }
            .chartYAxis { axisStyle() }
            .frame(height: 130)
            .accessibilityLabel("Verteilung der Geschwindigkeit")
        }
    }

    private func elevation(_ s: TripStatistics, _ d: TripDetailModel) -> some View {
        section("Höhe", info: "Höhe über dem Meeresspiegel aus Positionen mit gültiger Höhe. Anstieg und Abstieg mit 3 m Hysterese: Schwankungen unter 3 m zählen nicht.") {
            if let e = s.elevation {
                grid {
                    Metric(label: "Min", value: Num.fixed(units.elevation(e.min), 0), unit: units.elevationUnit)
                    Metric(label: "Max", value: Num.fixed(units.elevation(e.max), 0), unit: units.elevationUnit)
                    Metric(label: "Anstieg", value: Num.fixed(units.elevation(e.gain), 0), unit: units.elevationUnit)
                    Metric(label: "Abstieg", value: Num.fixed(units.elevation(e.loss), 0), unit: units.elevationUnit)
                }
                if !d.elevationSeries.isEmpty {
                    let lo = (d.elevationSeries.map(\.value).min() ?? 0) - 5
                    Chart(d.elevationSeries) { p in
                        AreaMark(x: .value("Zeit", p.date), yStart: .value("Basis", lo), yEnd: .value(units.elevationUnit, p.value))
                            .foregroundStyle(LinearGradient(colors: [Theme.accentLight.opacity(0.45), Theme.accentLight.opacity(0.05)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Zeit", p.date), y: .value(units.elevationUnit, p.value))
                            .foregroundStyle(Theme.accentLight)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis { timeAxis() }
                    .chartYAxis { axisStyle() }
                    .frame(height: 130)
                    .accessibilityLabel("Höhenprofil")
                }
            } else {
                Text("Keine gültigen Höhenwerte.").font(Typography.callout).foregroundStyle(Theme.Text.secondary)
            }
        }
    }

    private func stops(_ s: TripStatistics) -> some View {
        section("Stopps", info: "Ein Stopp: Geschwindigkeit unter 1,0 m/s für mindestens 3 s. Start-Stopp: ein Stopp, auf den wieder Fahrt folgt; je km erst ab 100 m Strecke.") {
            grid {
                Metric(label: "Anzahl", value: "\(s.stops.count)")
                Metric(label: "Gesamt", value: Format.duration(s.stops.totalTime))
                Metric(label: "Längster", value: Format.duration(s.stops.longest))
                Metric(label: "Start-Stopp", value: "\(s.stops.startStopEvents)",
                       unit: s.stops.startStopPerKm.map { "\(Format.number($0, digits: 1)) je km" })
            }
        }
    }

    private func dynamics(_ s: TripStatistics) -> some View {
        section("Fahrdynamik (ca.)", info: "Näherung aus zwei aufeinanderfolgenden gültigen Geschwindigkeiten, höchstens 2 s auseinander: a = Δv / Δt. Über +3 m/s² starke Beschleunigung, unter -3 m/s² starkes Bremsen. Eine zusammenhängende Folge zählt als ein Ereignis.") {
            grid {
                Metric(label: "Beschleunigungen", value: "\(s.dynamics.hardAccelerations)", unit: "über 3 m/s²")
                Metric(label: "Bremsungen", value: "\(s.dynamics.hardBrakings)", unit: "über 3 m/s²")
                Metric(label: "Max. Beschleunigung", value: s.dynamics.maxAcceleration.map { Format.number($0, digits: 1) } ?? "-", unit: "m/s²")
                Metric(label: "Max. Verzögerung", value: s.dynamics.maxDeceleration.map { Format.number(-$0, digits: 1) } ?? "-", unit: "m/s²")
            }
        }
    }

    private func dayNight(_ s: TripStatistics) -> some View {
        section("Tag und Nacht", info: "Anteil der Fahrzeit, in der die Sonne höher als -0,833° steht (Sonnenstand nach NOAA, auf dem iPhone berechnet, ohne Internet).") {
            HStack(alignment: .top) {
                Metric(label: "Anteil Tag", value: s.dayNight.dayShare.map { Format.percent($0) } ?? "-", size: 26)
                Spacer()
                Metric(label: "Tag", value: Format.duration(s.dayNight.daySeconds))
                Spacer()
                Metric(label: "Nacht", value: Format.duration(s.dayNight.nightSeconds))
            }
        }
    }

    private func gps(_ s: TripStatistics) -> some View {
        let g = s.gps
        return section("GPS-Qualität", info: "Prozentwerte beziehen sich auf Positionen mit bekannter Genauigkeit. Rate: Positionen je Sekunde ohne Lücken. Simuliert laut Core Location. Externer GNSS-Empfänger: Anteil aller Positionen, die Core Location als von Zubehör erzeugt markiert; ein MFi-Empfänger speist Core Location direkt.") {
            grid {
                Metric(label: "Positionen", value: "\(g.fixCount)")
                Metric(label: "Rate", value: g.meanRateHz.map { Format.number($0, digits: 2) } ?? "-", unit: "Hz")
                Metric(label: "Median", value: g.medianAccuracy.map { Format.number($0, digits: 1) } ?? "-", unit: "m",
                       info: "Median der horizontalen Genauigkeit (horizontalAccuracy) aller Positionen mit bekannter Genauigkeit.")
                Metric(label: "p95", value: g.p95Accuracy.map { Format.number($0, digits: 1) } ?? "-", unit: "m",
                       info: "95. Perzentil (Rangmethode) der horizontalen Genauigkeit aller Positionen mit bekannter Genauigkeit.")
                Metric(label: "Bis 5 m", value: g.percentPrecise.map { Format.percent($0 / 100) } ?? "-")
                Metric(label: "Bis 10 m", value: g.percentWithin10.map { Format.percent($0 / 100) } ?? "-")
                Metric(label: "Über 30 m", value: g.percentAbove30.map { Format.percent($0 / 100) } ?? "-")
                Metric(label: "Lücken", value: "\(g.gapCount)", unit: Format.duration(g.gapTotal))
                Metric(label: "Simuliert", value: "\(g.simulatedCount)")
                if g.accessoryCount > 0, let share = g.accessoryShare {
                    Metric(label: "Externer GNSS-Empfänger", value: Format.percent(share), unit: "\(g.accessoryCount) Pos.")
                }
            }
        }
    }

    private func places(_ s: TripStatistics) -> some View {
        section("Orte und Straßen", info: "Rückwärtssuche mit Apple Karten bei Start, Ende und während der Fahrt höchstens alle 60 s und mindestens 1 km auseinander. Die Strecke zwischen zwei Abfragen zählt zur Straße der ersten, daher ungefähr. Abschaltbar in den Einstellungen.") {
            let p = s.places
            if p.localities.isEmpty && p.streets.isEmpty {
                Text("Keine Orte ermittelt.").font(Typography.callout).foregroundStyle(Theme.Text.secondary)
            } else {
                grid {
                    Metric(label: "Start", value: p.startPlace ?? "-", size: 20)
                    Metric(label: "Ziel", value: p.endPlace ?? "-", size: 20)
                }
                if !p.localities.isEmpty {
                    Text(p.localities.joined(separator: "  ›  "))
                        .font(Typography.callout).foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: Theme.Space.xs) {
                    // Streets credited with less than 20 m (a sample right at the end) are noise here.
                    ForEach(p.streets.filter { $0.distance >= 20 }, id: \.name) { street in
                        HStack {
                            Text(street.name).font(Typography.body).foregroundStyle(Theme.Text.primary).lineLimit(1)
                            Spacer()
                            Text("ca. \(Format.distance(street.distance, units)) \(units.distanceUnit)")
                                .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }
            }
        }
    }

    private func context(_ r: TripRecord) -> some View {
        let c = r.context
        func battery(_ v: Double?) -> String { v.map { Format.percent($0) } ?? "-" }
        let auth = c.authorization == .always ? "Immer" : (c.authorization == .whenInUse ? "Beim Verwenden" : "-")
        let accuracy = c.accuracyAuthorization == .reduced ? "ungenau" : "genau"
        return section("Fahrer und Gerät") {
            grid {
                Metric(label: "Fahrer", value: c.driverName ?? "-", size: 18)
                Metric(label: "Fahrzeug", value: c.vehicleName ?? "-", size: 18)
                Metric(label: "Gerät", value: c.deviceModel ?? "-", size: 18)
                Metric(label: "Systemversion", value: c.systemVersion.map { "iOS \($0)" } ?? "-", size: 18)
                Metric(label: "App", value: "\(c.appVersion ?? "-") (\(c.appBuild ?? "-"))", size: 18)
                Metric(label: "Zeitzone", value: c.timeZoneIdentifier ?? "-", size: 18)
                Metric(label: "Akku", value: "\(battery(c.batteryLevelStart)) › \(battery(c.batteryLevelEnd))", size: 18,
                       info: "Ladestand bei Start und Ende. Stromsparmodus: \(c.lowPowerModeStart == true ? "an" : "aus") › \(c.lowPowerModeEnd == true ? "an" : "aus").")
                Metric(label: "Freigabe", value: "\(auth), \(accuracy)", size: 18)
            }
        }
    }

    private func eventsSection(_ d: TripDetailModel) -> some View {
        section("Ereignisse") {
            if d.events.isEmpty {
                Text("Keine Ereignisse markiert.").font(Typography.callout).foregroundStyle(Theme.Text.secondary)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(d.events.sorted { $0.timestampMs < $1.timestampMs }) { e in
                        HStack(spacing: Theme.Space.s) {
                            EventPin(tag: e.tag)
                            Text(e.tag.label).font(Typography.body).foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Text(e.date.formatted(.dateTime.locale(Format.locale).hour().minute().second()))
                                .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }
            }
        }
    }

    private func noteSection(_ r: TripRecord) -> some View {
        section("Notiz") {
            Button {
                editingNote = true
            } label: {
                Text(r.note ?? "Notiz hinzufügen")
                    .font(Typography.body)
                    .foregroundStyle(r.note == nil ? Theme.accentLight : Theme.Text.primary)
                    .frame(maxWidth: .infinity, minHeight: Theme.touchTarget, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

/// Map of the whole trip with colored track, start, end, event and gap markers.
struct DetailMap: View {
    var detail: TripDetailModel
    var coloring: TripDetailModel.Coloring
    var units: UnitSystem
    @Binding var showFeatures: Bool
    @Binding var showMotionEvents: Bool
    /// The running trip: the car's position instead of the finish flag.
    var livePosition: CLLocationCoordinate2D? = nil
    /// Suggested and accepted routes across gaps (SPEC 18.8), drawn dotted.
    var gapFills: [GapFillModel.Item] = []
    @Environment(Settings.self) private var settings

    private func legendLabel(_ k: Int) -> String {
        TripDetailModel.legendLabels(units)[k]
    }
    @State private var position: MapCameraPosition = .automatic
    /// The motion event whose callout is open.
    @State private var selectedEvent: Int?

    var body: some View {
        let runs = coloring == .speed ? detail.speedRuns : detail.roadRuns
        Map(position: $position) {
            ForEach(Array(detail.gapLines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Theme.Text.ink(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
            }
            // Dots, unlike the solid trail and the dashed planned route: open suggestions in ink,
            // accepted ones in the accent; rejected ones are not drawn.
            ForEach(gapFills.filter { $0.fill != nil && $0.status != .rejected }) { item in
                let line = item.fill!.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                MapPolyline(coordinates: line)
                    .stroke(item.status == .accepted ? Theme.accentLight : Theme.Text.ink(0.8),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [0.1, 7]))
            }
            ForEach(runs) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(runs) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(run.color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            if let first = detail.fixes.first {
                Annotation("Start", coordinate: first.coordinate) {
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
            if let here = livePosition {
                Annotation("Position", coordinate: here) {
                    Circle().fill(Theme.accentLight).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            } else if let last = detail.fixes.last, detail.fixes.count > 1 {
                Annotation("Ziel", coordinate: last.coordinate) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 12))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white))
                }
                .annotationTitles(.hidden)
            }
            ForEach(detail.events) { e in
                Annotation(e.tag.label, coordinate: .init(latitude: e.latitude, longitude: e.longitude)) {
                    EventPin(tag: e.tag)
                }
                .annotationTitles(.hidden)
            }
            if showFeatures {
                ForEach(Array(detail.mapFeatures.enumerated()), id: \.offset) { _, f in
                    if let kind = f.poiKind {
                        Annotation("", coordinate: .init(latitude: f.lat, longitude: f.lon), anchor: .center) {
                            RoadPOIGlyph(kind: kind, size: 18)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            if showMotionEvents {
                ForEach(Array(detail.mapMotionEvents.enumerated()), id: \.offset) { k, e in
                    Annotation(MotionEventGlyph.label(e.kind), coordinate: .init(latitude: e.latitude!, longitude: e.longitude!), anchor: .center) {
                        Button {
                            withAnimation(Theme.Motion.snappy) { selectedEvent = selectedEvent == k ? nil : k }
                        } label: {
                            MotionEventGlyph(kind: e.kind)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .overlay(alignment: .bottom) {
                            if selectedEvent == k {
                                MotionEventCallout(event: e, units: units)
                                    .offset(y: -36)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                            }
                        }
                        .zIndex(selectedEvent == k ? 1 : 0)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(detail.gapMarkers) { m in
                Annotation("Lücke", coordinate: m.coordinate) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.Status.warn))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapType.mapStyle(traffic: false))
        // Keep the framed track and its markers clear of the legend strip at the top.
        .safeAreaPadding(EdgeInsets(top: 64, leading: 20, bottom: 28, trailing: 20))
        .overlay(alignment: .topLeading) { legend.padding(10) }
        .overlay(alignment: .bottom) {
            if !detail.mapFeatures.isEmpty || !detail.mapMotionEvents.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    if !detail.mapMotionEvents.isEmpty {
                        Button {
                            showMotionEvents.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                MotionEventGlyph(kind: .hardBraking, size: 16)
                                Text(showMotionEvents ? "Ereignisse ausblenden" : "Ereignisse")
                                    .font(Typography.label)
                                    .foregroundStyle(Theme.Text.primary)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .glassSurface(radius: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .frame(minHeight: Theme.touchTarget)
                        .accessibilityLabel(showMotionEvents ? "Fahrdynamik-Ereignisse ausblenden" : "Fahrdynamik-Ereignisse einblenden")
                    }
                    Spacer(minLength: 0)
                    if !detail.mapFeatures.isEmpty {
                    Button {
                        showFeatures.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            RoadPOIGlyph(kind: .signal, size: 16)
                            Text(showFeatures ? "Schilder ausblenden" : "Ampeln und Schilder")
                                .font(Typography.label)
                                .foregroundStyle(Theme.Text.primary)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .glassSurface(radius: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .frame(minHeight: Theme.touchTarget)
                    .accessibilityLabel(showFeatures ? "Ampeln und Schilder ausblenden" : "Ampeln und Schilder einblenden")
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .onAppear { if let b = detail.bounds { position = .region(b) } }
        .onChange(of: detail.loaded) { _, _ in if let b = detail.bounds { position = .region(b) } }
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 8) {
            if coloring == .speed {
                let steps = TripDetailModel.speedSteps
                ForEach(Array(steps.enumerated()), id: \.offset) { k, step in
                    VStack(spacing: 2) {
                        Capsule().fill(step.color).frame(width: 22, height: 4)
                        Text(legendLabel(k))
                            .font(Typography.label).foregroundStyle(Theme.Text.secondary)
                    }
                }
                Text(units.speedUnit).font(Typography.label).foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(RoadClass.allCases) { c in
                    HStack(spacing: 4) {
                        Circle().fill(c.color).frame(width: 7, height: 7)
                        Text(c.label).font(Typography.label).foregroundStyle(Theme.Text.primary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(radius: 12)
    }
}

/// Sheet to edit the trip note.
struct NoteEditor: View {
    @State var text: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(Typography.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.m)
                .background(Theme.background)
                .navigationTitle("Notiz")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
