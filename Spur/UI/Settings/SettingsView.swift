import CoreLocation
import SwiftUI

/// Tab "Einstellungen" (SPEC section 7.4).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(RecordingEngine.self) private var engine
    @Environment(RoadService.self) private var roads
    @Environment(\.openURL) private var openURL
    @State private var confirmDeleteAll = false
    @State private var bytes: Int64 = 0
    @State private var cacheBytes = 0
    @State private var motionBytes: Int64 = 0
    @State private var exportBytes: Int64 = 0

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Group {
                        LabeledField(label: "Fahrer", placeholder: "Name", text: $settings.driverName)
                        LabeledField(label: "Fahrzeug", placeholder: "Spitzname", text: $settings.vehicleName)
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Fahrer und Fahrzeug")
                } footer: {
                    footer("Wird in jede neue Fahrt und in die Exporte geschrieben.")
                }

                Section {
                    Group {
                        Picker(selection: $settings.units) {
                            ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
                        } label: { rowLabel("Einheiten") }
                        // SPEC 18.1: the whole app, light by day with Automatisch.
                        Picker(selection: $settings.mapStyle) {
                            ForEach(MapStyleChoice.allCases) { Text($0.label).tag($0) }
                        } label: { rowLabel("Kartenstil") }
                        .accessibilityIdentifier("settings.mapStyle")
                        // SPEC 18.2b: Standard, Satellit, Hybrid; Kartenstil only changes Standard.
                        Picker(selection: $settings.mapType) {
                            ForEach(MapTypeChoice.allCases) { Text($0.label).tag($0) }
                        } label: { rowLabel("Kartentyp") }
                        .accessibilityIdentifier("settings.mapType")
                        Toggle(isOn: $settings.showTraffic) { rowLabel("Verkehr auf der Karte") }
                        Toggle(isOn: $settings.keepScreenAwake) { rowLabel("Display während der Fahrt anlassen") }
                        Toggle(isOn: $settings.showLiveActivity) { rowLabel("Live-Aktivität anzeigen") }
                            .onChange(of: settings.showLiveActivity) { model.refreshActivity() }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Anzeige")
                } footer: {
                    footer("Kartenstil Automatisch: hell, solange die Sonne über dem Horizont steht, nachts dunkel. Verkehr zeigt Apples Verkehrslage, wo Daten vorliegen; gefahrene Straßen sind dann lila und magenta statt gelb und grün. Kartentyp Satellit und Hybrid zeigen Luftbilder (ohne Kartenstil, mit dunklen Bedienelementen, gefahrene Straßen ebenfalls lila) und brauchen deutlich mehr mobile Daten.")
                }

                Section {
                    Group {
                        Toggle(isOn: $settings.geocodingEnabled) { rowLabel("Orte und Straßennamen ermitteln") }
                        Stepper(value: $settings.usableAccuracy, in: 5...100, step: 5) {
                            HStack {
                                rowLabel("Genauigkeitsfilter")
                                Spacer()
                                Text("\(Int(settings.usableAccuracy)) m")
                                    .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Aufzeichnung")
                } footer: {
                    footer("Ortsnamen kommen per Rückwärtssuche von Apple Karten. Sind sie und die Straßendaten aus dem Internet aus, verlässt außer Kartenkacheln nichts das iPhone. Der Genauigkeitsfilter gilt nur für Statistik und Anzeige; gespeichert wird jede Position.")
                }

                // SPEC 18.9: the automatic pause, explained, and how to turn it off.
                Section {
                    Group {
                        Toggle(isOn: $settings.autoPause) { rowLabel("Automatisch pausieren") }
                            .accessibilityIdentifier("settings.autoPause")
                        if settings.autoPause {
                            Picker(selection: $settings.autoPauseMinutes) {
                                ForEach([3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                            } label: { rowLabel("Pause ab") }
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Pausen")
                } footer: {
                    footer("Steht das Auto mindestens \(settings.autoPauseMinutes) Minuten abseits der Straße (Parkplatz, Tankstelle) oder an einer Nebenstraße, pausiert Spur die Fahrt ab Beginn des Stopps und setzt sie beim Losfahren von selbst fort. Entschieden wird nur nach dem Standort und den Straßendaten auf dem iPhone. Auf Autobahnen und Hauptstraßen pausiert Spur nie: dort ist ein langer Halt Stau oder Ampel. Ohne Straßendaten zählt jeder lange Halt als Pause. In einer automatischen Pause wird die Position grob weiter aufgezeichnet, der Bewegungssensor ruht. Die Pausenzeit zählt weder zur Fahrzeit noch zur Standzeit. Pause und Fortsetzen von Hand gibt es neben Ereignis; dann wird gar nichts aufgezeichnet.")
                }

                motionSection(record: $settings.recordMotion, rate: $settings.motionRateHz)
                    .id("bewegungssensor")

                roadDataSection(settings: $settings.roadDataOnline)
                    .id("strassendaten")

                Section {
                    Group {
                        HStack {
                            rowLabel("Status")
                            Spacer()
                            Text(permissionText)
                                .font(Typography.body)
                                .foregroundStyle(permissionColor)
                        }
                        Text(permissionExplanation)
                            .font(Typography.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if engine.authorization == .authorizedWhenInUse {
                            Button("„Immer“ erlauben") {
                            // iOS asks only once; afterwards the iOS settings are the way to "Immer".
                            if !engine.requestAlways(), let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                                .font(Typography.body)
                                .foregroundStyle(Theme.accentLight)
                        }
                        Button("iOS-Einstellungen öffnen") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .font(Typography.body)
                        .foregroundStyle(Theme.accentLight)
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Standortzugriff")
                }

                Section {
                    Group {
                        HStack {
                            rowLabel("Belegter Speicher")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                        HStack {
                            rowLabel("Exporte (Ordner Exports)")
                            Spacer()
                            Text(Format.bytes(exportBytes))
                                .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                        HStack {
                            rowLabel("Fahrten")
                            Spacer()
                            Text("\(model.finishedTrips.count)")
                                .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                        ExportAllRow()
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Text("Alle Fahrten löschen").font(Typography.body)
                        }
                        .disabled(model.finishedTrips.isEmpty)
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Daten")
                } footer: {
                    footer("Exporte liegen zusätzlich in der App „Dateien“ unter „Auf meinem iPhone“ › „Spur“ › „Exports“.")
                }

                Section {
                    Group {
                        HStack {
                            rowLabel("Version")
                            Spacer()
                            Text("\(AppEnvironment.appVersion) (\(AppEnvironment.appBuild))")
                                .font(Typography.body).foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    .listRowBackground(Theme.surface)
                } header: {
                    header("Info")
                } footer: {
                    footer("Alle Daten bleiben auf diesem iPhone. Kein Server, kein Konto, keine Analyse.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.defaultMinListRowHeight, Theme.touchTarget)
            .task {
                #if DEBUG
                if let target = AppEnvironment.settingsScroll {
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(target, anchor: .top)
                }
                #endif
            }
            }
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $confirmDeleteAll) {
                DeleteAllSheet { model.deleteAll() }
            }
            .task(id: model.trips.count) {
                bytes = await model.bytesUsed()
                motionBytes = await model.motionBytesUsed()
                exportBytes = await Task.detached { ExportService.exportsBytes() }.value
            }
            .task(id: roads.preload?.finished) { cacheBytes = await roads.cacheBytes() }
        }
    }

    // MARK: Bewegungssensor (SPEC 16.3)

    /// "etwa 22 MB" per hour at 100 Hz, "etwa 11 MB" at 50 Hz (60-byte records).
    static func motionPerHour(_ rateHz: Int) -> String {
        "etwa \(Int((Double(MotionFile.bytesPerHour(rateHz: rateHz)) / 1_000_000).rounded())) MB pro Stunde bei \(rateHz) Hz"
    }

    private func motionSection(record: Binding<Bool>, rate: Binding<Int>) -> some View {
        Section {
            Group {
                Toggle(isOn: record) { rowLabel("Bewegungssensor aufzeichnen") }
                    .onChange(of: record.wrappedValue) { engine.applyMotionSetting() }
                Picker(selection: rate) {
                    Text("100 Hz").tag(100)
                    Text("50 Hz").tag(50)
                } label: { rowLabel("Abtastrate") }
                .disabled(!record.wrappedValue)
                HStack {
                    rowLabel("Belegt durch Sensordaten")
                    Spacer()
                    Text(Format.bytes(motionBytes))
                        .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                }
            }
            .listRowBackground(Theme.surface)
        } header: {
            header("Bewegungssensor")
        } footer: {
            // SPEC 18.10a: what the rate gives, what it costs, and what it cannot fix.
            footer("Beschleunigung und Drehrate des iPhones, roh gespeichert, für Fahrdynamik und Fahrbahn in der Fahrt. Speicher: \(Self.motionPerHour(rate.wrappedValue)). 100 Hz löst Bodenwellen und Schlaglöcher feiner auf (etwa 21 MB pro Stunde); 50 Hz misst Bremsen, Beschleunigen und Kurven genauso gut mit halbem Speicher (etwa 11 MB pro Stunde). Gegen ein bewegtes iPhone hilft keine Abtastrate: nach jedem Ablegen braucht Spur etwa eine Minute mit Anfahren und Bremsen, um die Lage neu zu finden, solange sind die Werte pausiert. Eine feste Halterung hilft. Ausschalten stoppt die Aufzeichnung sofort, Einschalten und die Abtastrate gelten ab der nächsten Fahrt.")
        }
    }

    // MARK: Straßendaten (SPEC 14.6)

    private func roadDataSection(settings online: Binding<Bool>) -> some View {
        Section {
            Group {
                Toggle(isOn: online) { rowLabel("Straßendaten aus dem Internet laden") }
                    .onChange(of: online.wrappedValue) { _, on in roads.setOnline(on) }
                preloadRow
                HStack {
                    rowLabel("Offline-Paket")
                    Spacer()
                    Text(packText)
                        .font(Typography.body)
                        .foregroundStyle(Theme.Text.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    rowLabel("Zwischenspeicher")
                    Spacer()
                    Text(Format.bytes(Int64(cacheBytes)))
                        .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                }
                Button {
                    Task {
                        await roads.clearCache()
                        cacheBytes = await roads.cacheBytes()
                    }
                } label: {
                    Text("Straßendaten-Cache leeren").font(Typography.body)
                }
                .foregroundStyle(Theme.accentLight)
                .disabled(cacheBytes == 0)
                Toggle(isOn: Binding(get: { settings.showRoadFeatures }, set: { settings.showRoadFeatures = $0 })) {
                    rowLabel("Ampeln und Schilder auf der Karte")
                }
                Toggle(isOn: Binding(get: { settings.showSpeedLimit }, set: { settings.showSpeedLimit = $0 })) {
                    rowLabel("Tempolimit anzeigen")
                }
                .accessibilityIdentifier("settings.speedLimit")
            }
            .listRowBackground(Theme.surface)
        } header: {
            header("Straßendaten")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                footer("Ampeln, Stoppschilder und Kreuzungen kommen aus OpenStreetMap: für das Gebiet des Offline-Pakets direkt vom iPhone, anderswo, wenn erlaubt, von öffentlichen Overpass-Servern. Gesendet werden nur die Quadrate von etwa 4 km um die Strecke, nie die Strecke selbst. Vorladen am besten im WLAN. Das Tempolimit neben der Geschwindigkeit ist das der Straße laut OpenStreetMap, nur wenn die Position sicher auf einer Straße liegt; es kann fehlen oder falsch sein.")
                Text(OSMText.attribution).font(Typography.caption).foregroundStyle(Theme.Text.secondary)
            }
        }
    }

    @ViewBuilder private var preloadRow: some View {
        if let p = roads.preload, !p.finished {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    rowLabel("Gebiet vorladen")
                    Spacer()
                    Button("Abbrechen") { roads.cancelPreload() }
                        .font(Typography.body)
                        .foregroundStyle(Theme.accentLight)
                }
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .tint(Theme.accentLight)
                Text("\(p.done) von \(p.total) Kacheln")
                    .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
            }
            .padding(.vertical, Theme.Space.xxs)
        } else {
            Button {
                if let c = engine.lastKnownCoordinate { roads.startPreload(lat: c.latitude, lon: c.longitude) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gebiet vorladen").font(Typography.body)
                    Text(preloadHint)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.accentLight)
            .disabled(engine.lastKnownCoordinate == nil || !settings.roadDataOnline)
        }
    }

    private var preloadHint: String {
        if let p = roads.preload, p.finished {
            return p.failed == 0 ? "Fertig: \(p.total) Kacheln im Umkreis von 15 km verfügbar."
                                 : "Fertig: \(p.total - p.failed) von \(p.total) Kacheln verfügbar, der Rest später."
        }
        if !settings.roadDataOnline { return "Nur mit „Straßendaten aus dem Internet laden“." }
        if engine.lastKnownCoordinate == nil { return "Position unbekannt. Einmal den Tab „Fahrt“ öffnen." }
        return "Lädt alle Kacheln im Umkreis von 15 km um die aktuelle Position."
    }

    private var packText: String {
        guard let pack = roads.pack else { return "nicht enthalten" }
        // The extract's date is a UTC calendar date; shown as such in every time zone.
        var style = Date.FormatStyle.dateTime.locale(Format.locale).day().month(.twoDigits).year()
        style.timeZone = TimeZone(identifier: "UTC")!
        let date = (try? Date(pack.sourceDate, strategy: .iso8601))?.formatted(style) ?? pack.sourceDate
        let size = roads.packBytes.map { ", " + Format.bytes(Int64($0)) } ?? ""
        return "\(pack.area), Stand \(date)\(size)"
    }

    private var permissionText: String {
        switch engine.authorization {
        case .authorizedAlways: engine.isReducedAccuracy ? "Immer, ungenau" : "Immer"
        case .authorizedWhenInUse: engine.isReducedAccuracy ? "Beim Verwenden, ungenau" : "Beim Verwenden"
        case .denied: "Abgelehnt"
        case .restricted: "Eingeschränkt"
        default: "Noch nicht gefragt"
        }
    }

    private var permissionColor: Color {
        switch engine.authorization {
        case .authorizedAlways: engine.isReducedAccuracy ? Theme.Status.warn : Theme.Status.good
        case .authorizedWhenInUse: Theme.Status.warn
        case .denied, .restricted: Theme.Status.bad
        default: Theme.Text.secondary
        }
    }

    private var permissionExplanation: String {
        "„Beim Verwenden“ reicht für die Aufzeichnung, auch bei gesperrtem Display. Mit „Immer“ kann iOS Spur während einer Fahrt neu starten, falls das System die App beendet, so geht keine Strecke verloren. „Genaue Position“ muss an sein."
    }

    private func header(_ text: String) -> some View {
        Text(text).eyebrow()
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(Theme.Text.secondary)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(Typography.body).foregroundStyle(Theme.Text.primary)
    }
}

private struct LabeledField: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).font(Typography.body).foregroundStyle(Theme.Text.primary)
            TextField(placeholder, text: $text)
                .font(Typography.body)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.Text.secondary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .frame(minHeight: 44)
    }
}

/// "Alle Fahrten löschen" with a typed confirmation.
struct DeleteAllSheet: View {
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    static let word = "LÖSCHEN"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Alle Fahrten löschen")
                .font(Typography.title)
                .foregroundStyle(Theme.Text.primary)
            Text("Alle Fahrten und ihre Positionen werden endgültig von diesem iPhone entfernt. Zum Bestätigen \(Self.word) eingeben.")
                .font(Typography.body)
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(Self.word, text: $typed)
                .font(Typography.headline)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(Theme.Space.s)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("Abbrechen") { dismiss() }
                    .font(Typography.body)
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(minHeight: Theme.touchTarget)
                Spacer()
                Button("Endgültig löschen") {
                    onConfirm()
                    dismiss()
                }
                .font(Typography.body)
                .foregroundStyle(typed == Self.word ? Theme.Status.bad : Theme.Text.tertiary)
                .disabled(typed != Self.word)
                .frame(minHeight: Theme.touchTarget)
            }
        }
        .padding(Theme.Space.l)
        .presentationDetents([.height(340)])
        .presentationBackground(Theme.surface)
        .presentationCornerRadius(Theme.Radius.sheet)
    }
}
