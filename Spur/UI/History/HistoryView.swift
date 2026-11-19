import SwiftUI

/// Tab "Historie": totals, trips grouped by day, swipe to delete (SPEC section 7.2).
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingEngine.self) private var engine
    @Environment(Settings.self) private var settings
    @State private var pendingDelete: TripRecord?

    struct DayGroup: Identifiable {
        var id: Date
        var trips: [TripRecord]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.finishedTrips) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { DayGroup(id: $0, trips: grouped[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.historyPath) {
            List {
                if model.finishedTrips.isEmpty && !engine.isRecording {
                    if model.tripsLoaded { emptyState.listRowStyle() }
                } else {
                    TotalsCard(trips: model.finishedTrips, units: settings.units)
                        .listRowStyle()
                    if engine.isRecording, let trip = engine.trip {
                        Section {
                            // The running trip opens its live "Fahrt-Details" (SPEC 17.8).
                            Button {
                                model.historyPath.append(trip.id)
                            } label: {
                                RunningTripRow(trip: trip, units: settings.units)
                            }
                            .buttonStyle(PressableStyle())
                            .listRowStyle()
                            .accessibilityIdentifier("history.running")
                        } header: {
                            DayHeader(text: "Läuft")
                        }
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.trips) { trip in
                                Button {
                                    model.historyPath.append(trip.id)
                                } label: {
                                    TripRow(trip: trip, units: settings.units)
                                }
                                .buttonStyle(PressableStyle())
                                .listRowStyle()
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = trip
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            DayHeader(text: dayTitle(group.id))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Historie")
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ExportAllButton() }
            }
            .navigationDestination(for: UUID.self) { id in
                TripDetailView(tripId: id)
            }
            .confirmationDialog(
                "Fahrt löschen?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { trip in
                Button("Löschen", role: .destructive) { model.delete(trip.id) }
                Button("Abbrechen", role: .cancel) {}
            } message: { _ in
                Text("Die Fahrt und alle ihre Positionen werden von diesem iPhone entfernt.")
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Heute" }
        if calendar.isDateInYesterday(day) { return "Gestern" }
        return day.formatted(.dateTime.locale(Format.locale).weekday(.wide).day().month(.wide).year())
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentLight)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.surface))
            VStack(spacing: Theme.Space.xs) {
                Text("Noch keine Fahrten")
                    .font(Typography.title)
                    .foregroundStyle(Theme.Text.primary)
                Text("Tippe im Tab Fahrt auf Start. Jede Fahrt erscheint hier mit Karte, Strecke und Statistik.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.selectedTab = .live
            } label: {
                Label("Zur Fahrt", systemImage: "arrow.left")
                    .font(Typography.callout)
                    .foregroundStyle(Theme.accentLight)
                    .frame(minHeight: Theme.touchTarget)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

extension View {
    /// Plain list row on the dark background, no separators.
    func listRowStyle() -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: Theme.Space.m, bottom: 6, trailing: Theme.Space.m))
    }
}

struct DayHeader: View {
    var text: String

    var body: some View {
        Text(text)
            .eyebrow()
            .padding(.top, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background)
    }
}

/// Totals over all finished trips.
struct TotalsCard: View {
    var trips: [TripRecord]
    var units: UnitSystem

    var body: some View {
        let stats = trips.compactMap(\.statistics)
        let distance = stats.reduce(0) { $0 + $1.distance }
        let moving = stats.reduce(0) { $0 + $1.time.movingTime }
        var roads = RoadTypeStats()
        for s in stats {
            for c in RoadClass.allCases {
                roads[c].distance += s.roadType[c].distance
                roads[c].time += s.roadType[c].time
            }
        }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                Metric(label: "Gesamt", value: Format.distance(distance, units), unit: units.distanceUnit, size: 34)
                Spacer()
                Metric(label: "Fahrten", value: "\(trips.count)", size: 34)
                    .accessibilityIdentifier("totals.trips")
                Spacer()
                Metric(label: "Fahrzeit", value: Format.duration(moving), size: 22,
                       info: "Summe der Fahrzeit aller Fahrten: Intervalle mit mindestens 1 m/s.")
            }
            RoadShareBar(stats: roads, height: 6)
            RoadLegend(stats: roads, units: units, estimated: true)
            let osm = RoadTotals.of(trips)
            if osm.analyzedTrips > 0 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(alignment: .top) {
                    Metric(label: "Ampeln", value: "\(osm.signalSites)", size: 22,
                           info: "Summe der überfahrenen Ampelkreuzungen aller ausgewerteten Fahrten (\(osm.analyzedTrips) von \(trips.count)), laut OpenStreetMap.")
                        .accessibilityIdentifier("totals.signals")
                    Spacer()
                    Metric(label: "Stoppschilder", value: "\(osm.stopSigns)", size: 22,
                           info: "Summe der überfahrenen, in Fahrtrichtung geltenden Stoppschilder aller ausgewerteten Fahrten, laut OpenStreetMap. Untergrenze: OpenStreetMap kennt nicht alle.")
                    Spacer()
                }
                OSMAttribution()
            }
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

struct TripRow: View {
    var trip: TripRecord
    var units: UnitSystem

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TripThumbnail(record: trip)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(trip.displayTitle)
                        .font(Typography.body)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    if trip.isDemo == true {
                        Text("Demo")
                            .font(Typography.label)
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Text.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                }
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .monospacedDigit()
                    // A pause adds a clause; it may take a second line rather than being cut.
                    .lineLimit(2)
                RoadShareBar(stats: trip.statistics?.roadType, height: 4)
                    .frame(maxWidth: 180)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.tertiary)
                .padding(.trailing, 4)
        }
        .padding(Theme.Space.s)
        .cardSurface(radius: 18)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let time = trip.startedAt.formatted(.dateTime.locale(Format.locale).hour().minute())
        guard let s = trip.statistics else { return time }
        // SPEC 18.9: the pause is part of the duration; named only when there was one.
        let pause = trip.pauseSeconds()
        let pauseText = pause >= 60 ? ", davon \(Format.duration(pause)) Pause" : ""
        return "\(time) · \(Format.distance(s.distance, units)) \(units.distanceUnit) · \(Format.duration(s.time.totalDuration))\(pauseText)"
    }
}

struct RunningTripRow: View {
    var trip: TripRecord
    var units: UnitSystem
    @Environment(RecordingEngine.self) private var engine

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TripThumbnail(record: trip)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fahrt läuft")
                    .font(Typography.body)
                    .foregroundStyle(Theme.Text.primary)
                Text("Seit \(trip.startedAt.formatted(.dateTime.locale(Format.locale).hour().minute())) · \(Format.distance(engine.live.distance, units)) \(units.distanceUnit)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(Theme.Space.s)
        .cardSurface(radius: 18)
        .contentShape(Rectangle())
    }
}

extension TripRecord {
    /// Custom title, else places, else date and time.
    var displayTitle: String {
        customTitle ?? placeTitle ?? startedAt.formatted(.dateTime.locale(Format.locale).day().month(.abbreviated).hour().minute())
    }
}
