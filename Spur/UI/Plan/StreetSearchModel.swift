import MapKit
import SwiftUI

/// Streets from the road data around the user, for the search in Planen (SPEC 18.11).
@MainActor @Observable
final class StreetSearchModel {
    private(set) var streets: [StreetIndex.Street] = []
    private(set) var loading = false
    /// The street shown on the map with its card.
    var shown: StreetIndex.Street?
    @ObservationIgnored private var loadedAround: LatLon?

    static let radiusM = 6000.0

    /// Loads once per area: again only when the origin moved more than 1.5 km.
    func load(roads: RoadService, origin: LatLon) async {
        if let l = loadedAround, OSMGeo.haversine(l, origin) < 1500 { return }
        loadedAround = origin
        loading = true
        defer { loading = false }
        let data = await roads.scenarioData(around: origin, radiusM: Self.radiusM)
        streets = await Task.detached(priority: .userInitiated) {
            StreetIndex.build(data.segments, origin: origin, driven: ScenarioFinder.drivenLookup(data.edges))
        }.value
    }

    func matches(_ query: String) -> [StreetIndex.Street] {
        StreetIndex.search(streets, query: query, limit: query.isEmpty ? 6 : 4)
    }

    /// "3,2 km, 34 % gefahren · 1,2 km entfernt".
    static func caption(_ s: StreetIndex.Street) -> String {
        let driven = s.drivenM <= 0 ? "noch nie gefahren" : s.undrivenM < StreetIndex.minUndrivenM ? "ganz gefahren" : "\(Int((s.share * 100).rounded())) % gefahren"
        let d = s.undiscovered ? (s.undrivenDistanceM ?? s.distanceM) : s.distanceM
        return "\(km(s.lengthM)), \(driven) · \(km(d)) entfernt"
    }

    static func km(_ m: Double) -> String {
        m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func region(_ s: StreetIndex.Street) -> MKCoordinateRegion {
        let pts = s.lines.flatMap { $0 }
        let lats = pts.map(\.lat), lons = pts.map(\.lon)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (lats.max()! - lats.min()!) * 1.4),
                                    longitudeDelta: max(0.004, (lons.max()! - lons.min()!) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// The street on the map: its length, how much is driven, and the way to the undriven part.
struct StreetCard: View {
    var street: StreetIndex.Street
    var go: (LatLon, String) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top) {
                Text(street.name).font(Typography.headline).foregroundStyle(Theme.Text.primary)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Text.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Straße schließen")
            }
            Text(summary)
                .font(Typography.body).monospacedDigit().foregroundStyle(Theme.Text.primary)
                .accessibilityIdentifier("street.card")
            // The legend only when both kinds are on the map.
            if street.drivenM > 0 && street.undiscovered {
                HStack(spacing: Theme.Space.m) {
                    legend(Theme.accentLight, "gefahren")
                    legend(Theme.Status.warn, "unbefahren")
                }
            }
            Button {
                if let u = street.nearestUndriven { go(u, "\(street.name), unbefahrener Teil") }
                else { go(street.nearest, street.name) }
            } label: {
                Label(street.nearestUndriven != nil ? "Zum unbefahrenen Teil" : "Hinfahren", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(Typography.font(17, relativeTo: .headline))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("street.go")
        }
        .padding(Theme.Space.l)
        .glassSurface()
    }

    private var summary: String {
        let km = StreetSearchModel.km
        if street.drivenM <= 0 { return "\(km(street.lengthM)) lang, noch nie gefahren" }
        if !street.undiscovered { return "\(km(street.lengthM)) lang, ganz gefahren" }
        return "\(km(street.lengthM)) lang, \(km(street.drivenM)) gefahren (\(Int((street.share * 100).rounded())) %), \(km(street.undrivenM)) offen"
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 18, height: 4)
            Text(text).font(Typography.caption).foregroundStyle(Theme.Text.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
