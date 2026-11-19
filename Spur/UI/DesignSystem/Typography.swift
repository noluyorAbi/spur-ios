import SwiftUI
import UIKit

/// The one place that knows the UI typeface.
///
/// Only the Regular weight of the typeface exists, so hierarchy comes from size, case,
/// tracking and opacity, never from a synthesized bold. When the font file is missing
/// (a fresh clone without `scripts/install-font.sh`), every style falls back to the system font.
enum Typography {
    /// PostScript name of the bundled typeface (shared with the widget extension), if any.
    static let customFontName = SpurFont.postScriptName ?? ""

    /// True when a bundled typeface registered at launch.
    static let isCustomFontAvailable: Bool = SpurFont.postScriptName != nil

    /// A font of the given point size, scaled with Dynamic Type relative to `textStyle`.
    static func font(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        if isCustomFontAvailable {
            return .custom(customFontName, size: size, relativeTo: textStyle)
        }
        return .system(size: size, weight: .regular, design: .default)
    }

    /// A fixed size font (no Dynamic Type scaling), for the large live numerals.
    static func fixed(_ size: CGFloat) -> Font {
        if isCustomFontAvailable {
            return .custom(customFontName, fixedSize: size)
        }
        return .system(size: size, weight: .regular, design: .default)
    }

    static func uiFont(_ size: CGFloat) -> UIFont {
        UIFont(name: customFontName, size: size) ?? .systemFont(ofSize: size)
    }

    // Named styles.
    static let display = fixed(84)
    static let numeralLarge = font(34, relativeTo: .largeTitle)
    static let numeral = font(24, relativeTo: .title2)
    static let title = font(28, relativeTo: .title)
    static let headline = font(19, relativeTo: .headline)
    static let body = font(16, relativeTo: .body)
    static let callout = font(14, relativeTo: .callout)
    static let caption = font(12, relativeTo: .caption)
    static let label = font(11, relativeTo: .caption2)
}

extension View {
    /// Small uppercase label with generous tracking, the signature of the design language.
    func eyebrow(_ opacity: Double = Theme.Text.secondaryOpacity) -> some View {
        self.font(Typography.label)
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Theme.Text.ink(opacity))
    }
}
