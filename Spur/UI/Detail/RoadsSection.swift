import SwiftUI

/// "Kreuzungen und Verkehrszeichen (laut OpenStreetMap)" in the trip detail (SPEC 14.6): counts,
/// stops by place, the streets with many signals or stop signs, road categories, speed limits,
/// the data coverage and "Neu auswerten". Every number carries its exact rule.
struct RoadsSection: View {
    var record: TripRecord
    var analyzing: Bool
    var units: UnitSystem
    /// "Straßendaten aus dem Internet laden": without it, missing tiles are not loaded.
    var online: Bool
    var onAnalyze: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let title = "Kreuzungen und Verkehrszeichen (laut OpenStreetMap)"

    /// The note under the coverage when tiles are missing: the automatic reload is promised only
    /// while the setting allows it.
    static func missingNote(_ missing: Int, online: Bool) -> String {
        let what = missing == 1 ? "Für 1 Kachel fehlen Straßendaten" : "Für \(missing) Kacheln fehlen Straßendaten"
        guard online else { return "\(what). Fehlende Kacheln werden nur mit „Straßendaten aus dem Internet laden“ nachgeladen." }
        return missing == 1 ? "\(what); sie wird nachgeladen, sobald Internet da ist, dann wird neu ausgewertet."
                            : "\(what); sie werden nachgeladen, sobald Internet da ist, dann wird neu ausgewertet."
    }
    static let info = "Aus Straßendaten von OpenStreetMap: Die Fahrt wird mit dem Kartenabgleich des Hauptprojekts (Hidden-Markov-Modell) auf das Straßennetz gelegt. Ein Knoten zählt nur, wenn er auf dem abgeglichenen Weg liegt und die Positionen dort im Median höchstens den Suchradius (2 × Genauigkeit, 12 bis 30 m) von der Straße entfernt sind; bloße Nähe zählt nie. Straßendaten kommen aus dem Offline-Paket, dem Zwischenspeicher oder, wenn erlaubt, von Overpass."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle(title: Self.title, info: Self.info)
            if let r = record.roads {
                content(r)
            } else if analyzing {
                progress
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(record.isRecording ? "Wird nach dem Ende der Fahrt ausgewertet." : "Noch nicht ausgewertet.")
                        .font(Typography.callout)
                        .foregroundStyle(Theme.Text.secondary)
                    if !record.isRecording { analyzeButton("Auswerten") }
                }
            }
            if let seconds = record.speedLimitSeconds, !seconds.isEmpty { SpeedLimitShares(seconds: seconds) }
            OSMAttribution()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: analyzing)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.state), value: record.roads)
    }

    private var progress: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().tint(Theme.accentLight)
            Text("Wird ausgewertet")
                .font(Typography.callout)
                .foregroundStyle(Theme.Text.secondary)
        }
        .frame(minHeight: Theme.touchTarget)
    }

    private func analyzeButton(_ title: String) -> some View {
        Button(action: onAnalyze) {
            Label(title, systemImage: "arrow.triangle.2.circlepath")
                .font(Typography.callout)
                .foregroundStyle(Theme.accentLight)
                .frame(minHeight: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(analyzing)
        .accessibilityIdentifier("roads.reanalyze")
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                  alignment: .leading, spacing: Theme.Space.m) { content() }
    }

    @ViewBuilder private func content(_ r: RoadStatistics) -> some View {
        coverage(r)
        grid {
            Metric(label: "Ampeln", value: "\(r.counts.signalSites)", size: 30,
                   info: "Ampelkreuzungen, die auf dem abgeglichenen Weg überfahren wurden. Ampelknoten einer Kreuzung (getrennte Fahrbahnen tragen zwei bis vier) zählen zusammen einmal: Knoten höchstens 30 m auseinander und über das Straßennetz innerhalb von 30 m verbunden. Eine Ampel, die laut OpenStreetMap nur für die Gegenrichtung gilt (traffic_signals:direction oder direction), zählt nicht.")
            Metric(label: "Stoppschilder", value: "\(r.counts.stopSigns)",
                   unit: r.counts.allWayStops > 0 ? "davon \(r.counts.allWayStops) Allwege" : nil, size: 30,
                   info: "Überfahrene Stoppschilder (highway=stop), die in Fahrtrichtung gelten: direction=forward oder backward bezogen auf die Knotenfolge der Straße, ohne Angabe gilt es. Allwege-Stopp: stop=all. In OpenStreetMap fehlen viele Stoppschilder; die Zahl ist eine Untergrenze.")
            Metric(label: "Schräg", value: "\(r.counts.skewedJunctions)", unit: "Kreuzungen",
                   info: "Kreuzungen mit mindestens drei Zufahrten, bei denen ein Zufahrtspaar unter 70° oder zwischen 110° und 150° aufeinandertrifft (Regel des Hauptprojekts). Die Richtung einer Zufahrt zeigt auf ihren ersten Knoten in mindestens 15 m Abstand.")
            Metric(label: "Vorfahrt achten", value: "\(r.counts.giveWay)",
                   info: "Überfahrene Knoten highway=give_way, die in Fahrtrichtung gelten.")
            Metric(label: "Kreisverkehre", value: "\(r.counts.roundabouts)",
                   info: "Kreisverkehre (junction=roundabout) und Minikreisel (highway=mini_roundabout); alle Knoten einer Runde im Kreisel zählen als einer.")
            Metric(label: "Bahnübergänge", value: "\(r.counts.levelCrossings)",
                   info: "Überfahrene Knoten railway=level_crossing.")
            Metric(label: "Ausfahrten", value: "\(r.counts.motorwayJunctions)", unit: "Autobahn",
                   info: "Überfahrene Knoten highway=motorway_junction (Ausfahrten).")
        }
        stopsByPlace(r)
        streets("Straßen mit vielen Ampeln", r.manySignals, noun: "Ampeln",
                info: "Straßen (Name, sonst Nummer, sonst Weg-ID) mit mindestens 300 m gefahrener Strecke und mehr als 3 Ampelkreuzungen je km.")
        streets("Straßen mit vielen Stoppschildern", r.manyStopSigns, noun: "Stopp",
                info: "Straßen mit mindestens 300 m gefahrener Strecke und mehr als 3 geltenden Stoppschildern je km. Untergrenze, weil OpenStreetMap viele Stoppschilder nicht kennt.")
        categories(r)
        limits(r)
        analyzeButton("Neu auswerten")
    }

    private func coverage(_ r: RoadStatistics) -> some View {
        let share = r.coverage.map { Format.percent($0) } ?? "-"
        let missing = r.missingTiles?.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Straßendaten für \(share) der Strecke")
                    .font(Typography.body)
                    .foregroundStyle(Theme.Text.primary)
                    .accessibilityIdentifier("roads.coverage")
                InfoButton(title: "Abdeckung", text: "Anteil der Strecke (wie in der Übersicht gemessen), deren Positionen auf das Straßennetz abgeglichen sind. Ohne Straßendaten bleibt die geschätzte Streckenart aus dem Tempo. Quellen dieser Auswertung: \(r.tilesFromPack) Kacheln aus dem Offline-Paket, \(r.tilesFromCache) aus dem Zwischenspeicher, \(r.tilesFromLive) direkt geladen.")
            }
            if missing > 0 {
                Text(Self.missingNote(missing, online: online))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Status.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stopsByPlace(_ r: RoadStatistics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                Text("Stopps").eyebrow()
                InfoButton(title: "Stopps nach Ort", text: "Stopps wie im Abschnitt Stopps (unter 1 m/s für mindestens 3 s). Ein Stopp gilt als an der Ampel oder am Stoppschild, wenn so ein Knoten des abgeglichenen Wegs höchstens 30 m von der mittleren Standposition entfernt ist (der nähere zählt), sonst als sonstiger Stopp.")
            }
            HStack(alignment: .top) {
                Metric(label: "An Ampel", value: "\(r.stops.signal)")
                Spacer()
                Metric(label: "An Stoppschild", value: "\(r.stops.stopSign)")
                Spacer()
                Metric(label: "Sonstige", value: "\(r.stops.other)")
            }
        }
    }

    private func streets(_ title: String, _ list: [RoadStatistics.StreetDensity], noun: String, info: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                Text(title).eyebrow()
                InfoButton(title: title, text: info)
            }
            if list.isEmpty {
                Text("Keine auf dieser Fahrt.")
                    .font(Typography.callout)
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(list, id: \.self) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.name)
                            .font(Typography.body)
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        Text("\(s.count) \(noun) auf \(Format.distance(s.drivenMeters, units)) \(units.distanceUnit)")
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Text.secondary)
                        Text("\(Format.number(perUnit(s.perKm), digits: 1))/\(units.distanceUnit)")
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Text.primary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Per km, or per mile in imperial units.
    private func perUnit(_ perKm: Double) -> Double {
        units == .metric ? perKm : perKm * 1.609344
    }

    private func categories(_ r: RoadStatistics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                Text("Straßenkategorien").eyebrow()
                InfoButton(title: "Straßenkategorien", text: "Strecke und Zeit je Kategorie nach den Regeln des Hauptprojekts aus den OpenStreetMap-Merkmalen (highway, ref, toll, frontage_road, name). Eine Straße kann zu mehreren Kategorien gehören, etwa eine Interstate auch zu Freeway; die Summen sind darum größer als die Strecke.")
            }
            if r.categories.isEmpty {
                Text("Keine abgeglichene Strecke.").font(Typography.callout).foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(r.categories, id: \.self) { c in
                    HStack {
                        Text(c.category.label).font(Typography.body).foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Text("\(Format.distance(c.distance, units)) \(units.distanceUnit)")
                            .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.primary)
                        Text(Format.duration(c.time))
                            .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                            .frame(width: 84, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func limits(_ r: RoadStatistics) -> some View {
        let tolerance = units == .metric ? "8 km/h" : "5 mph"
        return grid {
            Metric(label: "Tempolimit bekannt", value: r.speedLimitKnownShare.map { Format.percent($0) } ?? "-",
                   info: "Anteil der abgeglichenen Strecke auf Straßen mit lesbarem maxspeed in OpenStreetMap.")
            Metric(label: "Mehr als \(tolerance) darüber", value: r.speedingShare.map { Format.percent($0) } ?? "-",
                   info: "Anteil der Strecke mit bekanntem Tempolimit, auf dem das Tempo zwischen zwei abgeglichenen Positionen mehr als 5 mph (8 km/h) über dem Limit lag.")
        }
    }
}

/// The speed-limit sign's reasons (SPEC 17.9), shared by the live panel and the trip details.
enum SpeedLimitText {
    static func reason(_ hidden: SpeedLimitSelector.Hidden) -> String {
        switch hidden {
        case .noTag: return "Kein Tempolimit in OSM eingetragen"
        case .unstable: return "Straße noch nicht sicher erkannt"
        case .inaccurate: return "GPS zu ungenau"
        case .contested: return "Zwei Straßen mit verschiedenem Limit"
        case .qualified: return "Limit mit Bedingung (Zeit, Spur oder Fahrzeug)"
        case .noRoadData: return "Keine Straßendaten hier (Kacheln fehlen)"
        }
    }

    /// "45 mph laut OSM", or the reason there is none.
    static func now(_ limit: SpeedLimit?, hidden: SpeedLimitSelector.Hidden?) -> String {
        if let limit { return "\(limit.value) \(limit.unit == .mph ? "mph" : "km/h") laut OSM" }
        return reason(hidden ?? .unstable)
    }

    static func label(_ key: String) -> String {
        key == "shown" ? "Tempolimit gezeigt" : SpeedLimitSelector.Hidden(rawValue: key).map(reason) ?? key
    }
}

/// The trip's moving time by sign state: shown, or why not (SPEC 17.9). It tells after a drive
/// whether a missing sign was OSM, the matcher or the tiles.
struct SpeedLimitShares: View {
    var seconds: [String: Double]

    var body: some View {
        let total = seconds.values.reduce(0, +)
        let order = ["shown"] + SpeedLimitSelector.Hidden.allCases.map(\.rawValue)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 4) {
                Text("Tempolimit im HUD").eyebrow()
                InfoButton(title: "Tempolimit im HUD", text: "Anteil der Fahrzeit (ab 2 m/s), in der das Schild ein Tempolimit zeigte, und je Grund, warum es keines zeigte. Gezählt während der Fahrt, so wie das Schild es entschied.")
            }
            ForEach(order.filter { (seconds[$0] ?? 0) > 0 }, id: \.self) { key in
                HStack {
                    Text(SpeedLimitText.label(key)).font(Typography.callout).foregroundStyle(Theme.Text.primary).lineLimit(2)
                    Spacer()
                    Text(Format.percent(total > 0 ? (seconds[key] ?? 0) / total : 0))
                        .font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("detail.speedLimitShares")
    }
}
