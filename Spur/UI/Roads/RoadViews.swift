import SwiftUI

// Shared views for the road data of version 1.1 (SPEC 14.6). Road data © OpenStreetMap
// contributors, ODbL.

extension RoadCategory {
    /// German UI label. The US road classes keep their US names: that is what the signs say.
    var label: String {
        switch self {
        case .interstate: "Interstate"
        case .freeway: "Freeway"
        case .tollway: "Tollway (Maut)"
        case .highway: "Highway"
        case .expressway: "Expressway"
        case .ramp: "Auf- und Abfahrt"
        case .frontage: "Frontage Road"
        case .arterial: "Hauptstraße"
        case .local: "Nebenstraße"
        }
    }
}

enum OSMText {
    /// The attribution OpenStreetMap's licence asks for, on every screen that shows road data.
    static let attribution = "Straßendaten © OpenStreetMap-Mitwirkende (ODbL)"
}

/// The attribution line, small and calm. `small` is the map variant: one 9 pt line in the
/// style of MapKit's own legal label, beside it.
struct OSMAttribution: View {
    var small = false

    var body: some View {
        Text(OSMText.attribution)
            .font(small ? .system(size: 9, weight: .medium) : Typography.label)
            // Over the map: ink with a halo of the opposite tone, on either map style (SPEC 18.1).
            .foregroundStyle(small ? Theme.Text.secondary : Theme.Text.tertiary)
            .shadow(color: small ? Theme.mapHalo : .clear, radius: 1.5)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Straßendaten von OpenStreetMap-Mitwirkenden, Lizenz ODbL")
    }
}

/// A stop sign's outline.
struct Octagon: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        for k in 0..<8 {
            let a = (Double(k) * 45 + 22.5) * .pi / 180
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// The small map symbols of the POI layer: calm dark discs with a white glyph. A signal is a
/// three-lamp housing, a stop sign a muted red octagon (with a white ring for an all-way stop), a
/// skewed junction a forked arrow in the light accent.
struct RoadPOIGlyph: View {
    var kind: RoadPOI.Kind
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.09, green: 0.11, blue: 0.14).opacity(0.92))
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .signal:
            VStack(spacing: size * 0.06) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.88)).frame(width: size * 0.15, height: size * 0.15)
                }
            }
            .padding(.vertical, size * 0.07)
            .padding(.horizontal, size * 0.06)
            .background(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.8))
        case .stop(let allWay):
            Octagon()
                .fill(Color(red: 0.78, green: 0.30, blue: 0.28))
                .overlay(Octagon().stroke(.white.opacity(allWay ? 0.95 : 0.6), lineWidth: allWay ? 1.6 : 0.8))
                .frame(width: size * 0.56, height: size * 0.56)
        case .skewed:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Theme.accentLight.opacity(0.85))
        }
    }

    private var label: String {
        switch kind {
        case .signal: "Ampel"
        case .stop(let allWay): allWay ? "Stoppschild, Allwege-Stopp" : "Stoppschild"
        case .skewed: "Schräge Kreuzung"
        }
    }
}

extension PassedFeature {
    /// The map symbol for a passed feature, nil for kinds the map does not show.
    var poiKind: RoadPOI.Kind? {
        switch type {
        case .trafficSignals: return applies ? .signal : nil
        case .stop: return applies ? .stop(allWay: allWay == true) : nil
        default: return skewed == true ? .skewed : nil
        }
    }
}

/// The live counters line: "7 Ampeln · 2 Stopp · 1 schräg".
enum RoadCountText {
    static func live(_ c: LiveRoadCounts) -> String {
        "\(c.signalSites) \(c.signalSites == 1 ? "Ampel" : "Ampeln") · \(c.stopSigns) Stopp · \(c.skewedJunctions) schräg"
    }
}
