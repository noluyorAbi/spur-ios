import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// The widget extension: only the Live Activity of a recording trip (SPEC 16.4).
@main
struct SpurWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpurTripActivity()
    }
}

/// The app's palette (the same values as `Theme`), dark only.
enum Palette {
    static let background = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0F / 255)
    static let accent = Color(red: 0x1C / 255, green: 0x69 / 255, blue: 0xD4 / 255)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.60)
    static let tertiary = Color.white.opacity(0.40)
    static let good = Color(red: 0.30, green: 0.80, blue: 0.52)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let bad = Color(red: 0.96, green: 0.36, blue: 0.33)
    static let ring = Color(red: 0.80, green: 0.10, blue: 0.12)
}

/// The UI typeface when it is bundled, else the system font (the extension must build and run
/// without the gitignored font file).
enum WidgetType {
    static let hasCustomFont = SpurFont.postScriptName != nil

    static func font(_ size: CGFloat) -> Font {
        SpurFont.postScriptName.map { .custom($0, fixedSize: size) } ?? .system(size: size, weight: .regular)
    }
}

struct SpurTripActivity: Widget {
    static let url = URL(string: "spur://fahrt")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpurActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.primary)
                .widgetURL(Self.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Labeled(label: "Zeit") { Elapsed(context: context, size: 24) }
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Labeled(label: "Strecke", alignment: .trailing) {
                        Measure(value: distance(context.state), unit: SpurActivityText.distanceUnit(metric: context.state.metric), size: 24)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(context: context)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    StatusDot(context: context, size: 7)
                    Elapsed(context: context, size: 14)
                        .frame(maxWidth: 58, alignment: .leading)
                }
                .padding(.leading, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpurActivityText.spoken(context.state, stale: context.isStale))
            } compactTrailing: {
                Measure(value: distance(context.state), unit: SpurActivityText.distanceUnit(metric: context.state.metric), size: 14)
                    .padding(.trailing, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Strecke \(distance(context.state)) \(SpurActivityText.distanceUnit(metric: context.state.metric))")
            } minimal: {
                StatusDot(context: context, size: 9)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(SpurActivityText.spoken(context.state, stale: context.isStale))
            }
            .widgetURL(Self.url)
            .keylineTint(Palette.accent)
        }
    }
}

private func distance(_ s: SpurActivityAttributes.ContentState) -> String {
    SpurActivityText.distance(s.distanceMeters, metric: s.metric)
}

/// The status as a mark, not by colour alone: a red dot while recording, a crossed-out arrow in a
/// signal gap, a pause sign while access is missing, a grey dot when ended or stale.
struct StatusDot: View {
    var context: ActivityViewContext<SpurActivityAttributes>
    var size: CGFloat

    var body: some View {
        Group {
            switch (context.isStale, context.state.status) {
            case (false, .gap):
                Image(systemName: "location.slash.fill").font(.system(size: size * 1.3, weight: .semibold))
            case (false, .paused), (false, .userPaused), (false, .pausedDriving), (false, .autoPaused):
                Image(systemName: "pause.fill").font(.system(size: size * 1.2, weight: .semibold))
            default:
                Circle().frame(width: size, height: size)
            }
        }
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }

    private var color: Color {
        if context.isStale || context.state.status == .ended { return Palette.tertiary }
        switch context.state.status {
        case .gap, .paused, .pausedDriving: return Palette.warn
        case .userPaused, .autoPaused: return Palette.tertiary
        default: return Palette.bad
        }
    }
}

/// Elapsed time, ticking without updates (`Text(timerInterval:)`); the fixed duration once ended.
struct Elapsed: View {
    var context: ActivityViewContext<SpurActivityAttributes>
    var size: CGFloat

    var body: some View {
        Group {
            if let end = context.state.endedAt {
                Text(SpurActivityText.duration(end.timeIntervalSince(context.attributes.startedAt)))
            } else {
                // Past the 8 h system cap, so the timer never stops early. Stale (the app was
                // killed), it stops at the last update instead of reading as still recording.
                Text(timerInterval: context.attributes.startedAt...context.attributes.startedAt.addingTimeInterval(12 * 3600),
                     pauseTime: context.isStale ? (context.state.updatedAt ?? Date()) : nil,
                     countsDown: false)
            }
        }
        .font(WidgetType.font(size))
        .monospacedDigit()
        .foregroundStyle(context.isStale ? Palette.tertiary : Palette.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A number with its unit, the unit smaller and dimmer.
struct Measure: View {
    var value: String
    var unit: String
    var size: CGFloat
    var dim = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(WidgetType.font(size))
                .monospacedDigit()
                .foregroundStyle(dim ? Palette.tertiary : Palette.primary)
            Text(unit)
                .font(WidgetType.font(max(10, size * 0.5)))
                .foregroundStyle(Palette.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct Labeled<Content: View>: View {
    var label: String
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label.uppercased())
                .font(WidgetType.font(10))
                .tracking(0.8)
                .foregroundStyle(Palette.tertiary)
            content
        }
    }
}

/// "± 4 m" with a quality dot, as the HUD's GPS chip.
struct GPSChip: View {
    var accuracy: Double?
    var stale: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(SpurActivityText.accuracy(accuracy))
                .font(WidgetType.font(12))
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPS-Genauigkeit \(SpurActivityText.accuracy(accuracy))")
    }

    private var color: Color {
        if stale { return Palette.tertiary }
        switch SpurActivityText.quality(accuracy) {
        case .good: return Palette.good
        case .fair: return Palette.warn
        case .poor: return Palette.bad
        case .none: return Palette.tertiary
        }
    }
}

/// A small speed limit sign: a red ring for km/h, the white rectangle for mph.
struct LimitBadge: View {
    var limit: SpurActivityAttributes.ContentState.Limit
    var size: CGFloat = 30

    var body: some View {
        Group {
            if limit.mph {
                Text("\(limit.value)")
                    .font(WidgetType.font(size * 0.48))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .frame(width: size * 0.8, height: size)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.black, lineWidth: 1).padding(2))
            } else {
                Text("\(limit.value)")
                    .font(WidgetType.font(limit.value >= 100 ? size * 0.34 : size * 0.42))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(Palette.ring, lineWidth: size * 0.11))
            }
        }
        .accessibilityLabel("Tempolimit \(limit.value) \(limit.mph ? "mph" : "km/h")")
    }
}

struct ExpandedBottom: View {
    var context: ActivityViewContext<SpurActivityAttributes>

    var body: some View {
        let s = context.state
        if s.status == .ended {
            Text(SpurActivityText.ended(s, startedAt: context.attributes.startedAt))
                .font(WidgetType.font(14))
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Measure(value: SpurActivityText.speed(s.speedMps, metric: s.metric),
                            unit: SpurActivityText.speedUnit(metric: s.metric), size: 30, dim: context.isStale)
                    if let limit = s.limit, !context.isStale { LimitBadge(limit: limit, size: 30) }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        GPSChip(accuracy: s.accuracyMeters, stale: context.isStale || s.status == .gap)
                        if let road = s.roadType {
                            Text(road)
                                .font(WidgetType.font(12))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if let status = SpurActivityText.status(s, stale: context.isStale) {
                    Text(status)
                        .font(WidgetType.font(12))
                        .foregroundStyle(Palette.warn)
                }
            }
        }
    }
}

struct LockScreenView: View {
    var context: ActivityViewContext<SpurActivityAttributes>

    var body: some View {
        let s = context.state
        Group {
            if s.status == .ended {
                HStack(spacing: 8) {
                    StatusDot(context: context, size: 8)
                    Text(SpurActivityText.ended(s, startedAt: context.attributes.startedAt))
                        .font(WidgetType.font(15))
                        .foregroundStyle(Palette.primary)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatusDot(context: context, size: 8)
                        Text(SpurActivityText.status(s, stale: context.isStale) ?? "Fahrt läuft")
                            .font(WidgetType.font(13))
                            .foregroundStyle(context.isStale || s.status != .recording ? Palette.warn : Palette.secondary)
                        Spacer(minLength: 0)
                        if let limit = s.limit, !context.isStale { LimitBadge(limit: limit, size: 26) }
                        GPSChip(accuracy: s.accuracyMeters, stale: context.isStale || s.status == .gap)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Elapsed(context: context, size: 34)
                        Spacer(minLength: 0)
                        Measure(value: distance(s), unit: SpurActivityText.distanceUnit(metric: s.metric), size: 22, dim: context.isStale)
                        Measure(value: SpurActivityText.speed(s.speedMps, metric: s.metric),
                                unit: SpurActivityText.speedUnit(metric: s.metric), size: 22, dim: context.isStale)
                    }
                }
            }
        }
        .padding(16)
    }
}
