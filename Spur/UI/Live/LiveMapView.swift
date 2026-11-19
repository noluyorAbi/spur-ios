import MapKit
import SwiftUI

/// The live map: previous trips with their driven directions, the current trail with underglow and direction marks, accuracy halo,
/// position arrow and markers. The camera follows the position until the user pans.
struct LiveMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingEngine.self) private var engine
    @Environment(Settings.self) private var settings
    /// The driven roads take the violet family when traffic is drawn or imagery lies under them
    /// (SPEC 18.2, 18.2b): amber and green clash with traffic and vanish on vegetation.
    private var violet: Bool { settings.trafficShown || settings.mapType.isImagery }
    @Environment(RoadService.self) private var roads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the POI layer was last built, to rebuild it only when the anchor moved.
    @State private var layerAnchor: (center: CLLocationCoordinate2D, at: Date)?
    /// Road symbols only at a zoom where they read as single symbols (see `poiMaxMetersPerPoint`).
    @State private var poisZoomedIn = true
    /// The many-signal lines as map coordinates, converted once per layer, not on every redraw.
    @State private var roadLines: [RoadLine] = []

    struct RoadLine: Identifiable {
        var id: Int
        var coordinates: [CLLocationCoordinate2D]
    }

    /// Above this many meters per screen point the symbols would crowd into clusters: hidden.
    static let poiMaxMetersPerPoint = 9.0

    @Binding var following: Bool
    @Binding var recenterRequest: Int
    /// How many earlier trips the cached driven layer holds.
    @Binding var drivenTripCount: Int
    /// Global y below which the top HUD ends, and above which the bottom card starts.
    var obscuredTopY: CGFloat = 0
    var obscuredBottomY: CGFloat = 0
    @State private var mapFrame: CGRect = .zero

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The current trip as separate lines: split at gaps and jumps, never a straight connector.
    @State private var trail: [[CLLocationCoordinate2D]] = []
    /// SPEC 15: the earlier trips' driven roads in view (amber one direction, green with a dark
    /// centre stripe both), their direction marks, and the marks along the whole current trail,
    /// all as map polylines.
    @State private var coverageOverlays: [CoverageOverlay] = []
    @State private var coverageStripes: [CoverageOverlay] = []
    @State private var coverageMarks: [MarkLine] = []
    /// Häufigkeit (SPEC 18.7): the driven roads by how often, instead of by direction.
    @State private var heatOverlays: [HeatOverlay] = []
    /// What a tap on a heat line says, until the next tap or 5 s.
    @State private var heatInfo: String?
    @State private var trailMarks: [MarkLine] = []
    /// More driven lines in view than the budget: the raw previews stay visible as well.
    @State private var coverageTruncated = false
    /// What the direction layers were last built from (not observed: only a real change sets the
    /// state above, so the map content stays put between fixes).
    @State private var directions = DirectionInputs()
    /// Camera heading, read only by the small annotation views below, so a rotating camera does
    /// not re-evaluate this whole map body every frame.
    @State private var camera = CameraHeading()
    /// Speed smoothed over roughly ten fixes, so the follow zoom widens calmly with speed.
    @State private var smoothedSpeed: Double = 0
    @State private var lastTrailUpdate = Date.distantPast
    /// The camera the follow mode set last, to tell a visible step from one too small to see.
    @State private var lastFollowCamera: MapCamera?

    /// A follow step that moves no point of the visible map by this much is set at once instead
    /// of animated: at 1 Hz a 0.9 s animation kept MapKit rendering on the main thread almost all
    /// the time, which made the buttons over the map slow to answer. At the follow zoom a car
    /// moves about 2 pt per second, which reads as still; turns and zoom changes are measured in
    /// points too (at the edge of the visible gap), so a visible one is always animated.
    static let animateFromPoints = 4.0

    struct CoverageOverlay: Identifiable {
        var id: String
        var coordinates: [CLLocationCoordinate2D]
        var state: RoadCoverage.State
    }

    struct HeatOverlay: Identifiable {
        var id: String
        var coordinates: [CLLocationCoordinate2D]
        var bin: Int
        /// From 5 passes the line is one step wider.
        var width: Double { bin >= 3 ? 5 : 4 }
    }

    /// One chevron of a direction mark (three points); the id follows the mark, not its place in
    /// a list, so adding a mark leaves the others' overlays alone.
    struct MarkLine: Identifiable {
        var id: String
        var coordinates: [CLLocationCoordinate2D]
    }

    /// The square around the view center that a layer is built for, and when to rebuild it.
    struct ViewKey: Equatable {
        var step: Double
        var x: Int
        var y: Int
    }

    final class DirectionInputs {
        var center: LatLon?
        var metersPerPoint: Double?
        var step: Double = 0
        var coverageKey: ViewKey?
        var coverageRevision = -1
        var frequency = false
        var trailKey: ViewKey?
        var lineIds: [String] = []
        var stripeIds: [String] = []
        var coverageArrowIds: [String] = []
        var trailMarkIds: [String] = []
        /// The current trip's display runs and the marks along each, built from new fixes only.
        var runs = TrailGeometry.RunBuilder()
        var markers: [Int: TrailGeometry.Marker] = [:]
        var markerStep: Double = 0
        var markerCount = 0
    }

    /// Direction marks (SPEC 15.2), in screen points at the current zoom step: `markSizePoints`
    /// long, one every `markSpacingPoints` (thinned by doubling when over the budget), every
    /// driven line of at least `minLinePoints` gets one. The zoom step is a quarter octave kept
    /// within a factor 1.2, so on screen a mark stays 10 to 14.4 pt long.
    static let markSpacingPoints = 64.0
    static let markSizePoints = 12.0
    static let minLinePoints = 12.0
    /// No two marks of a layer closer than this on screen.
    static let markSeparationPoints = 36.0
    static let maxCoverageLines = 400
    static let maxCoverageMarks = 80
    static let maxTrailMarks = 60

    /// "Bereits gefahren": cached, rebuilt only when the trip list or the layer toggle changes,
    /// not on every live update.
    @State private var drivenLines: [DrivenLine] = []

    /// What the driven layer depends on: each trip's id and whether (and how far) its preview exists.
    static func drivenKey(_ trips: [TripRecord]) -> [String] {
        trips.map { "\($0.id.uuidString):\($0.preview?.count ?? -1):\(($0.roads?.coverage ?? 0) >= matchedEnough)" }
    }
    static let drivenVertexBudget = 40_000
    /// Share of a trip matched to roads above which its raw preview is not drawn (SPEC 15.2).
    static let matchedEnough = 0.95

    struct DrivenLine: Identifiable {
        /// Trip id and segment index: stable across reloads.
        var id: String
        var coordinates: [CLLocationCoordinate2D]
    }

    private func rebuildDrivenLines() {
        guard settings.showDrivenLayer else {
            drivenLines = []
            drivenTripCount = 0
            return
        }
        let currentId = engine.trip?.id
        let earlier = model.trips.filter { $0.id != currentId && !($0.preview ?? []).isEmpty }
        drivenTripCount = earlier.count
        // A trip matched to the road network almost entirely is drawn by its driven directions
        // (SPEC 15.2); its raw line would only show GPS jitter beside them. Only once its coverage
        // is loaded, and not while the view holds more driven lines than the budget draws.
        let covered = coverageTruncated ? [] : roads.coveredTripIds
        let lines = earlier
            .filter { ($0.roads?.coverage ?? 0) < Self.matchedEnough || !covered.contains($0.id) }
            .flatMap { trip in (trip.preview ?? []).enumerated().map { k, line in ("\(trip.id.uuidString)-\(k)", line) } }
        // A global vertex budget keeps the layer light with hundreds of trips.
        let total = lines.reduce(0) { $0 + $1.1.count }
        let share = total > Self.drivenVertexBudget ? Double(Self.drivenVertexBudget) / Double(total) : 1
        drivenLines = lines.map { id, line in
            let kept = share < 1 ? TrailGeometry.strided(line, budget: max(2, Int(Double(line.count) * share))) : line
            return DrivenLine(id: id, coordinates: kept.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
    }

    var body: some View {
        MapReader { proxy in mapBody(proxy) }
    }

    /// A tap on a road of the Häufigkeit mode says how often it was driven (SPEC 18.7).
    private func tapped(_ point: CGPoint, _ proxy: MapProxy) {
        guard settings.showDrivenLayer, settings.coverageByFrequency, !heatOverlays.isEmpty,
              let c = proxy.convert(point, from: .local), let mpp = directions.metersPerPoint else { return }
        let hit = RoadCoverage.heatLine(near: LatLon(lat: c.latitude, lon: c.longitude), in: roads.heatLines, maxMeters: 22 * mpp)
        withAnimation(.easeOut(duration: 0.2)) { heatInfo = hit.map { RoadCoverage.heatInfo($0) } }
    }

    private func mapBody(_ proxy: MapProxy) -> some View {
        let fix = engine.live.lastFix
        return Map(position: $position, interactionModes: .all) {
            if showsRoadLayer {
                // Streets with many signals: a faint warm band under everything else.
                ForEach(roadLines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(Theme.Status.warn.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(drivenLines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.Text.ink(0.42), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            // Driven roads of earlier trips by direction (SPEC 15.2): amber 4 pt for one direction,
            // green 6 pt with a dark centre stripe (two lanes) for both, so the two differ in shape
            // too, not only in a hue red-green colour-blind eyes may not separate. Each carriageway
            // of a divided road driven both ways (`paired`) looks like `both`; its arrow keeps its
            // own direction, so the two carriageways together point both ways.
            ForEach(coverageOverlays) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: line.state == .one ? 6 : 8, lineCap: .round, lineJoin: .round))
            }
            ForEach(coverageOverlays) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(line.state == .one ? Theme.Coverage.one(traffic: violet) : Theme.Coverage.both(traffic: violet),
                            style: StrokeStyle(lineWidth: line.state == .one ? 4 : 6, lineCap: .round, lineJoin: .round))
            }
            ForEach(heatOverlays) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: line.width + 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(heatOverlays) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.Coverage.heat[line.bin], style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round))
            }
            ForEach(coverageStripes) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.background.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round))
            }
            // Their marks under the current trail: an earlier direction must not sit on this trip.
            ForEach(coverageMarks) { m in
                MapPolyline(coordinates: m.coordinates)
                    .stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(coverageMarks) { m in
                MapPolyline(coordinates: m.coordinates)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            // A route from Planen (SPEC 18.3), over the coverage layer and under the trail.
            if let route = model.plannedRoute {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Theme.Text.ink(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6]))
                // The waypoints of a discovery route (SPEC 18.5), numbered in order.
                ForEach(Array(route.waypoints.enumerated()), id: \.offset) { k, p in
                    Annotation("", coordinate: p, anchor: .center) {
                        Text("\(k + 1)")
                            .font(Typography.font(11, relativeTo: .caption2))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Text.primary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.surface))
                            .overlay(Circle().strokeBorder(Theme.mapCasing, lineWidth: 1.5))
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(Array(trail.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Theme.accent.opacity(0.28), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(trail.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Theme.mapCasing, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(trail.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Theme.accentLight, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if showsRoadLayer {
                ForEach(roads.layer.pois) { poi in
                    Annotation("", coordinate: .init(latitude: poi.lat, longitude: poi.lon), anchor: .center) {
                        // On the car's road ahead a little stronger, everything else faint.
                        RoadPOIGlyph(kind: poi.kind, size: poi.ahead ? 15 : 12)
                            .opacity(poi.ahead ? 1 : 0.5)
                    }
                    .annotationTitles(.hidden)
                }
            }
            // Marks along the whole current trail, on top of it. Polylines: no counter-rotation, no views.
            ForEach(trailMarks) { m in
                MapPolyline(coordinates: m.coordinates)
                    .stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(trailMarks) { m in
                MapPolyline(coordinates: m.coordinates)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            ForEach(engine.events) { e in
                Annotation(e.tag.label, coordinate: .init(latitude: e.latitude, longitude: e.longitude)) {
                    EventPin(tag: e.tag)
                }
                .annotationTitles(.hidden)
            }
            if let fix {
                if let acc = fix.horizontalAccuracy, acc > 3 {
                    MapCircle(center: fix.coordinate, radius: acc)
                        .foregroundStyle(Theme.accentLight.opacity(0.10))
                        .stroke(Theme.accentLight.opacity(0.35), lineWidth: 1)
                }
                Annotation("Position", coordinate: fix.coordinate, anchor: .center) {
                    PositionPuck(heading: engine.live.heading, camera: camera)
                }
                .annotationTitles(.hidden)
            } else if !engine.isRecording {
                UserAnnotation()
            }
        }
        // Full emphasis: the muted style flattened the roads on the dark map (owner, SPEC 18.1);
        // the traffic layer on request (SPEC 18.2).
        .mapStyle(settings.mapType.mapStyle(traffic: settings.trafficShown, muted: AppEnvironment.mutedMap))
        .mapControls {}
        // The map's safe area is the gap between the HUD parts, so the camera centers the position
        // where it can be seen. The right edge leaves room for the map buttons.
        .safeAreaPadding(EdgeInsets(
            top: max(0, obscuredTopY - mapFrame.minY) + 12,
            leading: 12,
            bottom: obscuredBottomY > 0 ? max(0, mapFrame.maxY - obscuredBottomY) + 12 : 0,
            trailing: 64
        ))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0 }
        .onMapCameraChange(frequency: .continuous) { ctx in
            // Whole degrees are enough for the glyphs and halve the updates.
            let rounded = ctx.camera.heading.rounded()
            if rounded != camera.heading { camera.heading = rounded }
        }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            let metersPerPoint = Self.visibleHeightPerDistance * ctx.camera.distance / max(1, mapFrame.height)
            let zoomedIn = metersPerPoint <= Self.poiMaxMetersPerPoint
            if zoomedIn != poisZoomedIn { poisZoomedIn = zoomedIn }
            directions.center = LatLon(lat: ctx.camera.centerCoordinate.latitude, lon: ctx.camera.centerCoordinate.longitude)
            directions.metersPerPoint = metersPerPoint
            refreshDirections()
            // Without a trip the layer follows the map; with one it follows the car (below).
            if !engine.isRecording { refreshLayer(anchor: ctx.camera.centerCoordinate) }
        }
        .onChange(of: settings.showRoadFeatures) { _, on in
            layerAnchor = nil
            if on, let c = engine.live.lastFix?.coordinate ?? engine.warmFix?.coordinate { refreshLayer(anchor: c) }
        }
        .onChange(of: roads.counts.hasRoadData) { _, has in
            // Road data under the car just arrived: show its symbols without waiting for the next move.
            if has { layerAnchor = nil }
        }
        .onChange(of: roads.layer.manySignalStreets) { _, lines in
            roadLines = lines.enumerated().map { k, line in
                RoadLine(id: k, coordinates: line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in tapped(point, proxy) }
        .overlay(alignment: .top) {
            if let heatInfo {
                Text(heatInfo)
                    .font(Typography.label)
                    .foregroundStyle(Theme.Text.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassSurface(radius: 16)
                    .padding(.top, max(0, obscuredTopY - mapFrame.minY) + 64)
                    .transition(.opacity)
                    .task(id: heatInfo) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation(.easeIn(duration: 0.2)) { self.heatInfo = nil }
                    }
                    .accessibilityIdentifier("heat.info")
            }
        }
        .overlay(alignment: .bottomLeading) {
            // The five bins of the Häufigkeit mode while its lines are on the map (SPEC 18.7).
            if settings.showDrivenLayer && settings.coverageByFrequency && !heatOverlays.isEmpty {
                HeatLegend()
                    .padding(.leading, 16)
                    .padding(.bottom, obscuredBottomY > 0 ? max(0, mapFrame.maxY - obscuredBottomY) + 34 : 50)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // One small line beside MapKit's own legal label whenever the screen shows road data:
            // the symbols, or the counters and the OSM road chip of a trip.
            if showsRoadLayer && !roads.layer.pois.isEmpty || engine.isRecording && roads.counts.hasRoadData {
                OSMAttribution(small: true)
                    .padding(.trailing, 16)
                    .padding(.bottom, obscuredBottomY > 0 ? max(0, mapFrame.maxY - obscuredBottomY) + 14 : 30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onChange(of: position.positionedByUser) { _, byUser in
            if byUser { following = false }
        }
        .onChange(of: engine.live.revision) { _, _ in
            let v = engine.live.lastFix?.speed ?? 0
            smoothedSpeed += (v - smoothedSpeed) * 0.15
            refreshTrail()
            if following { moveCamera(animated: true) }
            if let car = engine.live.lastFix?.coordinate { refreshLayer(anchor: car) }
        }
        .onChange(of: recenterRequest) { _, _ in
            following = true
            lastFollowCamera = nil
            moveCamera(animated: true)
        }
        .onChange(of: settings.courseUp) { _, _ in
            lastFollowCamera = nil
            if following { moveCamera(animated: true) }
        }
        // Keyed on content, not only ids: a just finished trip keeps its id but gains its preview
        // when the index reload lands.
        .onChange(of: Self.drivenKey(model.trips), initial: true) { _, _ in
            rebuildDrivenLines()
        }
        .onChange(of: settings.showDrivenLayer) { _, _ in
            rebuildDrivenLines()
            refreshDirections()
        }
        .onChange(of: settings.coverageByFrequency) { _, _ in refreshDirections() }
        .onChange(of: roads.coverageRevision) { _, _ in refreshDirections() }
        // A trip's raw line is hidden only once its coverage is drawn (SPEC 15.2).
        .onChange(of: roads.coveredTripIds) { _, _ in rebuildDrivenLines() }
        .onChange(of: coverageTruncated) { _, _ in rebuildDrivenLines() }
        .onChange(of: engine.trip?.id) { _, _ in rebuildDrivenLines() }
        .onAppear {
            refreshTrail(force: true)
            if engine.live.lastFix != nil { moveCamera(animated: false) }
        }
    }

    private var showsRoadLayer: Bool { settings.showRoadFeatures && poisZoomedIn }

    /// Rebuilds the POI layer around the anchor (the car, or the map center without a trip) when it
    /// moved 60 m or 5 s passed; the work runs off the main actor in `LiveRoads`.
    private func refreshLayer(anchor: CLLocationCoordinate2D) {
        guard settings.showRoadFeatures else { return }
        if let a = layerAnchor {
            let moved = Geo.distance(lat1: a.center.latitude, lon1: a.center.longitude, lat2: anchor.latitude, lon2: anchor.longitude)
            if moved < 60 && Date().timeIntervalSince(a.at) < 5 { return }
        }
        layerAnchor = (anchor, Date())
        roads.updateLayer(lat: anchor.latitude, lon: anchor.longitude)
    }

    private func refreshTrail(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTrailUpdate) >= 1 else { return }
        lastTrailUpdate = now
        let fixes = engine.fixes
        let d = directions
        // Only fixes added since the last call are walked (SPEC 15.2, 8 h trips).
        if fixes.count < d.runs.consumed {
            d.runs = TrailGeometry.RunBuilder()
            d.markers = [:]
        }
        d.runs.extend(fixes, config: settings.statsConfig)
        let runs = d.runs.all
        let spacing = Self.markSpacingPoints * max(d.step, 0.05)
        let chord = Self.markSizePoints * max(d.step, 0.05)
        if d.markerStep != d.step {
            // A new zoom step: same points, marks at the new spacing.
            d.markers = d.markers.mapValues { old in
                var m = TrailGeometry.Marker(spacing: spacing, chord: chord)
                m.extend(old.points)
                return m
            }
            d.markerStep = d.step
        }
        let total = max(1, runs.reduce(0) { $0 + $1.count })
        var lines: [[CLLocationCoordinate2D]] = []
        for (n, run) in runs.enumerated() {
            var m = d.markers[run[0]] ?? TrailGeometry.Marker(spacing: spacing, chord: chord)
            if run.count > m.points.count {
                m.extend(run[m.points.count...].map { LatLon(lat: fixes[$0].latitude, lon: fixes[$0].longitude) })
            }
            d.markers[run[0]] = m
            let isNewest = n == runs.count - 1
            let display = TrailGeometry.decimate(m.points, budget: max(2, 2000 * run.count / total), keepTail: isNewest ? 300 : 0)
            lines.append(display.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
        trail = lines
        refreshTrailMarks()
    }

    /// The view square (center, half size in meters) and its rebuild key: zoom step plus the
    /// center quantized to a third of the half size.
    private func viewSquare() -> (center: LatLon, half: Double, key: ViewKey)? {
        guard let center = directions.center, let mpp = directions.metersPerPoint else { return nil }
        let step = Self.zoomStep(mpp, current: directions.step)
        directions.step = step
        // Half the diagonal (the map may be rotated), plus a quarter for panning.
        let half = 1.25 * 0.5 * Double(hypot(mapFrame.width, mapFrame.height)) * mpp
        let cell = max(1, half / 3)
        let latM = 110_540.0, lonM = max(1, 111_320.0 * cos(center.lat * .pi / 180))
        return (center, half, ViewKey(step: step, x: Int((center.lon * lonM / cell).rounded(.down)),
                                      y: Int((center.lat * latM / cell).rounded(.down))))
    }

    static func inSquare(_ p: LatLon, center: LatLon, half: Double) -> Bool {
        let dLat = abs(p.lat - center.lat) * 110_540
        let dLon = abs(p.lon - center.lon) * 111_320 * cos(center.lat * .pi / 180)
        return dLat <= half && dLon <= half
    }

    /// Distance in meters from a point to a box (0 inside), flat approximation.
    static func distance(_ p: LatLon, to b: BBox) -> Double {
        let lat = min(max(p.lat, b.south), b.north), lon = min(max(p.lon, b.west), b.east)
        return hypot((p.lat - lat) * 110_540, (p.lon - lon) * 111_320 * cos(p.lat * .pi / 180))
    }

    /// Rebuilds the direction layers when the view key, the coverage or the trail changed (SPEC
    /// 15.2). Every change re-sends the overlays to MapKit, so nothing is set that did not change.
    private func refreshDirections() {
        refreshCoverage()
        refreshTrailMarks()
    }

    private func refreshCoverage() {
        guard let view = viewSquare() else { return }
        let d = directions
        guard settings.showDrivenLayer else {
            if !coverageOverlays.isEmpty { coverageOverlays = [] }
            if !coverageStripes.isEmpty { coverageStripes = [] }
            if !coverageMarks.isEmpty { coverageMarks = [] }
            if !heatOverlays.isEmpty { heatOverlays = [] }
            d.lineIds = []
            d.stripeIds = []
            d.coverageArrowIds = []
            d.coverageKey = nil
            return
        }
        let frequency = settings.coverageByFrequency
        guard view.key != d.coverageKey || roads.coverageRevision != d.coverageRevision || frequency != d.frequency else { return }
        if frequency != d.frequency {
            d.frequency = frequency
            d.lineIds = []
            d.stripeIds = []
            d.coverageArrowIds = []
        }
        d.coverageKey = view.key
        d.coverageRevision = roads.coverageRevision
        // Lines whose box meets the view square, nearest to the real view center first.
        let square = BBox(south: view.center.lat - view.half / 110_540, west: view.center.lon - view.half / max(1, 111_320 * cos(view.center.lat * .pi / 180)),
                          north: view.center.lat + view.half / 110_540, east: view.center.lon + view.half / max(1, 111_320 * cos(view.center.lat * .pi / 180)))
        if frequency {
            // Häufigkeit replaces the direction encoding, and only that (SPEC 18.7).
            if !coverageOverlays.isEmpty { coverageOverlays = [] }
            if !coverageStripes.isEmpty { coverageStripes = [] }
            if !coverageMarks.isEmpty { coverageMarks = [] }
            let heat = roads.heatLines.filter {
                $0.box.north >= square.south && $0.box.south <= square.north && $0.box.east >= square.west && $0.box.west <= square.east
            }
            let ranked = heat.map { ($0, Self.distance(view.center, to: $0.box)) }.sorted { $0.1 < $1.1 }.map(\.0)
            let kept = Array(ranked.prefix(Self.maxCoverageLines))
            if (ranked.count > kept.count) != coverageTruncated { coverageTruncated = ranked.count > kept.count }
            // Lighter bins first, so the most driven roads sit on top where lines meet.
            let sorted = kept.sorted { ($0.bin, $0.id) < ($1.bin, $1.id) }
            let ids = sorted.map { "\($0.id)#\($0.bin)" }
            if ids != d.lineIds {
                d.lineIds = ids
                heatOverlays = sorted.map { line in
                    HeatOverlay(id: line.id, coordinates: line.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }, bin: line.bin)
                }
            }
            return
        }
        if !heatOverlays.isEmpty { heatOverlays = [] }
        let inView = roads.coverageLines.filter {
            $0.box.north >= square.south && $0.box.south <= square.north && $0.box.east >= square.west && $0.box.west <= square.east
        }
        let ranked = inView.map { ($0, Self.distance(view.center, to: $0.box)) }.sorted { $0.1 < $1.1 }.map(\.0)
        let lines = Array(ranked.prefix(Self.maxCoverageLines))
        let truncated = ranked.count > lines.count
        if truncated != coverageTruncated { coverageTruncated = truncated }
        let sortedLines = lines.sorted { $0.id < $1.id }
        let ids = sortedLines.map(\.id)
        if ids != d.lineIds {
            d.lineIds = ids
            let overlays = sortedLines.map { line in
                CoverageOverlay(id: line.id, coordinates: line.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                                state: line.state)
            }
            coverageOverlays = overlays
            let stripes = overlays.filter { $0.state != .one }
            if stripes.map(\.id) != d.stripeIds {
                d.stripeIds = stripes.map(\.id)
                coverageStripes = stripes
            }
        }
        let step = view.key.step
        let arrows = RoadCoverage.arrows(lines, spacing: Self.markSpacingPoints * step, minLength: Self.minLinePoints * step,
                                         chord: Self.markSizePoints * step, center: view.center, budget: Self.maxCoverageMarks,
                                         separation: Self.markSeparationPoints * step) {
            Self.inSquare($0, center: view.center, half: view.half)
        }
        let arrowIds = arrows.map(\.id)
        if arrowIds != d.coverageArrowIds {
            d.coverageArrowIds = arrowIds
            coverageMarks = Self.markLines(arrows, size: Self.markSizePoints * step)
        }
    }

    private func refreshTrailMarks() {
        guard let view = viewSquare() else { return }
        let d = directions
        let count = d.markers.values.reduce(0) { $0 + $1.marks.count }
        guard view.key != d.trailKey || count != d.markerCount else { return }
        if d.markerStep != view.key.step && !d.markers.isEmpty {
            // The trail's marks follow the new zoom step on the next trail update.
            lastTrailUpdate = .distantPast
            refreshTrail(force: true)
            return
        }
        d.trailKey = view.key
        d.markerCount = count
        var marks: [(RoadCoverage.Arrow, Double)] = []
        for (start, m) in d.markers {
            for (k, mark) in m.marks.enumerated() where Self.inSquare(mark.point, center: view.center, half: view.half) {
                marks.append((RoadCoverage.Arrow(point: mark.point, bearing: mark.bearing, both: false, id: "t\(start)#\(k)"),
                              OSMGeo.haversine(view.center, mark.point)))
            }
        }
        let kept = RoadCoverage.thin(marks.sorted { $0.1 < $1.1 }.map(\.0), separation: Self.markSeparationPoints * view.key.step,
                                     budget: Self.maxTrailMarks, around: view.center).sorted { $0.id < $1.id }
        let ids = kept.map(\.id)
        if ids != d.trailMarkIds {
            d.trailMarkIds = ids
            trailMarks = Self.markLines(kept, size: Self.markSizePoints * view.key.step)
        }
    }

    /// Quarter-octave zoom steps; the current step is kept while the meters per point stay within
    /// a factor 1.2 of it, so a zoom near a boundary does not flip (the follow zoom breathes with
    /// speed) and a mark of 12 pt at the step shows 10 to 14.4 pt on screen.
    static func zoomStep(_ metersPerPoint: Double, current: Double) -> Double {
        let mpp = max(0.05, metersPerPoint)
        if current > 0, mpp >= current / 1.2, mpp <= current * 1.2 { return current }
        return pow(2, (log2(mpp) * 4).rounded() / 4)
    }

    static func markLines(_ arrows: [RoadCoverage.Arrow], size: Double) -> [MarkLine] {
        var out: [MarkLine] = []
        for a in arrows {
            for (k, chevron) in RoadCoverage.chevrons(a, size: size).enumerated() {
                out.append(MarkLine(id: "\(a.id)/\(k)", coordinates: chevron.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }))
            }
        }
        return out
    }

    /// MapKit shows about `0.536 * distance` meters over the full map height at pitch 0
    /// (a 30° vertical field of view), used to turn a wanted span into a camera distance.
    static let visibleHeightPerDistance = 0.536

    /// Meters the visible map gap (between the HUD parts) should span: about 3 km at city speed,
    /// so roughly the last 1.5 to 2 km of trail stay on screen, widening to 6 km at highway speed.
    static func followSpan(speed: Double) -> Double {
        min(6000, max(2200, 2200 + speed * 110))
    }

    private func moveCamera(animated: Bool) {
        guard let fix = engine.live.lastFix else {
            position = .userLocation(fallback: .automatic)
            return
        }
        let mapHeight = max(1, mapFrame.height)
        let gapTop = max(0, obscuredTopY - mapFrame.minY) + 12
        let gapBottom = obscuredBottomY > 0 ? obscuredBottomY - mapFrame.minY - 12 : mapHeight
        let gap = max(160, gapBottom - gapTop)
        let metersPerPoint = Self.followSpan(speed: smoothedSpeed) / gap
        let distance = metersPerPoint * mapHeight / Self.visibleHeightPerDistance
        let travel = engine.live.heading
        let heading = settings.courseUp ? (travel ?? camera.heading) : 0
        // Course up: aim 7 % of the gap ahead of the car, so the arrow sits slightly below the
        // middle and about 43 % of the visible map shows the trail behind it.
        var center = fix.coordinate
        if settings.courseUp, let travel {
            let ahead = Geo.destination(lat: fix.latitude, lon: fix.longitude, bearing: travel, distance: 0.07 * gap * metersPerPoint)
            center = CLLocationCoordinate2D(latitude: ahead.lat, longitude: ahead.lon)
        }
        let camera = MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: 0)
        let visible = lastFollowCamera.map {
            Self.isVisibleStep(from: $0, to: camera, metersPerPoint: metersPerPoint, radiusPoints: max(gap, mapFrame.width) / 2)
        } ?? true
        lastFollowCamera = camera
        if animated && !reduceMotion && visible {
            withAnimation(.easeInOut(duration: 0.9)) { position = .camera(camera) }
        } else {
            position = .camera(camera)
        }
    }

    /// True when the step from one follow camera to the next would move some point of the visible
    /// map by `animateFromPoints` or more: the shift of the center, plus what a turn or a zoom
    /// change does at `radiusPoints` from the center (the edge of the visible gap).
    static func isVisibleStep(from a: MapCamera, to b: MapCamera, metersPerPoint: Double, radiusPoints: Double) -> Bool {
        let moved = Geo.distance(lat1: a.centerCoordinate.latitude, lon1: a.centerCoordinate.longitude,
                                 lat2: b.centerCoordinate.latitude, lon2: b.centerCoordinate.longitude)
        let turned = abs((b.heading - a.heading + 540).truncatingRemainder(dividingBy: 360) - 180)
        let zoomed = abs(b.distance / max(1, a.distance) - 1)
        let points = moved / max(0.01, metersPerPoint) + (turned * .pi / 180 + zoomed) * radiusPoints
        return points >= animateFromPoints
    }
}

/// The map camera heading, observed only by the views that rotate with it.
@Observable
final class CameraHeading {
    var heading: Double = 0
}

/// The position arrow: white arrowhead on an accent disc, rotated to the course.
struct PositionPuck: View {
    var heading: Double?
    var camera: CameraHeading
    private var hasHeading: Bool { heading != nil }
    private var rotation: Double { (heading ?? 0) - camera.heading }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            if hasHeading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(rotation))
            } else {
                Circle().fill(.white).frame(width: 10, height: 10)
            }
        }
        .accessibilityLabel("Aktuelle Position")
    }
}

struct EventPin: View {
    var tag: TripEvent.Tag

    var body: some View {
        Image(systemName: tag.symbol)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color(red: 0.12, green: 0.14, blue: 0.18)))
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
            .accessibilityLabel(tag.label)
    }
}
