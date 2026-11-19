import SwiftUI

// MARK: - Road type colors

extension RoadClass {
    /// Three calm tones that read on dark and stay apart for color-blind users: a warm sand, a
    /// mid teal and a light blue differ in hue along the blue-yellow axis (kept by red-green color
    /// blindness) and in lightness (teal is clearly darker than the other two). On the light map
    /// deeper shades of the same three, each at least 3:1 against it (SPEC 18.1).
    var color: Color {
        switch self {
        case .stadt: Theme.adaptive(light: Theme.rgb(0xA07A35), dark: UIColor(red: 0.85, green: 0.76, blue: 0.56, alpha: 1))
        case .land: Theme.adaptive(light: Theme.rgb(0x165E58), dark: Theme.rgb(0x5CBDB1))
        case .autobahn: Theme.adaptive(light: Theme.rgb(0x3474C2), dark: UIColor(red: 0.62, green: 0.80, blue: 0.97, alpha: 1))
        }
    }
}

// MARK: - Surfaces

/// A glass surface over the map (iOS 26 Liquid Glass), with a dark tint for contrast in sunlight.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(Theme.glassTint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// An opaque card for scrolling screens (history, detail, settings).
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

extension View {
    func glassSurface(radius: CGFloat = Theme.Radius.card) -> some View { modifier(GlassSurface(radius: radius)) }
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View { modifier(CardSurface(radius: radius)) }
}

// MARK: - Metric

/// A labelled number: small uppercase label, large numeral, unit at reduced opacity.
struct Metric: View {
    var label: String
    var value: String
    var unit: String?
    var size: CGFloat = 24
    var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).eyebrow()
                if let info { InfoButton(title: label, text: info) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Typography.font(size, relativeTo: .title2))
                    .foregroundStyle(Theme.Text.primary)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Info affordance

/// The "i" next to a metric: shows the exact definition in a small popover.
struct InfoButton: View {
    var title: String
    var text: String
    @State private var shown = false

    var body: some View {
        Button {
            shown = true
        } label: {
            // A 16 pt glyph in the label row; the hit area grows to 48 pt without moving the layout.
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 16, height: 16)
                .padding(16)
                .contentShape(Rectangle())
                .padding(-16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Definition \(title)")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).eyebrow()
                Text(text)
                    .font(Typography.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Theme.surfaceRaised)
        }
    }
}

// MARK: - Road type bar

/// A thin stacked bar of the road-type shares.
struct RoadShareBar: View {
    var stats: RoadTypeStats?
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                if let stats, stats.classifiedDistance > 0 {
                    ForEach(RoadClass.allCases) { c in
                        let share = stats.distanceShare(c)
                        if share > 0 {
                            Capsule().fill(c.color).frame(width: max(2, (geo.size.width - 3) * share))
                        }
                    }
                } else {
                    Capsule().fill(Theme.Text.ink(0.12))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

struct RoadLegend: View {
    var stats: RoadTypeStats
    var units: UnitSystem
    /// Adds "geschätzt" with the rule behind an info button.
    var estimated = false

    static let rule = "Offline aus dem Geschwindigkeitsprofil geschätzt, ohne Kartenabgleich: gleitendes Fenster der letzten 60 s, Median der bewegten Positionen. Autobahn ab 85 km/h, Land 50 bis 85 km/h, Stadt unter 50 km/h oder mehr als 2 Stopps je km im Fenster (ab 250 m Fensterstrecke). Eine neue Klasse muss 30 s halten, bevor sie die alte ablöst."

    var body: some View {
        // Whole percentages that add up to 100.
        let percents = Format.wholePercents(RoadClass.allCases.map { stats[$0].distance })
        VStack(alignment: .leading, spacing: 4) {
            if estimated {
                HStack(spacing: 4) {
                    Text("Streckenart (geschätzt)").eyebrow()
                    InfoButton(title: "Streckenart (geschätzt)", text: Self.rule)
                }
            }
            HStack(spacing: Theme.Space.m) {
                ForEach(Array(RoadClass.allCases.enumerated()), id: \.offset) { k, c in
                    HStack(spacing: 6) {
                        Circle().fill(c.color).frame(width: 8, height: 8)
                        Text("\(c.label) \(percents[k]) %")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Banner

struct Banner: View {
    enum Tone { case info, warn, bad }
    var tone: Tone
    var symbol: String
    var text: String
    var action: (label: String, run: () -> Void)?
    var onClose: (() -> Void)?

    private var tint: Color {
        switch tone {
        case .info: Theme.accentLight
        case .warn: Theme.Status.warn
        case .bad: Theme.Status.bad
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
            Text(text)
                .font(Typography.callout)
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action: action.run) {
                    Text(action.label)
                        .font(Typography.callout)
                        .foregroundStyle(tint)
                        .padding(.horizontal, Theme.Space.xs)
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            if let onClose {
                Button(action: onClose) {
                    // The whole 48 pt square takes the touch, not only the 12 pt cross.
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Schließen")
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, onClose == nil && action == nil ? Theme.Space.m : Theme.Space.xxs)
        .frame(minHeight: Theme.touchTarget)
        .glassSurface(radius: Theme.Radius.small + 6)
    }
}

// MARK: - Section header

struct SectionTitle: View {
    var title: String
    var info: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Theme.Text.primary)
            if let info { InfoButton(title: title, text: info) }
            Spacer()
        }
    }
}

// MARK: - Buttons

/// Press timing: in fast (100 ms), out a little slower (220 ms), so a press reads at once and the
/// release settles calmly.
enum PressMotion {
    static let press = Animation.spring(duration: 0.10, bounce: 0)
    static let release = Animation.spring(duration: 0.22, bounce: 0.15)
    static func animation(_ pressed: Bool) -> Animation { pressed ? press : release }
}

/// Press feedback for large buttons: a slight scale (none with Reduce Motion) and a dim.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(PressMotion.animation(configuration.isPressed), value: configuration.isPressed)
    }
}

/// A round glass button: the whole circle takes the touch, and the whole circle answers it (it
/// shrinks to 0.9 and lights up; with Reduce Motion only the light). 0.97 would move a 48 pt
/// circle by about 1 pt, which nobody sees.
struct GlassCircleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            .background(Circle().fill(Theme.Text.ink(configuration.isPressed ? 0.16 : 0)))
            .contentShape(Circle())
            .glassEffect(.regular.tint(Theme.glassTint), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(PressMotion.animation(configuration.isPressed), value: configuration.isPressed)
    }
}

/// Round icon button on glass, 48 pt, with a selection tick on every tap.
struct MapIconButton: View {
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(active ? Theme.accentLight : Theme.Text.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(GlassCircleButtonStyle())
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityLabel(label)
    }
}
