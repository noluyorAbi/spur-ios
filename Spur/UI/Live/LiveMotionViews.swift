import Charts
import SwiftUI

/// "Fahrdynamik live" (SPEC 17.2a): the acceleration now in a g circle, the current values, the
/// trip's Höchstwerte and Starke Ereignisse so far (the trip analysis of the data so far, same
/// names, units and info texts as "Fahrt-Details") and the last 60 s of longitudinal acceleration.
/// Before the mount is aligned only the size of the acceleration is shown, never a sign.
struct LiveMotionSection: View {
    var model: LiveMotionModel
    var units: UnitSystem
    /// In the panel its header names the section: no title row, the definition at the status line,
    /// so the medium height shows the circle and the status (review U1).
    var compact = false

    static let title = "Fahrdynamik live"
    static let info = MotionDynamicsSection.info + " Live: die Auswertung der bisherigen Fahrt, neu berechnet, solange diese Ansicht offen ist; dazwischen werden die neuesten Messungen mit der zuletzt ermittelten Ausrichtung umgerechnet. Vorzeichen (vorn, hinten, links, rechts) erst, wenn die Ausrichtung steht, und nur, wo eine noch unbemerkte Schräglage das Vorzeichen nicht umdrehen könnte."

    private var snapshot: LiveMotionSnapshot { model.snapshot }

    /// The status line: what the live values can say now.
    static func status(_ snapshot: LiveMotionSnapshot, state: LiveMotionEstimator.State?) -> (text: String, good: Bool) {
        if snapshot.computing { return ("Wird berechnet …", false) }
        // SPEC 18.10a: handling in words, before the generic states.
        let current = state ?? snapshot.state
        if current != .aligned, let hidden = snapshot.hidden {
            switch hidden {
            case .inHand: return ("In der Hand, Werte pausiert", false)
            case .realigning(let remaining):
                let rest = remaining > 45 ? "noch etwa 1 min" : remaining > 15 ? "noch etwa 30 s" : "gleich"
                return ("Neu ausrichten nach dem Ablegen, \(rest) (braucht Anfahren und Bremsen)", false)
            }
        }
        switch current {
        case .waiting: return ("Warte auf Sensordaten", false)
        case .aligning: return ("Ausrichtung läuft (braucht Anfahren und Bremsen)", false)
        case .moved: return ("Handy bewegt: Ausrichtung wird neu geprüft", false)
        case .aligned:
            // One state, one colour (review U4): green with "Ausrichtung gut", amber with "unsicher";
            // a short sensor coverage is said in the line below, not by the dot.
            if let s = snapshot.summary { return (MotionDynamicsSection.statusLine(s), s.alignmentGood) }
            return ("Ausgerichtet", true)
        }
    }

    var body: some View {
        // The 12 Hz reading is read only inside `LiveReadingRow`: this body (and the chart in it)
        // follows the 1 Hz snapshot and the state, which changes rarely (17.4 main-thread cost).
        let status = Self.status(snapshot, state: model.state)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !compact { SectionTitle(title: Self.title, info: Self.info) }
            // The acceleration first: at the medium height it is what shows.
            LiveReadingRow(model: model, summary: snapshot.summary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(status.good ? Theme.Status.good : Theme.Status.warn).frame(width: 7, height: 7)
                Text(status.text)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.primary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                if compact {
                    Spacer(minLength: 0)
                    InfoButton(title: Self.title, text: Self.info)
                }
            }
            // Its info button stays reachable on its own.
            .accessibilityElement(children: compact ? .contain : .combine)
            .accessibilityIdentifier("live.motion.status")
            if let s = snapshot.summary, !MotionDynamicsSection.alignmentLine(s).isEmpty {
                Text(MotionDynamicsSection.alignmentLine(s))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
            if let s = snapshot.summary {
                let section = MotionDynamicsSection(summary: s, bands: [], events: [], units: units)
                if s.isAligned { section.extremes }
                if s.hasEnoughSamples { section.eventCounts }
            }
            RollingChart(points: snapshot.chart, events: recentEvents)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        // A container: an identifier on the card itself would replace its children's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.motion")
    }

    /// Longitudinal events of the last 60 s, as seconds before now.
    private var recentEvents: [(age: Double, kind: MotionEvent.Kind)] {
        (snapshot.details?.events ?? []).compactMap { e in
            let age = snapshot.time - e.peakTime
            guard age >= 0, age <= LiveMotionEstimator.chartSeconds, e.kind == .hardBraking || e.kind == .hardAcceleration else { return nil }
            return (age, e.kind)
        }
    }
}

/// The g circle and the current values: the only part that follows the 12 Hz reading.
struct LiveReadingRow: View {
    var model: LiveMotionModel
    var summary: MotionSummary?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            GCircle(reading: model.reading, trail: model.trail, summary: summary)
                .frame(width: 128, height: 128)
                // Room for the four direction words around it.
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
            CurrentValues(reading: model.reading)
            Spacer(minLength: 0)
        }
    }
}

/// The current longitudinal and lateral acceleration in m/s² and g; before alignment only the size.
struct CurrentValues: View {
    var reading: LiveMotionEstimator.Reading?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let r = reading, r.long != nil || r.lat != nil {
                value("Längs", r.long ?? r.longSize, positive: r.long == nil ? nil : "Beschleunigen", negative: r.long == nil ? nil : "Bremsen",
                      unsure: r.long == nil)
                value("Quer", r.lat ?? r.latSize, positive: r.lat == nil ? nil : "links", negative: r.lat == nil ? nil : "rechts",
                      unsure: r.lat == nil)
            } else {
                value("Gesamt", reading?.horizontal, positive: nil, negative: nil)
                Text("Richtung erst nach der Ausrichtung")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// `unsure`: the size without a direction (an unseen misalignment could flip this axis's sign).
    private func value(_ label: String, _ v: Double?, positive: String?, negative: String?, unsure: Bool = false) -> some View {
        let shown = v.map { (($0 * 10).rounded() / 10) }
        // A value that rounds to 0 has no direction to be unsure about.
        let direction = unsure ? (shown.map { abs($0) >= 0.1 } == true ? "unsicher" : nil)
            : shown.flatMap { x -> String? in x > 0 ? positive : (x < 0 ? negative : nil) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).eyebrow()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shown.map { Format.number(abs($0), digits: 1) } ?? "-")
                    .font(Typography.font(26, relativeTo: .title2))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Text.primary)
                    .contentTransition(.numericText(value: shown ?? 0))
                Text("m/s²").font(Typography.caption).foregroundStyle(Theme.Text.secondary)
            }
            // g and the direction in one small line (the column is narrow beside the circle).
            Text([shown.map { Format.number(abs($0) / MotionConstants.g, digits: 2) + " g" }, direction].compactMap { $0 }.joined(separator: " · "))
                .font(Typography.label)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.secondary)
        }
    }
}

/// The friction circle: the horizontal acceleration as a dot (up forward, left left), a fading
/// trail of the last 2 s, and tick marks at the trip's peaks per direction. Rings at 0.2, 0.4 and
/// 0.6 g. Before alignment a ring of the size alone, no dot.
struct GCircle: View {
    var reading: LiveMotionEstimator.Reading?
    var trail: [LiveMotionEstimator.Reading]
    var summary: MotionSummary?

    static let outerG = 0.6
    /// Peaks smaller than this get no mark.
    static let minPeakMark = 0.5

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 6
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let perMps = r / (Self.outerG * MotionConstants.g)
            for k in 1...3 {
                let rr = r * CGFloat(k) / 3
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(Theme.hairline), lineWidth: k == 3 ? 1.2 : 0.8)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: c.x - r, y: c.y)); axes.addLine(to: CGPoint(x: c.x + r, y: c.y))
            axes.move(to: CGPoint(x: c.x, y: c.y - r)); axes.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(axes, with: .color(Theme.hairline), lineWidth: 0.8)
            func point(_ long: Double, _ lat: Double) -> CGPoint {
                var x = -lat * perMps, y = -long * perMps
                let d = (x * x + y * y).squareRoot()
                if d > r { x *= r / d; y *= r / d }
                return CGPoint(x: c.x + x, y: c.y + y)
            }
            // Peaks so far: a short tick across each axis.
            if let s = summary, s.isAligned {
                let ticks: [(Double, Double)] = [(s.maxAcceleration ?? 0, 0), (s.maxBraking ?? 0, 0), (0, s.maxLateralLeft ?? 0), (0, s.maxLateralRight ?? 0)]
                // Only from 0.5 m/s², on its own axis at its radius (review U2: zero peaks drawn at
                // the centre read as a pause symbol).
                for (long, lat) in ticks where abs(long) >= Self.minPeakMark || abs(lat) >= Self.minPeakMark {
                    let p = point(long, lat)
                    var t = Path()
                    if long != 0 { t.move(to: CGPoint(x: p.x - 7, y: p.y)); t.addLine(to: CGPoint(x: p.x + 7, y: p.y)) }
                    else { t.move(to: CGPoint(x: p.x, y: p.y - 7)); t.addLine(to: CGPoint(x: p.x, y: p.y + 7)) }
                    ctx.stroke(t, with: .color(Theme.Text.secondary), lineWidth: 2)
                }
            }
            guard let now = reading else { return }
            if let long = now.long ?? (now.lat != nil ? 0 : nil), let lat = now.lat ?? (now.long != nil ? 0 : nil) {
                // Trail, fading with age.
                for (a, b) in zip(trail, trail.dropFirst()) {
                    guard let la = a.long, let qa = a.lat, let lb = b.long, let qb = b.lat else { continue }
                    var seg = Path()
                    seg.move(to: point(la, qa)); seg.addLine(to: point(lb, qb))
                    let age = now.time - b.time
                    ctx.stroke(seg, with: .color(Theme.accentLight.opacity(max(0, 1 - age / LiveMotionModel.trailSeconds) * 0.6)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                let p = point(long, lat)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(Theme.accentLight))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.black.opacity(0.5)), lineWidth: 1)
            } else {
                // Unaligned: the size only, as a dashed ring.
                let rr = min(r, now.horizontal * perMps)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(Theme.accentLight), style: StrokeStyle(lineWidth: 2.5, dash: [4, 4]))
            }
        }
        .overlay(alignment: .top) { axisLabel("Beschleunigen").offset(y: -12) }
        .overlay(alignment: .bottom) { axisLabel("Bremsen").offset(y: 12) }
        .overlay(alignment: .leading) { axisLabel("links").offset(x: -14) }
        .overlay(alignment: .trailing) { axisLabel("rechts").offset(x: 16) }
        .accessibilityElement()
        .accessibilityLabel("Beschleunigungskreis")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("live.gcircle")
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text).font(Typography.font(9, relativeTo: .caption2)).foregroundStyle(Theme.Text.tertiary)
    }

    private var accessibilityValue: String {
        guard let r = reading else { return "keine Daten" }
        if let l = r.long, let q = r.lat {
            return "längs \(Format.number(l, digits: 1)), quer \(Format.number(q, digits: 1)) Meter pro Sekunde zum Quadrat"
        }
        return "gesamt \(Format.number(r.horizontal, digits: 1)) Meter pro Sekunde zum Quadrat, Richtung noch unbekannt"
    }
}

/// Längsbeschleunigung over the last 60 s, with the strong braking and acceleration events.
struct RollingChart: View {
    var points: [LiveMotionSnapshot.ChartPoint]
    var events: [(age: Double, kind: MotionEvent.Kind)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Längsbeschleunigung, letzte 60 s").eyebrow()
            if points.isEmpty {
                Text("Erscheint, sobald die Ausrichtung steht.")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else {
                Chart {
                    RuleMark(y: .value("Null", 0)).foregroundStyle(Theme.hairline)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("s", -p.age), y: .value("m/s²", p.long))
                            .foregroundStyle(Theme.accentLight)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        PointMark(x: .value("s", -e.age), y: .value("m/s²", 0))
                            .symbol(e.kind == .hardBraking ? .triangle : .circle)
                            .foregroundStyle(e.kind == .hardBraking ? Theme.Status.warn : Theme.Status.good)
                    }
                }
                .chartXScale(domain: -LiveMotionEstimator.chartSeconds...0)
                .chartXAxis {
                    AxisMarks(values: [-60, -30, 0]) { v in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel { Text(v.as(Double.self).map { $0 == 0 ? "jetzt" : "\(Int($0)) s" } ?? "") }
                            .font(Typography.label)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().font(Typography.label).foregroundStyle(Theme.Text.secondary)
                    }
                }
                .frame(height: 110)
                .accessibilityLabel("Längsbeschleunigung der letzten 60 Sekunden")
            }
        }
    }
}

/// "Fahrbahn live" (SPEC 17.2b): the last finished 100 m stretch, then the trip's shares so far
/// in the trip detail's own section.
struct LiveRoadSurfaceSection: View {
    var snapshot: LiveMotionSnapshot
    var units: UnitSystem

    var body: some View {
        if let s = snapshot.summary {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let cls = snapshot.lastStretchClass {
                    HStack(spacing: 6) {
                        Text("Letzte 100 m").eyebrow()
                        Text(RoadSurfaceSection.classes[cls])
                            .font(Typography.callout)
                            .foregroundStyle(Theme.Text.primary)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .accessibilityElement(children: .combine)
                }
                RoadSurfaceSection(summary: s, details: snapshot.details, units: units)
            }
        }
    }
}

/// "Kreuzungen und Verkehrszeichen" while recording (SPEC 17.2c): the live counters, the road now
/// and its limit. After Stop the trip's own road analysis replaces it.
struct LiveRoadsSection: View {
    var counts: LiveRoadCounts
    var street: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: RoadsSection.title, info: "Live gezählt, solange die Fahrt läuft, aus den Straßendaten von OpenStreetMap um die Position: Ampelstandorte, Stoppschilder und schräge Kreuzungen auf der gefahrenen Strecke. Nach dem Beenden ersetzt die Auswertung der ganzen Fahrt diese Zahlen.")
            if counts.hasRoadData {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: Theme.Space.m) {
                    Metric(label: "Ampeln", value: "\(counts.signalSites)")
                    Metric(label: "Stoppschilder", value: "\(counts.stopSigns)",
                           unit: counts.allWayStops > 0 ? "davon \(counts.allWayStops) allseitig" : nil)
                    Metric(label: "Schräge Kreuzungen", value: "\(counts.skewedJunctions)")
                    Metric(label: "Straße jetzt", value: counts.category?.label ?? "-", unit: street, size: 18)
                    Metric(label: "Tempolimit jetzt", value: counts.speedLimit.map { "\($0.value)" } ?? "-",
                           unit: counts.speedLimit.map { $0.unit == .mph ? "mph laut OSM" : "km/h laut OSM" }, size: 18)
                }
                if counts.speedLimit == nil {
                    Text(SpeedLimitText.now(nil, hidden: counts.limitHidden))
                        .font(Typography.callout)
                        .foregroundStyle(Theme.Text.secondary)
                        .accessibilityIdentifier("live.limit.reason")
                }
                if !counts.limitSeconds.isEmpty { SpeedLimitShares(seconds: counts.limitSeconds) }
            } else {
                Text(SpeedLimitText.reason(.noRoadData)).font(Typography.callout).foregroundStyle(Theme.Text.secondary)
                if !counts.limitSeconds.isEmpty { SpeedLimitShares(seconds: counts.limitSeconds) }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// The live details panel over the live map (SPEC 17.1), between the top of the HUD and its card,
/// so the card and Stop stay as they are: at the medium height the sensor block with the map
/// still visible above it, at the large height every section of the running trip's
/// "Fahrt-Details". The same view and model as the running trip's details in the history. The
/// grabber switches the height (drag up or down, or tap) and closes it from the medium height.
struct LiveDetailsPanel: View {
    @Binding var large: Bool
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The trip shown: the running one, kept when it stops while the panel is open.
    @State private var tripId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let id = tripId ?? model.live.runningTripId {
                    TripDetailView(tripId: id, style: .panel)
                        // A soft edge where the panel cuts its content (design review).
                        .mask {
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                            }
                        }
                } else {
                    VStack(spacing: Theme.Space.s) {
                        Text("Keine Fahrt läuft")
                            .font(Typography.headline)
                            .foregroundStyle(Theme.Text.primary)
                        Text("Live-Details gibt es während einer Aufzeichnung.")
                            .font(Typography.callout)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .onAppear { tripId = model.live.runningTripId }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.details")
    }

    private var header: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.Text.tertiary).frame(width: 36, height: 5).padding(.top, 6)
            HStack {
                Button {
                    setLarge(!large)
                } label: {
                    Image(systemName: large ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: Theme.touchTarget, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(large ? "Verkleinern" : "Alle Details")
                .accessibilityIdentifier("live.details.size")
                Spacer()
                Text("Live-Details")
                    .font(Typography.font(17, relativeTo: .headline))
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: Theme.touchTarget, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Schließen")
                .accessibilityIdentifier("live.details.close")
            }
            .padding(.horizontal, Theme.Space.xs)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { v in
                if v.translation.height < -30 { setLarge(true) }
                else if v.translation.height > 30 { large ? setLarge(false) : onClose() }
            }
        )
    }

    private func setLarge(_ on: Bool) {
        withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.snappy)) { large = on }
    }
}

/// Wrappers that read the live sources inside themselves: the details view around them (and its
/// charts) then follows only the statistics, not the 1 Hz snapshot or every fix (17.4 cost).
struct LiveRoadSurfaceCard: View {
    var motion: LiveMotionModel
    var units: UnitSystem
    var body: some View { LiveRoadSurfaceSection(snapshot: motion.snapshot, units: units) }
}

struct LiveRoadsCard: View {
    var roads: RoadService
    var street: String?
    var body: some View { LiveRoadsSection(counts: roads.counts, street: street) }
}
