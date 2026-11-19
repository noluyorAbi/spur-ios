import MapKit
import SwiftUI

/// One place that turns the settings into MapKit's style (SPEC 18.1, 18.2, 18.2b), so the live map,
/// the trip map and the plan views agree.
extension MapTypeChoice {
    func mapStyle(traffic: Bool, muted: Bool = false) -> MapStyle {
        switch self {
        case .standard:
            return .standard(elevation: .flat, emphasis: muted ? .muted : .automatic, pointsOfInterest: .excludingAll, showsTraffic: traffic)
        case .satellite:
            return .imagery(elevation: .flat)
        case .hybrid:
            return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: traffic)
        }
    }
}

/// On satellite imagery everything that floats over the map takes the dark glass and the night
/// inks, whatever Kartenstil says (SPEC 18.2b); on Standard nothing changes.
struct FloatsOverMap: ViewModifier {
    var mapType: MapTypeChoice

    func body(content: Content) -> some View {
        if mapType.isImagery {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

extension View {
    func floatsOverMap(_ mapType: MapTypeChoice) -> some View { modifier(FloatsOverMap(mapType: mapType)) }
}

/// The map's layer menu behind the same glass circle as the other map buttons: Kartentyp (SPEC
/// 18.2b) and how the driven roads read, by direction or by how often (SPEC 18.7).
struct MapTypeButton: View {
    @Bindable var settings: Settings

    var body: some View {
        Menu {
            Picker("Kartentyp", selection: $settings.mapType) {
                ForEach(MapTypeChoice.allCases) { Text($0.label).tag($0) }
            }
            Picker("Abdeckung", selection: $settings.coverageByFrequency) {
                Text("Richtung").tag(false)
                Text("Häufigkeit").tag(true)
            }
        } label: {
            Image(systemName: settings.mapType == .standard ? "map" : "globe.europe.africa.fill")
                .font(.system(size: 17))
                .foregroundStyle(settings.mapType == .standard ? Theme.Text.primary : Theme.accentLight)
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.button)
        .buttonStyle(GlassCircleButtonStyle())
        .sensoryFeedback(.selection, trigger: settings.mapType)
        .accessibilityLabel("Kartentyp")
        .accessibilityValue("\(settings.mapType.label), Abdeckung \(settings.coverageByFrequency ? "Häufigkeit" : "Richtung")")
        .accessibilityIdentifier("layer.mapType")
    }
}

/// The five bins of the Häufigkeit mode (SPEC 18.7), small enough to sit over the map.
struct HeatLegend: View {
    static let labels = ["1×", "2×", "3-4×", "5-9×", "10×+"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { k in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(Theme.Coverage.heat[k])
                        .overlay(Capsule().strokeBorder(Theme.mapCasing, lineWidth: 1))
                        .frame(width: 22, height: k >= 3 ? 7 : 6)
                    Text(Self.labels[k])
                        .font(Typography.font(10, relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(radius: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Häufigkeit: hell einmal gefahren, dunkler öfter, bis zehnmal und mehr")
        .accessibilityIdentifier("legend.heat")
    }
}
