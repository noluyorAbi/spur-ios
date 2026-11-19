import Foundation

/// The map and app style (SPEC 18.1): "Kartenstil" Automatisch, Hell or Dunkel.
nonisolated enum MapStyleChoice: String, CaseIterable, Sendable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatisch"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }
}

/// The map type (SPEC 18.2b): "Kartentyp" Standard, Satellit or Hybrid (satellite with roads and
/// names). Kartenstil only changes Standard.
nonisolated enum MapTypeChoice: String, CaseIterable, Sendable, Identifiable {
    case standard, satellite, hybrid
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellit"
        case .hybrid: return "Hybrid"
        }
    }

    /// Satellite imagery under the map: what floats over it uses the dark glass, and the driven
    /// roads use the violet family (amber and green vanish on vegetation and roofs).
    var isImagery: Bool { self != .standard }
    /// MapKit draws traffic on Standard and Hybrid, not on plain imagery.
    var showsTraffic: Bool { self != .satellite }
}

/// Light by day, dark by night, decided by the sun at the position (pure, tested). A switch needs
/// the sun to cross a band around the horizon (the standard sunrise and sunset altitude of
/// -0.833° plus or minus `band`), so dusk never flips the style back and forth.
nonisolated enum AppearanceRule {
    /// The style is light (true) or dark (false).
    static let horizon = -0.833
    static let band = 0.8

    /// The style for a choice; `automatic` keeps `current` until the sun leaves the band.
    static func isLight(choice: MapStyleChoice, sunElevation: Double?, current: Bool) -> Bool {
        switch choice {
        case .light: return true
        case .dark: return false
        case .automatic:
            guard let e = sunElevation else { return current }
            if e >= horizon + band { return true }
            if e <= horizon - band { return false }
            return current
        }
    }

    /// The first decision without history: the sun's side of the horizon.
    static func initial(choice: MapStyleChoice, sunElevation: Double?) -> Bool {
        switch choice {
        case .light: return true
        case .dark: return false
        case .automatic: return (sunElevation ?? -90) >= horizon
        }
    }
}
