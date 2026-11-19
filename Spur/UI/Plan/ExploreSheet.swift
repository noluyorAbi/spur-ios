import MapKit
import SwiftUI

/// What the scenario finder found, for the Planen map (SPEC 18.4).
@MainActor @Observable
final class ExploreModel {
    var features: Set<ScenarioFinder.Feature> = [.signals, .skewed]
    var onlyMissing = false
    var radiusKm = 5.0
    private(set) var results: [ScenarioFinder.Result] = []
    private(set) var nearest: ScenarioFinder.Nearest?
    private(set) var loading = false
    /// The honest empty state, nil while there are results or nothing was asked yet.
    private(set) var message: String?
    /// What is happening right now: loading road data (with the count) or computing.
    private(set) var status: String?

    /// "Straßendaten 3 von 12 …" while live tiles load, on the main actor.
    private func progress() -> @Sendable (Int, Int) -> Void {
        { [weak self] done, of in
            Task { @MainActor in
                guard let self, self.loading || self.planning else { return }
                self.status = of == 0 ? nil : "Straßendaten aus dem Internet: \(done) von \(of) Kacheln …"
            }
        }
    }

    func run(roads: RoadService, origin: LatLon, nearestOnly: Bool) async {
        loading = true
        message = nil
        results = []
        nearest = nil
        status = "Straßendaten werden geladen …"
        defer {
            loading = false
            status = nil
        }
        let data = await roads.scenarioData(around: origin, radiusM: radiusKm * 1000, progress: progress())
        guard !Task.isCancelled else { return }
        guard !data.segments.isEmpty else {
            message = data.noDataReason
            return
        }
        status = "Suche läuft …"
        let features = self.features, onlyMissing = self.onlyMissing, radiusM = radiusKm * 1000
        let driven = ScenarioFinder.drivenLookup(data.edges)
        if nearestOnly {
            let n = await Task.detached(priority: .userInitiated) {
                ScenarioFinder.nearestUndriven(from: origin, segments: data.segments, features: data.features, chips: features, driven: driven)
            }.value
            nearest = n
            if n == nil { message = "Nichts Unbefahrenes mit diesen Merkmalen im Umkreis" }
            return
        }
        let q = ScenarioFinder.Query(origin: origin, radiusM: radiusM, features: features, onlyMissing: onlyMissing)
        let found = await Task.detached(priority: .userInitiated) {
            ScenarioFinder.find(q, segments: data.segments, features: data.features, driven: driven)
        }.value
        results = found
        if found.isEmpty { message = "Nichts Unbefahrenes mit diesen Merkmalen im Umkreis" + (data.partialNote.map { " (\($0))" } ?? "") }
        else if let note = data.partialNote { message = note }
    }

    func clear() {
        results = []
        nearest = nil
        message = nil
    }

    // MARK: Entdeckerroute (SPEC 18.5)

    var toGoal = false
    /// Rundkurs: the length; Zum Ziel: the detour, in km.
    var budgetKm = 30.0
    private(set) var routes: [DiscoveryPlanner.Route] = []
    var chosen = 0
    private(set) var planning = false
    private(set) var planMessage: String?
    /// The search or planning in flight, for "Abbrechen".
    @ObservationIgnored var task: Task<Void, Never>?

    /// Farthest goal for "Zum Ziel": the road data of the way there must fit the live tile limit.
    static let maxGoalKm = 40.0

    func cancel() {
        task?.cancel()
        task = nil
        planning = false
        loading = false
        status = nil
        planMessage = "Abgebrochen"
    }

    func planRoute(roads: RoadService, start: LatLon, goal: LatLon?) async {
        planning = true
        planMessage = nil
        routes = []
        chosen = 0
        status = "Straßendaten werden geladen …"
        defer {
            planning = false
            status = nil
        }
        let goalPoint = toGoal ? goal : nil
        if toGoal && goalPoint == nil {
            planMessage = "Für Zum Ziel zuerst ein Ziel suchen"
            return
        }
        if let g = goalPoint, OSMGeo.haversine(start, g) > Self.maxGoalKm * 1000 {
            planMessage = "Das Ziel ist zu weit für eine Entdeckerroute (höchstens \(Int(Self.maxGoalKm)) km Luftlinie)"
            return
        }
        // The roads a route of this budget can reach: a loop of L km stays within about 0.3 L.
        let center = goalPoint.map { LatLon(lat: (start.lat + $0.lat) / 2, lon: (start.lon + $0.lon) / 2) } ?? start
        let span = goalPoint.map { OSMGeo.haversine(start, $0) / 2 + budgetKm * 500 } ?? budgetKm * 300
        let data = await roads.scenarioData(around: center, radiusM: min(25_000, max(3000, span)), progress: progress())
        guard !Task.isCancelled else { return }
        guard !data.segments.isEmpty else {
            planMessage = data.noDataReason
            return
        }
        status = "Route wird berechnet …"
        let features = self.features, onlyMissing = self.onlyMissing, wantedKm = self.budgetKm
        let q = DiscoveryPlanner.Query(start: start, mode: goalPoint.map { .toGoal($0) } ?? .loop, budgetM: wantedKm * 1000,
                                       features: features, onlyMissing: onlyMissing)
        let (planned, why) = await Task.detached(priority: .userInitiated) { () -> ([DiscoveryPlanner.Route], String?) in
            let driven = ScenarioFinder.drivenLookup(data.edges)
            let g = DiscoveryPlanner.graph(segments: data.segments, features: data.features, chips: features,
                                           onlyMissing: onlyMissing, driven: driven)
            let routes = DiscoveryPlanner.plan(q, graph: g)
            guard routes.isEmpty else { return (routes, nil) }
            // Why not: in the owner's words, with what would help.
            if DiscoveryPlanner.snap(start, g) == nil {
                return ([], "Dein Standort liegt an keiner Straße der geladenen Straßendaten")
            }
            if let p = goalPoint, DiscoveryPlanner.snap(p, g) == nil {
                return ([], "Das Ziel liegt an keiner Straße der geladenen Straßendaten")
            }
            if goalPoint != nil { return ([], "Kein befahrbarer Weg zum Ziel in den geladenen Straßendaten") }
            return ([], "Kein Rundkurs von etwa \(Int(wantedKm)) km gefunden. Eine andere Länge versuchen")
        }.value
        guard !Task.isCancelled else { return }
        routes = planned
        if let why { planMessage = why + (data.partialNote.map { " (\($0))" } ?? "") }
        else if let note = data.partialNote { planMessage = note }
    }

    func clearRoutes() {
        routes = []
        planMessage = nil
    }
}

/// "Was gibt es zu entdecken": the chips, the direction, the radius, and the two actions.
struct ExploreSheet: View {
    @Bindable var model: ExploreModel
    var place: String
    var search: () -> Void
    var nearest: () -> Void
    var pick: (ScenarioFinder.Result) -> Void
    /// The searched place, for Zum Ziel.
    var goalName: String?
    var plan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Was gibt es zu entdecken").font(Typography.headline).foregroundStyle(Theme.Text.primary)
                FlowLayout(spacing: 8) {
                    ForEach(ScenarioFinder.Feature.allCases) { f in
                        let on = model.features.contains(f)
                        Button {
                            if on { model.features.remove(f) } else { model.features.insert(f) }
                        } label: {
                            Text(f.label)
                                .font(Typography.label)
                                .foregroundStyle(on ? Color.white : Theme.Text.primary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(Capsule().fill(on ? Theme.accent : Theme.Text.ink(0.08)))
                                .overlay(Capsule().strokeBorder(Theme.Text.ink(on ? 0 : 0.16), lineWidth: 1))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("explore.chip.\(f.rawValue)")
                    }
                }
                Picker("Richtung", selection: $model.onlyMissing) {
                    Text("Richtung egal").tag(false)
                    Text("Nur fehlende Richtung").tag(true)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Umkreis \(Int(model.radiusKm)) km um \(place)").font(Typography.body).foregroundStyle(Theme.Text.secondary)
                    Slider(value: $model.radiusKm, in: 1...20, step: 1)
                }
                Button(action: search) {
                    Text(model.loading ? "Suche läuft …" : "Suchen")
                        .font(Typography.font(17, relativeTo: .headline))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(model.loading || model.features.isEmpty)
                .accessibilityIdentifier("explore.search")
                Button(action: nearest) {
                    Text("Nächste unbefahrene Strecke")
                        .font(Typography.label)
                        .foregroundStyle(Theme.Text.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.Text.ink(0.08), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(model.loading)
                .accessibilityIdentifier("explore.nearest")
                if let message = model.message {
                    Text(message).font(Typography.body).foregroundStyle(Theme.Text.secondary).accessibilityIdentifier("explore.message")
                }
                // SPEC 18.5: the Entdeckerroute with the same chips and direction.
                Divider().overlay(Theme.hairline)
                Text("Entdeckerroute").font(Typography.headline).foregroundStyle(Theme.Text.primary)
                Picker("Art", selection: $model.toGoal) {
                    Text("Rundkurs").tag(false)
                    Text(goalName.map { "Zum Ziel: \($0)" } ?? "Zum Ziel").tag(true)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.toGoal ? "Umweg bis \(Int(model.budgetKm)) km" : "Länge etwa \(Int(model.budgetKm)) km")
                        .font(Typography.body).foregroundStyle(Theme.Text.secondary)
                    Slider(value: $model.budgetKm, in: model.toGoal ? 2...40 : 5...100, step: 1)
                }
                Button(action: plan) {
                    Text(model.planning ? "Route wird geplant …" : "Route planen")
                        .font(Typography.label)
                        .foregroundStyle(Theme.Text.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.Text.ink(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.Text.ink(0.16), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(model.planning || model.loading)
                .accessibilityIdentifier("explore.plan")
                if let status = model.status, model.planning || model.loading {
                    // SPEC 18.5 (2026-11-17): what is happening while it takes, and a way out.
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(status).font(Typography.body).foregroundStyle(Theme.Text.secondary)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("explore.status")
                        Spacer(minLength: 0)
                        Button("Abbrechen") { model.cancel() }
                            .font(Typography.label)
                            .accessibilityIdentifier("explore.cancel")
                    }
                    .animation(Theme.Motion.state, value: status)
                    .transition(.opacity)
                }
                if let m = model.planMessage {
                    Text(m).font(Typography.body).foregroundStyle(Theme.Text.secondary).accessibilityIdentifier("explore.planMessage")
                }
                ForEach(Array(model.results.enumerated()), id: \.element.id) { k, r in
                    Button { pick(r) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text("\(k + 1)").font(Typography.label).monospacedDigit().foregroundStyle(Theme.Text.tertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.reason).font(Typography.body).foregroundStyle(Theme.Text.primary).multilineTextAlignment(.leading)
                                Text(distanceText(r.distanceM)).font(Typography.caption).foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("explore.result.\(k)")
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func distanceText(_ m: Double) -> String {
        m < 1000 ? "\(Int((m / 10).rounded()) * 10) m entfernt" : String(format: "%.1f km entfernt", m / 1000).replacingOccurrences(of: ".", with: ",")
    }
}

/// Chips that wrap onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
