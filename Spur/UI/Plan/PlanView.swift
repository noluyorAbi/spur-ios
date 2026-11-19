import MapKit
import SwiftUI

/// "Planen" (SPEC 18.3): find a place, see how far it is, and hand it to a navigation app or
/// show the route in Spur. One primary action per view: searching here, Navigieren on the card.
struct PlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @Environment(RoadService.self) private var roads
    @State private var search = SearchModel()
    @State private var explore = ExploreModel()
    /// Streets by name from the road data (SPEC 18.11).
    @State private var streets = StreetSearchModel()
    @State private var showExplore = false
    /// The last searched place, the goal of "Zum Ziel" (SPEC 18.5).
    @State private var lastPlace: MKMapItem?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var region: MKCoordinateRegion?
    @State private var selected: MKMapItem?
    @FocusState private var typing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position, selection: Binding(get: { selected.map(MapSelection.init) }, set: { selected = $0?.value })) {
                UserAnnotation()
                ForEach(search.results, id: \.self) { item in
                    Marker(item: item).tint(Theme.accent)
                }
                // SPEC 18.4: what the scenario finder found, and the nearest undriven stretch.
                ForEach(explore.results) { r in
                    ForEach(Array(r.coords.enumerated()), id: \.offset) { _, line in
                        MapPolyline(coordinates: line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                            .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                            .stroke(Theme.Status.warn, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                // SPEC 18.5: the alternatives faint, the chosen route on top.
                ForEach(Array(explore.routes.enumerated()), id: \.offset) { k, r in
                    if k != explore.chosen {
                        MapPolyline(coordinates: r.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                            .stroke(Theme.Text.ink(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                if explore.routes.indices.contains(explore.chosen) {
                    let line = explore.routes[explore.chosen].coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    MapPolyline(coordinates: line)
                        .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: line)
                        .stroke(Theme.accentLight, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if let n = explore.nearest {
                    MapPolyline(coordinates: n.segment.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: n.segment.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(Theme.Status.warn, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                // SPEC 18.11: the searched street, driven parts in the accent, the rest in the warning tone.
                if let st = streets.shown {
                    ForEach(Array(st.lines.enumerated()), id: \.offset) { k, line in
                        let c = line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                        MapPolyline(coordinates: c)
                            .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: c)
                            .stroke(st.driven[k] ? Theme.accentLight : Theme.Status.warn, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                if let route = model.plannedRoute {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(Theme.accentLight, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(settings.mapType.mapStyle(traffic: settings.trafficShown))
            .onMapCameraChange(frequency: .onEnd) { ctx in
                region = ctx.region
                search.setRegion(ctx.region)
            }
            .floatsOverMap(settings.mapType)
            .ignoresSafeArea(edges: .top)

            VStack(spacing: Theme.Space.xs) {
                searchField
                if typing && (!streetMatches.isEmpty || streets.loading) {
                    streetList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if typing && !search.suggestions.isEmpty {
                    suggestionList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if !typing && search.results.count > 1 {
                    resultList
                        .transition(.opacity)
                }
                if search.failed {
                    Banner(tone: .warn, symbol: "wifi.slash", text: "Suche gerade nicht möglich (keine Verbindung?)")
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .floatsOverMap(settings.mapType)
            .animation(Theme.Motion.state, value: typing)
            .animation(Theme.Motion.state, value: search.suggestions.count)
            .animation(Theme.Motion.state, value: streetMatches.map(\.id))
        }
        .onChange(of: typing) { _, now in
            guard now, let origin = model.engine.lastKnownCoordinate ?? region?.center else { return }
            Task { await streets.load(roads: roads, origin: LatLon(lat: origin.latitude, lon: origin.longitude)) }
        }
        .overlay(alignment: .bottom) {
            if let st = streets.shown, selected == nil, !typing {
                StreetCard(street: st, go: { p, name in show(p, name: name) }, close: { streets.shown = nil })
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.m)
                    .floatsOverMap(settings.mapType)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !explore.routes.isEmpty && selected == nil {
                RouteCard(model: explore) { route in
                    model.plannedRoute = PlannedRoute(name: "Entdeckerroute", coordinates: route.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                                                      seconds: route.seconds, meters: route.lengthM,
                                                      waypoints: route.waypoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    model.selectedTab = .live
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
                .floatsOverMap(settings.mapType)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if selected == nil && !typing {
                Button { showExplore = true } label: {
                    Label("Entdecken", systemImage: "sparkle.magnifyingglass")
                        .font(Typography.font(17, relativeTo: .headline))
                        .foregroundStyle(Theme.Text.primary)
                        .padding(.horizontal, Theme.Space.l)
                        .frame(minHeight: 48)
                        .glassSurface(radius: 24)
                }
                .buttonStyle(PressableStyle())
                .padding(.bottom, Theme.Space.l)
                .floatsOverMap(settings.mapType)
                .accessibilityIdentifier("plan.explore")
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showExplore) {
            ExploreSheet(model: explore, place: selected?.name ?? "deine Position", search: { runExplore(nearestOnly: false) },
                         nearest: { runExplore(nearestOnly: true) }, pick: { r in
                showExplore = false
                show(r.center, name: r.reason)
            }, goalName: lastPlace?.name, plan: runPlan)
            .presentationDetents([.medium, .large])
            .presentationBackground(Theme.surface)
        }
        .sheet(item: Binding(get: { selected.map(SelectedPlace.init) }, set: { if $0 == nil { selected = nil } })) { place in
            PlaceCard(item: place.item) { selected = nil }
                .presentationDetents([.height(330)])
                .presentationBackground(Theme.surface)
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Text.secondary)
            TextField("Ort, Adresse oder Straße suchen", text: $search.query)
                .font(Typography.body)
                .foregroundStyle(Theme.Text.primary)
                .focused($typing)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { run(nil) }
                .accessibilityIdentifier("plan.search")
            if !search.query.isEmpty {
                Button {
                    search.clear()
                    selected = nil
                    streets.shown = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Text.tertiary)
                }
                .accessibilityLabel("Suche leeren")
            }
            if search.searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 48)
        .glassSurface(radius: 24)
    }

    private var streetMatches: [StreetIndex.Street] { streets.matches(search.query) }

    /// SPEC 18.11: streets by name, the undiscovered first; with an empty field the nearest
    /// undiscovered streets.
    private var streetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(search.query.isEmpty ? "Unentdeckte Straßen in der Nähe" : "Straßen")
                .eyebrow()
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.xs)
            if streets.loading && streetMatches.isEmpty {
                Text("Straßendaten werden geladen …").font(Typography.caption).foregroundStyle(Theme.Text.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
            }
            ForEach(Array(streetMatches.enumerated()), id: \.element.id) { k, st in
                Button { pick(st) } label: {
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(st.undiscovered ? Theme.Status.warn : Theme.accentLight).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.name).font(Typography.body).foregroundStyle(Theme.Text.primary)
                            Text(StreetSearchModel.caption(st)).font(Typography.caption).monospacedDigit().foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("street.result.\(k)")
                if k < streetMatches.count - 1 { Divider().overlay(Theme.hairline).padding(.leading, Theme.Space.m) }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .glassSurface(radius: 18)
    }

    private func pick(_ st: StreetIndex.Street) {
        typing = false
        selected = nil
        streets.shown = st
        position = .region(StreetSearchModel.region(st))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { k, s in
                Button { run(s) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(Typography.body).foregroundStyle(Theme.Text.primary)
                        if !s.subtitle.isEmpty {
                            Text(s.subtitle).font(Typography.caption).foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                if k < search.suggestions.count - 1 { Divider().overlay(Theme.hairline).padding(.leading, Theme.Space.m) }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .glassSurface(radius: 18)
    }

    private var resultList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(search.results, id: \.self) { item in
                    Button { selected = item; lastPlace = item } label: {
                        Text(item.name ?? "Ort")
                            .font(Typography.label)
                            .foregroundStyle(Theme.Text.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .glassSurface(radius: 18)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    /// The finder from the searched place, else from the position Spur knows.
    private func runExplore(nearestOnly: Bool) {
        let origin = selected?.placemark.coordinate ?? model.engine.lastKnownCoordinate ?? region?.center
        guard let origin else { return }
        explore.task?.cancel()
        explore.task = Task {
            await explore.run(roads: roads, origin: LatLon(lat: origin.latitude, lon: origin.longitude), nearestOnly: nearestOnly)
            if nearestOnly, let n = explore.nearest {
                showExplore = false
                let name = "\(n.segment.streetName), Richtung \(ScenarioFinder.compass(OSMGeo.bearing(n.segment.coords.first!, n.segment.coords.last!) + (n.direction == .forward ? 0 : 180)))"
                show(CLLocationCoordinate2D(latitude: n.start.lat, longitude: n.start.lon), name: name)
            }
        }
    }

    private func runPlan() {
        let origin = model.engine.lastKnownCoordinate ?? region?.center
        guard let origin else { return }
        let goal = lastPlace.map { LatLon(lat: $0.placemark.coordinate.latitude, lon: $0.placemark.coordinate.longitude) }
        explore.task?.cancel()
        explore.task = Task {
            await explore.planRoute(roads: roads, start: LatLon(lat: origin.latitude, lon: origin.longitude), goal: goal)
            if !explore.routes.isEmpty {
                showExplore = false
                position = .automatic
            }
        }
    }

    /// A found place as a card with the 18.3 actions.
    private func show(_ c: LatLon, name: String) {
        show(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), name: name)
    }

    private func show(_ c: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = name
        position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2500, longitudinalMeters: 2500))
        selected = item
    }

    private func run(_ completion: MKLocalSearchCompletion?) {
        typing = false
        Task {
            await search.search(completion, region: region)
            if let only = search.results.first, search.results.count == 1 {
                selected = only
                lastPlace = only
                // One place: show it with its surroundings, not at the closest zoom.
                position = .region(MKCoordinateRegion(center: only.placemark.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500))
            } else if !search.results.isEmpty {
                position = .automatic
            }
        }
    }
}

private struct SelectedPlace: Identifiable {
    var item: MKMapItem
    var id: ObjectIdentifier { ObjectIdentifier(item) }
}

/// The place card: name, address, distance and driving time, and what to do with it.
struct PlaceCard: View {
    var item: MKMapItem
    var close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var route: MKRoute?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? "Ort").font(Typography.headline).foregroundStyle(Theme.Text.primary)
                    if let address = address {
                        Text(address).font(Typography.caption).foregroundStyle(Theme.Text.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Text.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Schließen")
            }
            Text(summary)
                .font(Typography.body)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.primary)
                .contentTransition(.numericText())
                .accessibilityIdentifier("plan.eta")
            Button {
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } label: {
                Label("Navigieren", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(Typography.font(17, relativeTo: .headline))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("plan.navigate")
            HStack(spacing: Theme.Space.s) {
                Button {
                    if let url = GoogleMapsLink.url(destination: item.placemark.coordinate) { openURL(url) }
                } label: {
                    Text("In Google Maps öffnen").secondaryAction()
                }
                .buttonStyle(PressableStyle())
                Button {
                    if let route {
                        model.plannedRoute = PlannedRoute(name: item.name ?? "Ziel", route: route)
                        close()
                    }
                } label: {
                    Text("Route in Spur zeigen").secondaryAction()
                }
                .buttonStyle(PressableStyle())
                .disabled(route == nil)
                .accessibilityIdentifier("plan.showRoute")
            }
        }
        .padding(Theme.Space.l)
        .task(id: "\(ObjectIdentifier(item))-\(model.engine.lastKnownCoordinate != nil)") {
            loading = true
            route = await SearchModel.route(to: item, from: model.engine.lastKnownCoordinate)
            loading = false
        }
    }

    private var address: String? {
        let p = item.placemark
        let line = [p.thoroughfare.map { [$0, p.subThoroughfare].compactMap { $0 }.joined(separator: " ") }, p.locality]
            .compactMap { $0 }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    private var summary: String {
        if loading { return "Fahrzeit wird berechnet …" }
        if route == nil && model.engine.lastKnownCoordinate == nil { return "Fahrzeit braucht deine Position" }
        guard let route else { return "Keine Autoroute gefunden" }
        let km = route.distance / 1000
        let minutes = Int((route.expectedTravelTime / 60).rounded())
        return String(format: "%@ km · etwa %@", km < 10 ? String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",") : "\(Int(km.rounded()))",
                      minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min")
    }
}

private extension Text {
    func secondaryAction() -> some View {
        self.font(Typography.label)
            .foregroundStyle(Theme.Text.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.Text.ink(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Text.ink(0.16), lineWidth: 1))
    }
}

/// The discovery route's card (SPEC 18.5): what it brings, and how to follow it.
struct RouteCard: View {
    @Bindable var model: ExploreModel
    var show: (DiscoveryPlanner.Route) -> Void
    @Environment(\.openURL) private var openURL
    @State private var gpxFile: URL?
    @State private var appleNote = false

    var body: some View {
        let route = model.routes[min(model.chosen, model.routes.count - 1)]
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Entdeckerroute").font(Typography.headline).foregroundStyle(Theme.Text.primary)
                Spacer()
                if model.routes.count > 1 {
                    Picker("Alternative", selection: $model.chosen) {
                        ForEach(model.routes.indices, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                Button { model.clearRoutes() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Text.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Route schließen")
            }
            Text(DiscoveryPlanner.card(route))
                .font(Typography.body).foregroundStyle(Theme.Text.primary)
                .accessibilityIdentifier("route.card")
            Text(route.outsideBudget ? "Länge weicht vom Wunsch ab · Abbiegeverbote nicht geprüft" : "Abbiegeverbote nicht geprüft")
                .font(Typography.caption).foregroundStyle(Theme.Text.secondary)
            if appleNote {
                Text("Apple Maps führt zum ersten Wegpunkt; den Rest zeigt Spur.").font(Typography.caption).foregroundStyle(Theme.Text.secondary)
            }
            Button { show(route) } label: {
                Label("Route anzeigen", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(Typography.font(17, relativeTo: .headline))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("route.show")
            HStack(spacing: Theme.Space.s) {
                Button {
                    if let p = route.waypoints.first {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)))
                        item.name = "Erster Wegpunkt"
                        appleNote = true
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                    }
                } label: { Text("Apple Maps").routeAction() }
                .buttonStyle(PressableStyle())
                Button {
                    if let url = DiscoveryPlanner.googleMapsURL(route) { openURL(url) }
                } label: { Text("Google Maps").routeAction() }
                .buttonStyle(PressableStyle())
                if let gpxFile {
                    ShareLink(item: gpxFile) { Text("GPX").routeAction() }
                }
            }
        }
        .padding(Theme.Space.l)
        .glassSurface()
        .task(id: "\(model.chosen)-\(route.arcs.count)") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Entdeckerroute.gpx")
            try? DiscoveryPlanner.gpx(route, name: "Entdeckerroute").write(to: url, atomically: true, encoding: .utf8)
            gpxFile = url
        }
    }
}

private extension Text {
    func routeAction() -> some View {
        self.font(Typography.label)
            .foregroundStyle(Theme.Text.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.Text.ink(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Text.ink(0.16), lineWidth: 1))
    }
}
