import SwiftUI
import UIKit

/// Colors, spacing, radii and motion of the design language (SPEC section 8).
enum Theme {
    // MARK: Color

    /// A token with a light and a dark value (SPEC 18.1: the whole app follows "Kartenstil").
    /// The provider is nonisolated: MapKit resolves overlay colours on its render thread, and a
    /// main-actor closure there traps the isolation check (crash in ui-flow, 2026-11-13).
    nonisolated static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor(dynamicProvider: { @Sendable trait in trait.userInterfaceStyle == .light ? light : dark }))
    }

    nonisolated static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Near-black background; a cool light grey by day.
    static let background = adaptive(light: rgb(0xF2F4F7), dark: rgb(0x0A0C0F))
    /// Slightly lifted surface for grouped content.
    static let surface = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x13161B))
    static let surfaceRaised = adaptive(light: rgb(0xF7F8FA), dark: rgb(0x1A1E24))
    /// The one accent: trail, primary buttons, selection.
    static let accent = Color(uiColor: rgb(0x1C69D4))
    /// The accent for text and highlights: lighter on dark, deeper on light (at least 4.5:1).
    static let accentLight = adaptive(light: rgb(0x1A5FC0), dark: rgb(0x6FA8FF))
    /// The tint of the glass over the map: dark at night, light by day, for contrast in sunlight
    /// either way (the HUD follows the map's style, SPEC 18.1).
    static let glassTint = adaptive(light: UIColor.white.withAlphaComponent(0.55), dark: UIColor.black.withAlphaComponent(0.35))
    /// The casing under lines drawn on the map (trail, driven roads, trip colours): 1 pt each side,
    /// so a line keeps 3:1 against parks and major roads too, where its fill alone does not
    /// (SPEC 18.1, docs/contrast-1.4.md).
    static let mapCasing = adaptive(light: rgb(0x3A3D42), dark: rgb(0x0A0C0F))
    /// A halo for small text straight on the map.
    static let mapHalo = adaptive(light: UIColor.white.withAlphaComponent(0.8), dark: UIColor.black.withAlphaComponent(0.6))
    static let hairline = adaptive(light: UIColor.black.withAlphaComponent(0.10), dark: UIColor.white.withAlphaComponent(0.10))

    enum Text {
        static let primaryOpacity = 0.92
        static let secondaryOpacity = 0.60
        static let tertiaryOpacity = 0.46
        /// Text ink: white on dark, near-black on light. Every level keeps 4.5:1 on background,
        /// surface and raised surface (measured in docs/contrast-1.4.md).
        static let primary = ink(primaryOpacity, light: 0.92)
        static let secondary = ink(secondaryOpacity, light: 0.68)
        static let tertiary = ink(tertiaryOpacity, light: 0.58)

        static func ink(_ dark: Double, light: Double) -> Color {
            Theme.adaptive(light: Theme.rgb(0x0B0D10, CGFloat(light)), dark: UIColor.white.withAlphaComponent(CGFloat(dark)))
        }

        /// Ink at an opacity (the eyebrow style takes one).
        static func ink(_ opacity: Double) -> Color { ink(opacity, light: min(1, opacity + 0.05)) }
    }

    /// Status colors, only for status; deeper on light for contrast.
    enum Status {
        static let good = Theme.adaptive(light: Theme.rgb(0x157443), dark: UIColor(red: 0.30, green: 0.80, blue: 0.52, alpha: 1))
        static let warn = Theme.adaptive(light: Theme.rgb(0x935500), dark: UIColor(red: 0.98, green: 0.72, blue: 0.24, alpha: 1))
        static let bad = Theme.adaptive(light: Theme.rgb(0xC8312C), dark: UIColor(red: 0.96, green: 0.36, blue: 0.33, alpha: 1))
        static let idle = Text.tertiary
    }

    // MARK: Spacing (8 pt grid, 4 pt half steps)

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 22
        static let sheet: CGFloat = 28
    }

    /// Minimum touch target, and the primary control size.
    static let touchTarget: CGFloat = 48
    static let primaryControl: CGFloat = 76

    /// Driven directions on the map (SPEC 15.2): amber for one direction (the parent's), green for
    /// both (the parent's blue would sit next to the trail's accent blue).
    /// On the light map deeper shades, at least 3:1 against its roads (SPEC 18.1).
    enum Coverage {
        static let one = Theme.adaptive(light: Theme.rgb(0xC27400), dark: Theme.rgb(0xFFB224))
        static let both = Theme.adaptive(light: Theme.rgb(0x15884F), dark: Theme.rgb(0x3DD68C))
        /// While the traffic layer is on (SPEC 18.2): a violet family, no hue traffic uses; the
        /// shapes (one direction plain, both with the centre stripe) stay.
        static let oneTraffic = Theme.adaptive(light: Theme.rgb(0x6B43D6), dark: Theme.rgb(0xB49BFF))
        static let bothTraffic = Theme.adaptive(light: Theme.rgb(0x9A2E8F), dark: Theme.rgb(0xE88AD9))

        static func one(traffic: Bool) -> Color { traffic ? oneTraffic : one }

        /// Häufigkeit (SPEC 18.7): one violet ramp with monotonic lightness, 1, 2, 3 to 4, 5 to 9,
        /// 10 or more. Violet is the one hue nothing else on the map uses in this mode (the trail
        /// and speed are blue, traffic green to red, the direction mode it replaces amber and
        /// green), so it stays the same with traffic on and on imagery. More passes are darker by
        /// day and lighter at night.
        static let heat: [Color] = [
            (0xA68FEE, 0xAB9BF5), (0x8466E0, 0xBDAEF9), (0x6544C9, 0xCFC4FC), (0x4A2CA3, 0xE0D8FE), (0x301870, 0xF2EEFF),
        ].map { Theme.adaptive(light: Theme.rgb($0.0), dark: Theme.rgb($0.1)) }
        static func both(traffic: Bool) -> Color { traffic ? bothTraffic : both }
    }

    // MARK: Motion

    enum Motion {
        /// Default state change: quick, no bounce.
        static let state = Animation.spring(duration: 0.32, bounce: 0)
        /// Small, snappy feedback.
        static let snappy = Animation.spring(duration: 0.22, bounce: 0)
        /// Sheet-like entrance.
        static let enter = Animation.spring(duration: 0.42, bounce: 0.05)

        /// The animation to use, or nil when Reduce Motion is on.
        static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}
