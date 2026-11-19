import CoreLocation
import SwiftUI

/// Tab "Fahrt": full-screen map with the glanceable HUD (SPEC section 7.1).
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @Environment(RoadService.self) private var roads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var following = true
    @State private var recenterRequest = 0
    @State private var showEvents = false
    /// The live details panel (SPEC 17.1).
    @State private var showDetails = false
    @State private var detailsLarge = false
    @State private var toast: String?
    @State private var dismissedGap: Gap?
    @State private var eventTick = 0
    /// Global y of the bottom edge of the top HUD and of the top edge of the bottom card, so the
    /// map can keep the position and the fresh trail in the visible gap between them.
    @State private var hudTopMaxY: CGFloat = 0
    @State private var cardMinY: CGFloat = 0
    /// Earlier trips the "bereits gefahren" layer currently draws (read out by VoiceOver).
    @State private var drivenTripCount = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if engine.isDenied && !engine.isRecording {
                PermissionDeniedView()
                    .transition(.opacity)
            } else {
                // On satellite imagery the map's own marks and everything floating over it use
                // the dark glass (SPEC 18.2b).
                LiveMapView(following: $following, recenterRequest: $recenterRequest, drivenTripCount: $drivenTripCount,
                            obscuredTopY: hudTopMaxY, obscuredBottomY: cardMinY)
                    .floatsOverMap(settings.mapType)
                    .ignoresSafeArea()
                hud
                    .floatsOverMap(settings.mapType)
            }
        }
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: engine.phase)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: following)
        // One spring for the panel's height, the banners and the card folding (review U1).
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: detailsLarge)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: showDetails)
        // Outside a recording the panel is not offered; when the trip stops it shows the
        // finished trip until it is closed.
        .onChange(of: engine.isRecording) { _, recording in
            if recording { detailsLarge = false }
        }
        .sheet(isPresented: $showEvents) {
            EventPickerSheet { tag in
                if engine.addEvent(tag) {
                    eventTick += 1
                    show(toast: "Ereignis gesetzt: \(tag.label)")
                }
            }
        }
        .sheet(item: Binding(get: { engine.finishedTrip }, set: { engine.finishedTrip = $0 })) { trip in
            StopSummarySheet(trip: trip, units: settings.units) {
                model.open(trip: trip.id)
            }
        }
        .sensoryFeedback(.success, trigger: eventTick)
        // The first time driven roads appear on the map, the legend shows once by itself.
        .onChange(of: roads.coverageRevision) { _, _ in
            if !settings.coverageLegendSeen, settings.showDrivenLayer, !roads.coverageLines.isEmpty { showLegend() }
        }
        .onChange(of: settings.keepScreenAwake) { _, _ in engine.updateIdleTimer() }
        .task(id: engine.isRecording) {
            #if DEBUG
            guard engine.isRecording, let height = AppEnvironment.liveDetails else { return }
            try? await Task.sleep(for: .seconds(AppEnvironment.liveDetailsAfter))
            detailsLarge = height == "large"
            showDetails = engine.isRecording
            #endif
        }
    }

    // MARK: HUD

    private var hud: some View {
        // Large accessibility sizes would push the HUD over the map; the cap keeps it glanceable.
        // One glass container: the HUD's glass shapes (pill, chips, map buttons, card) render in
        // one pass over the moving map instead of one each. Spacing 0: they never blend together.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: Theme.Space.xs) {
                VStack(spacing: Theme.Space.xs) {
                    topBar
                    // The large panel covers the banners (review U1).
                    if !compactCard { banners.transition(.opacity) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { hudTopMaxY = $0 }
                // The open panel takes the room of the map buttons (the map stays visible above the
                // medium one); closing it brings them back.
                if !showDetails {
                    HStack(alignment: .top) {
                        Spacer()
                        mapButtons
                    }
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
                if let toast {
                    Text(toast)
                        .font(Typography.callout)
                        .foregroundStyle(Theme.Text.primary)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: 40)
                        .glassSurface(radius: 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showAlwaysCard { alwaysCard.transition(.opacity) }
                if showDetails {
                    if !detailsLarge { Spacer(minLength: 0) }
                    // Up to the medium height, less when banners take the room: it never pushes the
                    // top bar or the card.
                    LiveDetailsPanel(large: $detailsLarge) { closeDetails() }
                        .frame(maxHeight: detailsLarge ? .infinity : Self.mediumPanelHeight)
                        .layoutPriority(1)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else if engine.isRecording {
                    detailsHandle.transition(.opacity)
                }
                bottomCard
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { cardMinY = $0 }
                    // A swipe up on the card opens the live details (SPEC 17.1).
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            guard engine.isRecording, value.translation.height < -40,
                                  abs(value.translation.width) < abs(value.translation.height) else { return }
                            openDetails()
                        }
                    )
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.xxs)
            .padding(.bottom, Theme.Space.xs)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.xs) {
            RecordingPill()
            Spacer(minLength: 0)
            // The OSM category of the matched road when there is one, else the speed estimate;
            // the second line says which one it is (SPEC 14.5).
            if engine.isRecording, let chip = roadChip {
                HStack(spacing: 8) {
                    Circle().fill(chip.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(chip.label)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.Text.primary)
                            .contentTransition(.opacity)
                        Text(chip.source)
                            .font(Typography.font(10, relativeTo: .caption2))
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .glassSurface(radius: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Straße jetzt: \(chip.label), \(chip.source)")
                .transition(.opacity)
            }
            // Before Start the chip shows the warm-up position (SPEC 14.1), which is never stored.
            GPSChip(fix: engine.phase == .idle ? engine.warmFix : engine.live.lastFix, recording: engine.isRecording)
        }
    }

    private var roadChip: (label: String, source: String, color: Color)? {
        if let category = roads.counts.category {
            return (category.label, "laut OSM", Theme.accentLight)
        }
        if let road = engine.live.roadNow {
            return (road.label, "geschätzt", road.color)
        }
        return nil
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: Theme.Space.xs) {
            if let notice = engine.notice {
                Banner(tone: engine.noticeIsWarning ? .warn : .info,
                       symbol: engine.noticeIsWarning ? "exclamationmark.circle" : "checkmark.circle",
                       text: notice, onClose: { engine.notice = nil })
            }
            if engine.isPausedForAccess {
                Banner(tone: .bad, symbol: "location.slash", text: "Kein Standortzugriff. Die Fahrt wird nicht aufgezeichnet.",
                       action: ("Einstellungen", { openSettings() }))
            }
            if engine.isReducedAccuracy {
                Banner(tone: .warn, symbol: "scope", text: "Genaue Position ist aus. Spur und Strecke werden nicht erfasst.",
                       action: ("Ändern", { engine.requestFullAccuracy() }))
            }
            if engine.isRecording, !engine.isReducedAccuracy, let accuracy = engine.poorAccuracy {
                Banner(tone: .info, symbol: "scope",
                       text: "Ungenaue Position (± \(Int(accuracy.rounded())) m): freie Sicht zum Himmel?")
            }
            if let gap = engine.lastGap, gap != dismissedGap, engine.isRecording, gap.duration >= 1 || gap.reason == .relaunch {
                Banner(tone: .info, symbol: "arrow.clockwise",
                       text: gapText(gap), onClose: { dismissedGap = gap })
            }
            if let route = model.plannedRoute {
                Banner(tone: .info, symbol: "arrow.triangle.turn.up.right.diamond",
                       text: "\(route.waypoints.isEmpty ? "Route nach \(route.name)" : route.name): \(Format.distance(route.meters, settings.units)) \(settings.units.distanceUnit), etwa \(max(1, Int((route.seconds / 60).rounded()))) min",
                       onClose: { model.plannedRoute = nil })
            }
            if settings.mapType.isImagery && !model.connectivity.isOnline {
                Banner(tone: .info, symbol: "wifi.slash", text: "Satellitenbild nicht verfügbar (offline)")
            }
            if settings.showTraffic && !model.connectivity.isOnline {
                Banner(tone: .info, symbol: "wifi.slash", text: "Verkehr: keine Internetverbindung, keine Verkehrsdaten")
            }
            // SPEC 18.9: a manual pause says so; when the car drives, it asks to continue.
            if engine.isAutoPaused {
                Banner(tone: .info, symbol: "pause.circle",
                       text: "Automatisch pausiert (\(engine.trip?.openPause?.evidence ?? "Pause erkannt")), geht beim Losfahren weiter",
                       action: ("Fortsetzen", { _ = engine.resumeTrip() }))
            } else if engine.isPaused {
                Banner(tone: engine.drivingWhilePaused ? .warn : .info, symbol: "pause.circle",
                       text: engine.drivingWhilePaused ? "Pausiert, du fährst" : "Pausiert, es wird nichts aufgezeichnet",
                       action: ("Fortsetzen", { _ = engine.resumeTrip() }))
            }
            if engine.showsLowBatteryWarning {
                Banner(tone: .warn, symbol: "battery.25percent", text: "Akku unter 15 %. Bitte Ladekabel anschließen.",
                       onClose: { engine.batteryWarningDismissed = true })
            }
            if let error = engine.lastError {
                Banner(tone: .bad, symbol: "exclamationmark.triangle", text: error, onClose: { engine.dismissError() })
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func gapText(_ gap: Gap) -> String {
        let length = Format.duration(gap.duration)
        switch gap.reason {
        case .relaunch: return "Aufzeichnung nach Neustart fortgesetzt (Lücke \(length))"
        case .background: return "Aufzeichnung fortgesetzt (Lücke \(length) im Hintergrund)"
        case .signal: return "Aufzeichnung fortgesetzt (Lücke \(length) ohne Signal)"
        case .pause: return "Fahrt fortgesetzt nach \(length) Pause"
        }
    }

    private var mapButtons: some View {
        VStack(spacing: Theme.Space.xs) {
            MapTypeButton(settings: settings)
            MapIconButton(symbol: settings.showDrivenLayer ? "square.3.layers.3d.top.filled" : "square.3.layers.3d",
                          label: settings.showDrivenLayer ? "Bereits gefahren ausblenden" : "Bereits gefahren einblenden",
                          active: settings.showDrivenLayer) {
                settings.showDrivenLayer.toggle()
                // Turning it on says what the colours mean (SPEC 15.2).
                if settings.showDrivenLayer { showLegend() }
            }
            .accessibilityValue(settings.showDrivenLayer ? "\(drivenTripCount) frühere Fahrten" : "aus")
            .accessibilityIdentifier("layer.driven")
            MapIconButton(symbol: settings.showRoadFeatures ? "signpost.right.and.left.fill" : "signpost.right.and.left",
                          label: settings.showRoadFeatures ? "Ampeln und Schilder ausblenden" : "Ampeln und Schilder einblenden",
                          active: settings.showRoadFeatures) {
                settings.showRoadFeatures.toggle()
            }
            .accessibilityValue(settings.showRoadFeatures ? "\(roads.layer.pois.count) Symbole" : "aus")
            .accessibilityIdentifier("layer.roads")
            // SPEC 18.2: Apple's traffic layer; while it is on, the driven roads change to violet.
            MapIconButton(symbol: "car.rear.road.lane",
                          label: settings.showTraffic ? "Verkehr ausblenden" : "Verkehr einblenden",
                          active: settings.showTraffic) {
                settings.showTraffic.toggle()
                if settings.showTraffic { show(toast: settings.mapType.showsTraffic ? trafficToast : "Verkehr gibt es auf Standard und Hybrid, nicht auf Satellit", seconds: 3.5) }
            }
            .accessibilityValue(settings.showTraffic ? (model.connectivity.isOnline ? "an" : "an, keine Internetverbindung") : "aus")
            .accessibilityIdentifier("layer.traffic")
            MapIconButton(symbol: settings.courseUp ? "location.north.line.fill" : "safari",
                          label: settings.courseUp ? "In Fahrtrichtung, auf Norden umschalten" : "Norden oben, auf Fahrtrichtung umschalten",
                          active: settings.courseUp) {
                settings.courseUp.toggle()
            }
            if !following {
                MapIconButton(symbol: "location.fill", label: "Zentrieren", active: true) {
                    recenterRequest += 1
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    /// The compact card (about a quarter of the screen): speed, distance and duration in one row,
    /// the controls in a second row, a small secondary line. The map above keeps the trail visible.
    private var bottomCard: some View {
        VStack(spacing: engine.isRecording ? Theme.Space.xs : Theme.Space.s) {
            // With the large panel the card folds to its controls row (the speed beside Stop); Stop
            // keeps its place, size and hold (design review).
            if !compactCard {
            HStack(alignment: .bottom, spacing: Theme.Space.m) {
                // Once a second, so a sign and its red state go away when fixes stop (tunnel, GPS
                // loss) instead of standing still with the last value.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let limit = Self.displayedLimit(roads.counts.speedLimit, recording: engine.isRecording, enabled: settings.showSpeedLimit,
                                                    lastFix: engine.live.lastFix?.date, now: context.date)
                    let over = limit != nil && roads.overLimit
                    HStack(alignment: .bottom, spacing: Theme.Space.s) {
                        SpeedReadout(speed: engine.live.lastFix?.speed, units: settings.units, active: engine.isRecording && !engine.isPaused, warning: over && !engine.isPaused)
                        // SPEC 16.2: the OSM limit of the matched way, only on a stable match; fades
                        // in and out, the card keeps its height.
                        if let limit {
                            SpeedLimitSign(limit: limit, over: over, overBy: roads.overLimitBy,
                                           showUnit: (limit.unit == .mph) != (settings.units == .imperial))
                                .padding(.bottom, 10)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: limit)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: over)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Metric(label: "Strecke", value: Format.distance(engine.live.distance, settings.units),
                           unit: settings.units.distanceUnit, size: 22)
                        .accessibilityIdentifier("live.distance")
                    TripClock()
                }
            }
            .transition(.opacity)
            }
            controls
            // Two small lines in the room the single v1.0 line had (spacing above trimmed), so the
            // card does not grow: the moving average with the live road counters, then the footer.
            VStack(spacing: 1) {
                if let line = recordingLine {
                    Text(line)
                        .font(Typography.label)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Text.secondary)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("live.roadCounts")
                }
                Text("Bedienung nur durch Beifahrer")
                    .font(Typography.label)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, recordingLine == nil ? 0 : -8)
        }
        // While recording the two rows sit 4 pt closer, which pays for the second text line.
        .padding(14)
        .glassSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.card")
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy), value: recordingLine)
    }

    /// A sign whose last fix is older than this is taken down (SPEC 16.2).
    static let limitStaleSeconds = 5.0

    /// The limit the sign shows: recording, the setting on, the selector allowed it, and the last
    /// fix is at most 5 s old.
    static func displayedLimit(_ limit: SpeedLimit?, recording: Bool, enabled: Bool, lastFix: Date?, now: Date) -> SpeedLimit? {
        guard recording, enabled, let limit, let lastFix, now.timeIntervalSince(lastFix) <= limitStaleSeconds else { return nil }
        return limit
    }

    /// "Ø 48 km/h in Fahrt · 7 Ampeln · 2 Stopp · 1 schräg" while recording; the counters only
    /// when road data covers the position.
    private var recordingLine: String? {
        guard engine.isRecording else { return nil }
        var parts: [String] = []
        if let avg = movingAverage { parts.append("Ø \(Format.speed(avg, settings.units)) \(settings.units.speedUnit) in Fahrt") }
        if roads.counts.hasRoadData { parts.append(RoadCountText.live(roads.counts)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var movingAverage: Double? {
        engine.live.movingTime > 0 ? engine.live.distance / engine.live.movingTime : nil
    }

    @ViewBuilder private var controls: some View {
        switch engine.phase {
        case .idle, .awaitingPermission:
            StartButton(busy: engine.phase == .awaitingPermission) {
                following = true
                engine.requestStart()
            }
            .transition(.opacity)
        case .recording, .stopping:
            HStack(spacing: Theme.Space.s) {
                if compactCard {
                    CompactSpeed(speed: engine.isPaused ? nil : engine.live.lastFix?.speed, units: settings.units, warning: roads.overLimit && roads.counts.speedLimit != nil)
                        .transition(.opacity)
                } else {
                    HStack(spacing: Theme.Space.s) {
                        EventButton(showsLabel: false) { showEvents = true }
                            .disabled(engine.isPaused)
                            .opacity(engine.isPaused ? 0.4 : 1)
                        PauseButton(paused: engine.isPaused) {
                            if engine.isPaused {
                                if engine.resumeTrip() { show(toast: "Fahrt fortgesetzt") }
                            } else if engine.pauseTrip() {
                                show(toast: "Pausiert: es wird nichts aufgezeichnet")
                            }
                        }
                    }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                HoldToStopButton(onStop: { engine.stop() },
                                 // A correction after a mistaken press: long enough to read at a glance.
                                 onTooShort: { show(toast: "Zum Beenden gedrückt halten", seconds: 3) })
            }
            .transition(.opacity)
        }
    }

    /// The visible way into the live details: a small handle above the card.
    /// The medium height: the g circle, the current values and the status line, with a band of
    /// map above it (review U1).
    static let mediumPanelHeight: CGFloat = 290

    /// The large panel: the card folds to its controls row.
    private var compactCard: Bool { showDetails && detailsLarge && engine.isRecording }

    private func openDetails() {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy)) { showDetails = true }
    }

    private func closeDetails() {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy)) {
            showDetails = false
            detailsLarge = false
        }
    }

    private var detailsHandle: some View {
        Button {
            openDetails()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Live-Details")
                    .font(Typography.label)
                    .tracking(0.6)
            }
            .foregroundStyle(Theme.Text.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .glassSurface(radius: 16)
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Live-Details öffnen")
        .accessibilityHint("Oder auf der Karte unten nach oben wischen")
        .accessibilityIdentifier("live.details.handle")
    }

    // MARK: Always card

    private var showAlwaysCard: Bool {
        engine.authorization == .authorizedWhenInUse && !settings.alwaysHintDismissed && !engine.isRecording
    }

    private var alwaysCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Standort „Immer“ erlauben").eyebrow(Theme.Text.primaryOpacity)
            Text("Dann kann iOS Spur während einer Fahrt neu starten, falls das System die App beendet. So geht keine Strecke verloren.")
                .font(Typography.callout)
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button {
                    // iOS asks only once; afterwards the iOS settings are the way to "Immer".
                    if !engine.requestAlways() { openSettings() }
                } label: {
                    Text("Immer erlauben")
                        .font(Typography.callout)
                        .foregroundStyle(Theme.accentLight)
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                Spacer()
                Button {
                    settings.alwaysHintDismissed = true
                } label: {
                    Text("Später")
                        .font(Typography.callout)
                        .foregroundStyle(Theme.Text.secondary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(Theme.Space.m)
        .glassSurface()
    }

    /// What turning traffic on says: where it comes from, the colour change, and when it cannot show.
    private var trafficToast: String {
        guard model.connectivity.isOnline else { return "Verkehr: keine Internetverbindung, keine Verkehrsdaten" }
        return "Verkehr von Apple, wo Daten vorliegen · gefahrene Straßen jetzt lila und magenta"
    }

    /// The legend of the driven directions (SPEC 15.2), also read out by VoiceOver.
    static let coverageLegend = "Gelb: in einer Richtung gefahren · Grün mit Mittelstreifen: in beiden Richtungen · Pfeile zeigen die Richtung"
    /// The same legend while the traffic layer is on (SPEC 18.2: violet family instead).
    static let coverageLegendTraffic = "Lila: in einer Richtung gefahren · Magenta mit Mittelstreifen: in beiden Richtungen · Pfeile zeigen die Richtung"

    private func showLegend() {
        let legend = settings.trafficShown || settings.mapType.isImagery ? Self.coverageLegendTraffic : Self.coverageLegend
        show(toast: legend, seconds: 4)
        UIAccessibility.post(notification: .announcement, argument: legend)
        settings.coverageLegendSeen = true
    }

    private func show(toast text: String, seconds: Double = 1.8) {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.enter)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(Theme.Motion.respecting(reduceMotion, .easeIn(duration: 0.2))) {
                if toast == text { toast = nil }
            }
        }
    }
}

// MARK: - HUD parts

/// Current speed, very large, readable from 1 m.
struct SpeedReadout: View {
    var speed: Double?
    var units: UnitSystem
    var active: Bool
    /// Over the shown limit: the number takes the danger colour (SPEC 16.2).
    var warning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(units.speedUnit).eyebrow()
            Text(active ? Format.speed(speed, units) : "0")
                .font(Typography.fixed(68))
                .foregroundStyle(warning ? Theme.Status.bad : (active ? Theme.Text.primary : Theme.Text.tertiary))
                .monospacedDigit()
                .contentTransition(.numericText(value: speed ?? 0))
                .animation(Theme.Motion.respecting(reduceMotion, .spring(duration: 0.3, bounce: 0)), value: speed ?? 0)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geschwindigkeit \(Format.speed(speed, units)) \(units.speedUnit)")
    }
}

/// The speed in the folded card beside Stop, while the large panel is open (review U1).
struct CompactSpeed: View {
    var speed: Double?
    var units: UnitSystem
    var warning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Format.speed(speed, units))
                .font(Typography.fixed(40))
                .foregroundStyle(warning ? Theme.Status.bad : Theme.Text.primary)
                .monospacedDigit()
                .contentTransition(.numericText(value: speed ?? 0))
                .animation(Theme.Motion.respecting(reduceMotion, .spring(duration: 0.3, bounce: 0)), value: speed ?? 0)
            Text(units.speedUnit).eyebrow()
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geschwindigkeit \(Format.speed(speed, units)) \(units.speedUnit)")
        .accessibilityIdentifier("live.compactSpeed")
    }
}

/// Elapsed trip time, ticking once per second.
struct TripClock: View {
    @Environment(RecordingEngine.self) private var engine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = engine.trip.map { context.date.timeIntervalSince($0.startedAt) } ?? 0
            Metric(label: "Dauer", value: Format.duration(elapsed), size: 22)
                .accessibilityIdentifier("trip.duration")
        }
    }
}

/// "Bereit" or the recording pill with a pulsing red dot and the elapsed time.
struct RecordingPill: View {
    @Environment(RecordingEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if engine.isPausedForAccess {
                // No access: the trip is kept but nothing is being recorded.
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Status.warn)
                Text("Pausiert")
                    .font(Typography.label)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Text.primary)
            } else if engine.isRecording {
                PulsingDot(color: UIColor(Theme.Status.bad), pulsing: !reduceMotion)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = engine.trip.map { context.date.timeIntervalSince($0.startedAt) } ?? 0
                    Text(Format.duration(elapsed))
                        .font(Typography.callout)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Text.primary)
                }
            } else {
                Circle().fill(Theme.Status.idle).frame(width: 8, height: 8)
                Text(engine.phase == .stopping ? "Speichert" : "Bereit")
                    .font(Typography.label)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Text.primary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassSurface(radius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(engine.isRecording ? (engine.isPausedForAccess ? "Aufzeichnung pausiert, kein Standortzugriff" : "Aufzeichnung läuft") : "Bereit")
    }
}

/// The red recording dot, pulsing between full and 35 % opacity. A Core Animation layer animation:
/// it runs in the render server, while a repeating SwiftUI animation (or a symbol effect) re-ran
/// the view graph on every frame for the whole trip, about 5 to 10 % of the main thread in a
/// profiled drive, and made the buttons over the map slower to answer.
struct PulsingDot: UIViewRepresentable {
    var color: UIColor
    var pulsing: Bool

    func makeUIView(context: Context) -> PulseView {
        let view = PulseView()
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = 5
        return view
    }

    func updateUIView(_ view: PulseView, context: Context) {
        view.backgroundColor = color
        view.pulsing = pulsing
    }

    /// Core Animation drops layer animations when the view leaves its window or the app goes to
    /// the background, so the pulse is added again whenever the view is back on screen.
    final class PulseView: UIView {
        private static let key = "pulse"

        var pulsing = false {
            didSet { if pulsing != oldValue { refresh() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Selector observers are removed with the view by the system.
            NotificationCenter.default.addObserver(self, selector: #selector(enteredForeground),
                                                   name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func enteredForeground() { refresh() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        /// True while the pulse animation is attached (tests and checks).
        var isPulsing: Bool { layer.animation(forKey: Self.key) != nil }

        func refresh() {
            guard pulsing, window != nil else {
                layer.removeAnimation(forKey: Self.key)
                return
            }
            guard layer.animation(forKey: Self.key) == nil else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 0.9
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: Self.key)
        }
    }
}

/// GPS accuracy chip: green at most 5 m, amber up to 15 m, red above, grey without a fresh fix.
struct GPSChip: View {
    var fix: Fix?
    var recording: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let fresh = fix.map { context.date.timeIntervalSince($0.date) < 10 } ?? false
            let acc = fresh ? fix?.horizontalAccuracy : nil
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(color(acc))
                Text(acc.map { "± \(Int($0.rounded())) m" } ?? "GPS")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(acc == nil ? Theme.Text.secondary : Theme.Text.primary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .glassSurface(radius: 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(acc.map { "GPS Genauigkeit plus minus \(Int($0.rounded())) Meter" } ?? "Kein GPS")
        }
    }

    private func color(_ acc: Double?) -> Color {
        guard let acc else { return Theme.Status.idle }
        if acc <= 5 { return Theme.Status.good }
        if acc <= 15 { return Theme.Status.warn }
        return Theme.Status.bad
    }
}

/// Location access denied or restricted: a clear empty state with the way to iOS settings.
struct PermissionDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Image(systemName: "location.slash")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accentLight)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.surface))
            VStack(spacing: Theme.Space.s) {
                Text("Kein Zugriff auf den Standort")
                    .font(Typography.title)
                    .foregroundStyle(Theme.Text.primary)
                    .multilineTextAlignment(.center)
                Text("Spur braucht die Position, um die Fahrt aufzuzeichnen. Erlaube den Standort in den iOS-Einstellungen, am besten mit „Immer“ und „Genaue Position“. Alle Daten bleiben auf diesem iPhone.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("iOS-Einstellungen öffnen")
                    .font(Typography.font(17, relativeTo: .headline))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            Spacer()
            Text("Bedienung nur durch Beifahrer")
                .font(Typography.label)
                .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(Theme.Space.l)
    }
}
