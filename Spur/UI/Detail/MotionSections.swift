import Charts
import SwiftUI

/// The longitudinal chart's data: buckets with min and max, cut into runs at gaps, at most about
/// 600 buckets however long the trip (re-bucketed off the main actor by the model).
nonisolated enum MotionChart {
    struct Band: Identifiable, Sendable {
        var id: Int
        var date: Date
        var low: Double
        var high: Double
        /// The contiguous run the bucket belongs to: the area breaks between runs.
        var run: Int
    }

    static func bands(_ d: MotionDetails, columns: Int = MotionConstants.chartColumns) -> [Band] {
        let n = d.seriesTime.count
        guard n > 0, d.seriesMin.count == n, d.seriesMax.count == n else { return [] }
        let step = d.seriesStep ?? 0.5
        let group = max(1, Int((Double(n) / Double(columns)).rounded(.up)))
        var out: [Band] = []
        var run = 0
        var k = 0
        while k < n {
            if k > 0 && d.seriesTime[k] - d.seriesTime[k - 1] > 1.5 * step { run += 1 }
            var lo = d.seriesMin[k], hi = d.seriesMax[k]
            var j = k + 1
            // Merge up to `group` buckets, never across a gap.
            while j < n && j < k + group && d.seriesTime[j] - d.seriesTime[j - 1] <= 1.5 * step {
                lo = min(lo, d.seriesMin[j])
                hi = max(hi, d.seriesMax[j])
                j += 1
            }
            out.append(Band(id: out.count, date: Date(timeIntervalSince1970: d.seriesTime[k]), low: lo, high: hi, run: run))
            k = j
        }
        return out
    }
}

/// "Fahrdynamik (Bewegungssensor)" in the trip detail (SPEC 16.3.4): quality, extremes, events and
/// the longitudinal acceleration over time. Every number states its exact rule, built from
/// `MotionConstants`.
struct MotionDynamicsSection: View {
    var summary: MotionSummary
    var bands: [MotionChart.Band]
    var events: [MotionEvent]
    var units: UnitSystem
    /// The recorder's problems during the trip.
    var health: MotionHealth? = nil

    static let title = "Fahrdynamik (Bewegungssensor)"
    static let info = "Aus dem Bewegungssensor des iPhones (Beschleunigung und Drehrate, 100 oder 50 Messungen je Sekunde). Das Handy sitzt in der Halterung schräg: Senkrecht kommt aus der Schwerkraft, die Ausrichtung in der Waagerechten wird je Fahrt aus GPS (Geschwindigkeitsänderung) und Kreisel (Drehrate mal Geschwindigkeit) ermittelt, je Abschnitt zwischen zwei Lageänderungen des Handys. Zeiten, in denen das Handy bewegt wird, zählen nicht."

    static func n(_ v: Double, _ digits: Int = 1) -> String { Format.number(v, digits: digits) }
    static func g(_ v: Double) -> String { n(abs(v) / MotionConstants.g, 2) + " g" }

    /// The first quality line: the verdict and r ("r längs", or "r quer" at constant speed).
    static func statusLine(_ s: MotionSummary) -> String {
        guard s.hasEnoughSamples else { return "Zu wenige Sensordaten (\(s.sampleCount) Messungen)" }
        guard s.isAligned else {
            return s.reflected ? "Nicht ausgerichtet: Sensordaten widersprechen sich" : "Nicht ausgerichtet: zu wenig Beschleunigen, Bremsen oder Kurven"
        }
        var parts = [s.alignmentGood ? "Ausrichtung gut" : "Ausrichtung unsicher"]
        if let r = s.rFit {
            parts.append("r = " + n(r, 2) + (s.rFitLateralOnly == true ? " (quer, Tempo gleichmäßig)" : " (längs und quer)"))
        } else if let r = s.rLong {
            parts.append("r längs = " + n(r, 2))
        } else if let r = s.rLat {
            parts.append("r quer = " + n(r, 2))
        }
        return parts.joined(separator: " · ")
    }

    /// The second line: how much of the trip is aligned, and how much has samples at all.
    static func alignmentLine(_ s: MotionSummary) -> String {
        var parts: [String] = []
        if s.isAligned, let share = s.alignedShare {
            // SPEC 18.10a: the rest of the time in words (in a hand, or finding the mount again).
            var line = "Ausgerichtet \(Format.percent(share)) der Fahrzeit"
            if share < 0.995 { line += ", \(Format.percent(1 - share)) in der Hand oder beim Ausrichten" }
            parts.append(line + " (\(s.alignedSegments) von \(s.segments) Abschnitten)")
        }
        if let c = s.coverage { parts.append("Sensordaten für \(Format.percent(c)) der Fahrzeit") }
        return parts.joined(separator: " · ")
    }

    /// Specific doubts, each its own line.
    static func warnings(_ s: MotionSummary) -> [String] {
        var out: [String] = []
        if s.isAligned, !s.gainsOK, let gains = s.gains {
            out.append("Skala quer weicht ab (" + gains.map { n($0, 2) }.joined(separator: ", ") + " statt 1): Werte und Ereignisse unsicher")
        }
        if s.yawSwapped == true { out.append("Drehrichtung des Sensors widerspricht GPS: links und rechts getauscht") }
        if s.lagAtBoundary == true, let lag = s.lagSeconds { out.append("GPS-Verzögerung am Rand des Suchbereichs (\(n(lag)) s)") }
        return out
    }

    static func isAmber(_ s: MotionSummary) -> Bool {
        !s.alignmentGood || (s.coverage ?? 0) < 0.9 || !warnings(s).isEmpty
    }

    private var qualityInfo: String {
        let c = MotionConstants.self
        return "r ist die Korrelation der ermittelten Beschleunigung mit GPS und Kreisel: längs gegen die Geschwindigkeitsänderung aus GPS, quer gegen Drehrate mal Geschwindigkeit, beide zusammen; ändert sich das Tempo kaum mehr als das Rauschen der GPS-Geschwindigkeit (eine Autobahn), zählt nur quer. Ein Abschnitt zählt als ausgerichtet mit mindestens \(c.excitationCount) Sekundenpaaren ab \(Self.n(c.excitationTarget)) m/s² und eigenem r ab \(Self.n(c.goodRLong)); sonst bleiben seine Längs- und Querwerte leer, Stöße zählen trotzdem. Gut heißt zusätzlich: mindestens \(Format.percent(c.goodAlignedShare)) der Zeit ausgerichtet, Skala quer zwischen \(Self.n(c.gainRange.lowerBound, 2)) und \(Self.n(c.gainRange.upperBound, 2)) (längs nur zur Information: \(summary.gainsLong.map { $0.map { Self.n($0, 2) }.joined(separator: ", ") } ?? "-"), iOS glättet die GPS-Geschwindigkeit), Drehrichtung von Kreisel und GPS stimmen überein (\(summary.rYaw.map { "r Drehung " + Self.n($0, 2) } ?? "nicht prüfbar, zu wenig Kurven")). Lageänderungen des Handys: \(max(0, summary.segments - 1)), Zeit mit bewegtem Handy: \(summary.handlingShare.map { Format.percent($0) } ?? "-"), Sensorlücken über \(Self.n(c.sensorGapSeconds)) s: \(summary.sensorGaps), GPS-Verzögerung \(summary.lagSeconds.map { Self.n($0) } ?? "-") s." + healthText
    }

    private var healthText: String {
        guard let h = health else { return "" }
        var parts: [String] = []
        if h.restarts > 0 { parts.append("Sensoraufzeichnung \(h.restarts) Mal neu gestartet (keine Daten für 15 s)") }
        if h.writeFailures > 0 { parts.append("\(h.writeFailures) Mal nicht gespeichert") }
        if h.gaveUp { parts.append("nach wiederholten Fehlern gestoppt") }
        if h.openFailed { parts.append("Datei konnte nicht angelegt werden") }
        if (summary.rejectedRecords ?? 0) > 0 { parts.append("\(summary.rejectedRecords!) unplausible Messungen verworfen") }
        return parts.isEmpty ? "" : " Aufzeichnung: " + parts.joined(separator: ", ") + "."
    }

    private var minSpeed: String {
        "\(Format.speed(MotionConstants.bumpMinSpeed, units)) \(units.speedUnit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: Self.title, info: Self.info)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Self.isAmber(summary) ? Theme.Status.warn : Theme.Status.good).frame(width: 7, height: 7)
                    Text(Self.statusLine(summary))
                        .font(Typography.caption)
                        .foregroundStyle(Theme.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    InfoButton(title: "Ausrichtung", text: qualityInfo)
                }
                let line = Self.alignmentLine(summary)
                if !line.isEmpty {
                    Text(line)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 13)
                }
                ForEach(Self.warnings(summary), id: \.self) { w in
                    Text(w)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.Status.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 13)
                }
            }
            .accessibilityElement(children: .combine)
            if summary.isAligned {
                extremes
            }
            if summary.hasEnoughSamples {
                eventCounts
            }
            if !bands.isEmpty {
                chart
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    var extremes: some View {
        let lp = "über \(Self.n(1 / (2 * MotionConstants.eventLowPassHz), 2)) s geglättet (etwa \(Self.n(MotionConstants.eventLowPassHz, 0)) Hz), nur in ausgerichteter Zeit ohne bewegtes Handy"
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Höchstwerte").eyebrow()
            grid {
                Metric(label: "Bremsen", value: summary.maxBraking.map { Self.n(-$0) } ?? "-",
                       unit: summary.maxBraking.map { "m/s² · \(Self.g($0))" } ?? "m/s²",
                       info: "Stärkste Verzögerung in Längsrichtung, \(lp).")
                Metric(label: "Beschleunigen", value: summary.maxAcceleration.map { Self.n($0) } ?? "-",
                       unit: summary.maxAcceleration.map { "m/s² · \(Self.g($0))" } ?? "m/s²",
                       info: "Stärkste Beschleunigung in Längsrichtung, \(lp).")
                Metric(label: "Quer links", value: summary.maxLateralLeft.map { Self.n($0) } ?? "-",
                       unit: summary.maxLateralLeft.map { "m/s² · \(Self.g($0))" } ?? "m/s²",
                       info: "Stärkste Querbeschleunigung nach links (in einer Linkskurve), \(lp).")
                Metric(label: "Quer rechts", value: summary.maxLateralRight.map { Self.n(-$0) } ?? "-",
                       unit: summary.maxLateralRight.map { "m/s² · \(Self.g($0))" } ?? "m/s²",
                       info: "Stärkste Querbeschleunigung nach rechts (in einer Rechtskurve), \(lp).")
            }
        }
    }

    var eventCounts: some View {
        let c = MotionConstants.self
        let ends = "endet erst \(Self.n(c.eventHysteresis)) m/s² darunter; Ereignisse weniger als \(Self.n(c.eventMergeSeconds, 2)) s auseinander zählen als eines, eine Sensorlücke trennt immer"
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Starke Ereignisse").eyebrow()
            grid {
                if summary.isAligned {
                    Metric(label: "Bremsungen", value: "\(summary.counts.hardBraking)",
                           unit: summary.counts.veryHardBraking > 0 ? "davon \(summary.counts.veryHardBraking) sehr stark" : "ab \(Self.n(-c.hardBraking)) m/s²",
                           info: "Längs mindestens \(Self.n(-c.hardBraking)) m/s² Verzögerung (geglättet) für zusammen mindestens \(Self.n(c.hardBrakingSeconds)) s; \(ends). Sehr stark: Spitze ab \(Self.n(-c.veryHardBraking)) m/s².")
                    Metric(label: "Beschleunigungen", value: "\(summary.counts.hardAcceleration)", unit: "ab \(Self.n(c.hardAcceleration)) m/s²",
                           info: "Längs mindestens \(Self.n(c.hardAcceleration)) m/s² (geglättet) für zusammen mindestens \(Self.n(c.hardAccelerationSeconds)) s; \(ends).")
                    Metric(label: "Querbeschl.", value: "\(summary.counts.lateralLeft + summary.counts.lateralRight)",
                           unit: "\(summary.counts.lateralLeft) links · \(summary.counts.lateralRight) rechts",
                           info: "Starke Querbeschleunigungen: quer mindestens \(Self.n(c.lateral)) m/s² (geglättet) für zusammen mindestens \(Self.n(c.lateralSeconds)) s; \(ends).")
                }
                Metric(label: "Stöße", value: "\(summary.counts.bumps)", unit: "ab \(Self.n(c.bump)) m/s²",
                       info: "Stöße wie eine Bodenwelle oder ein Schlagloch: senkrechte Beschleunigung (ohne den Mittelwert der umgebenden Sekunde, bis \(Self.n(c.roughnessLowPassHz, 0)) Hz) ab \(Self.n(c.bump)) m/s² und mindestens \(Self.n(c.bumpOverLocalRMS)) mal so stark wie das Rütteln der umgebenden Sekunde, bei mindestens \(minSpeed); Treffer innerhalb \(Self.n(c.bumpMergeSeconds, 0)) s zählen als einer. Zählt auch ohne Ausrichtung.")
            }
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: Theme.Space.m) { content() }
    }

    private var chart: some View {
        let marked = events.filter { $0.kind != .bump }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Längsbeschleunigung").eyebrow()
                InfoButton(title: "Längsbeschleunigung", text: "Je Zeitabschnitt (höchstens etwa \(MotionConstants.chartColumns) je Fahrt) der kleinste und größte Wert, geglättet über \(Self.n(1 / (2 * MotionConstants.eventLowPassHz), 2)) s, damit kurze Spitzen sichtbar bleiben. Lücken ohne ausgerichtete Sensordaten bleiben frei. Senkrechte Linien: starke Bremsungen (rot), starke Beschleunigungen (grün), starke Querbeschleunigungen (gelb).")
            }
            Chart {
                ForEach(bands) { b in
                    AreaMark(x: .value("Zeit", b.date), yStart: .value("min", b.low), yEnd: .value("max", b.high),
                             series: .value("Teil", b.run))
                        .foregroundStyle(Theme.accentLight.opacity(0.55))
                }
                RuleMark(y: .value("0", 0)).foregroundStyle(Theme.Text.tertiary).lineStyle(StrokeStyle(lineWidth: 0.5))
                ForEach(Array(marked.prefix(200).enumerated()), id: \.offset) { _, e in
                    RuleMark(x: .value("Ereignis", Date(timeIntervalSince1970: e.peakTime)))
                        .foregroundStyle(Self.color(e.kind).opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYAxisLabel { Text("m/s²").font(Typography.label).foregroundStyle(Theme.Text.tertiary) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel(format: .dateTime.hour().minute(), centered: false).font(Typography.label).foregroundStyle(Theme.Text.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().font(Typography.label).foregroundStyle(Theme.Text.tertiary)
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Längsbeschleunigung über die Zeit, \(marked.count) markierte Ereignisse")
        }
    }

    static func color(_ kind: MotionEvent.Kind) -> Color {
        switch kind {
        case .hardBraking: return Theme.Status.bad
        case .hardAcceleration: return Theme.Status.good
        case .lateralLeft, .lateralRight: return Theme.Status.warn
        case .bump: return Theme.Text.secondary
        }
    }
}

/// "Fahrbahn (Bewegungssensor)": roughness shares, jolts and the roughest stretches.
struct RoadSurfaceSection: View {
    var summary: MotionSummary
    var details: MotionDetails?
    var units: UnitSystem

    static let classes = ["glatt", "normal", "uneben", "sehr uneben"]

    private var info: String {
        let c = MotionConstants.self
        let b = c.roughnessBounds
        let ref = "\(Format.speed(c.roughnessReferenceSpeed, units)) \(units.speedUnit)"
        return "Je \(MotionDynamicsSection.n(c.roughnessStretchM, 0)) m gefahrene Strecke ab \(Format.speed(c.roughnessMinSpeed, units)) \(units.speedUnit), ohne bewegtes Handy: Effektivwert der senkrechten Beschleunigung ohne den Mittelwert der umgebenden Sekunde, tiefpassgefiltert bei \(MotionDynamicsSection.n(c.roughnessLowPassHz, 0)) Hz (so sind 50 und 100 Hz Abtastrate vergleichbar) ohne das Grundrütteln (im Stand gemessen, nur soweit es während der Fahrt anhält) und auf \(ref) umgerechnet (mal Wurzel aus \(ref) durch das gefahrene Tempo). Klassen: glatt unter \(MotionDynamicsSection.n(b[0])) m/s², normal unter \(MotionDynamicsSection.n(b[1])), uneben unter \(MotionDynamicsSection.n(b[2])), darüber sehr uneben. Grenzen und Umrechnung sind eine erste Schätzung und werden nach der ersten echten Fahrt angepasst."
    }

    var body: some View {
        let total = summary.roughnessMeters.reduce(0, +)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: "Fahrbahn (Bewegungssensor)", info: info)
            if total > 0 {
                HStack(alignment: .top) {
                    ForEach(0..<4, id: \.self) { k in
                        Metric(label: Self.classes[k], value: Format.percent(summary.roughnessMeters[k] / total))
                        if k < 3 { Spacer(minLength: 0) }
                    }
                }
            } else {
                Text("Keine Strecke ab \(Format.speed(MotionConstants.roughnessMinSpeed, units)) \(units.speedUnit) gemessen.")
                    .font(Typography.callout).foregroundStyle(Theme.Text.secondary)
            }
            Metric(label: "Stöße", value: "\(summary.counts.bumps)", unit: "Bodenwelle, Schlagloch o. ä.")
            if let worst = details.map({ Array($0.stretches.sorted { $0.rms > $1.rms }.prefix(5)) }), !worst.isEmpty, total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unebenste Abschnitte").eyebrow()
                    ForEach(Array(worst.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.street ?? "ohne Straßennamen")
                                .font(Typography.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(MotionDynamicsSection.n(s.rms, 2)) m/s² · \(Self.classes[s.roughness])")
                                .font(Typography.caption)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Text.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// A calm map glyph for a motion event: a white symbol on a dark disc with a thin ring in the
/// event's colour; jolts smaller and grey.
struct MotionEventGlyph: View {
    var kind: MotionEvent.Kind
    var size: CGFloat = 22

    static func symbol(_ kind: MotionEvent.Kind) -> String {
        switch kind {
        case .hardBraking: return "arrow.down"
        case .hardAcceleration: return "arrow.up"
        case .lateralLeft: return "arrow.turn.up.left"
        case .lateralRight: return "arrow.turn.up.right"
        case .bump: return "arrow.up.and.down"
        }
    }

    static func label(_ kind: MotionEvent.Kind) -> String { kind.label }

    var body: some View {
        // Jolts are frequent on a rough road: a smaller, quieter glyph keeps the map readable.
        let size = kind == .bump ? self.size * 0.75 : self.size
        Image(systemName: Self.symbol(kind))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(kind == .bump ? Theme.Text.secondary : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(red: 0.12, green: 0.14, blue: 0.18)))
            .overlay(Circle().strokeBorder(MotionDynamicsSection.color(kind), lineWidth: 1.5))
            .accessibilityLabel(Self.label(kind))
    }
}

/// The callout of a tapped event on the map: kind, value, time, speed, street.
struct MotionEventCallout: View {
    var event: MotionEvent
    var units: UnitSystem

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let value = abs(event.peak)
        VStack(alignment: .leading, spacing: 2) {
            Text(event.kind.label)
                .font(Typography.caption)
                .foregroundStyle(Theme.Text.primary)
            Text("\(MotionDynamicsSection.n(value)) m/s² · \(MotionDynamicsSection.g(value))")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.secondary)
            Text(([Self.time.string(from: Date(timeIntervalSince1970: event.peakTime))]
                  + [event.speed.map { "\(Format.speed($0, units)) \(units.speedUnit)" }, event.street].compactMap { $0 })
                .joined(separator: " · "))
                .font(Typography.label)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(radius: 12)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
