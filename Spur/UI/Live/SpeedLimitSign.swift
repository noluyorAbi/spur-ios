import SwiftUI

/// The tagged speed limit beside the speed readout (SPEC 16.2), in the tag's own unit: a white
/// US-style rectangle for a mph tag, a round sign with a red ring for km/h. No words on it. Over
/// the limit it gets a thin danger outline; no sound, no haptic.
struct SpeedLimitSign: View {
    var limit: SpeedLimit
    var over: Bool
    var overBy: Int?
    /// The sign's unit differs from the speed readout's: a small unit under the number, so "72"
    /// beside "30" never reads as 72 against 30 km/h. A real sign carries no unit; this one sits
    /// next to a number that does.
    var showUnit = false

    static let ring = Color(red: 0.80, green: 0.10, blue: 0.12)

    var body: some View {
        Group {
            switch limit.unit {
            case .mph:
                VStack(spacing: 0) {
                    Text("\(limit.value)")
                        .font(Typography.font(showUnit ? 19 : 22, relativeTo: .title3))
                        .monospacedDigit()
                    if showUnit {
                        Text("mph").font(Typography.font(9, relativeTo: .caption2))
                    }
                }
                .foregroundStyle(.black)
                .frame(width: 40, height: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black, lineWidth: 1.5).padding(2.5))
            case .kmh:
                VStack(spacing: -1) {
                    Text("\(limit.value)")
                        .font(Typography.font(limit.value >= 100 ? 14 : (showUnit ? 16 : 18), relativeTo: .title3))
                        .monospacedDigit()
                    if showUnit {
                        Text("km/h").font(Typography.font(7, relativeTo: .caption2))
                    }
                }
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(Self.ring, lineWidth: 5))
            }
        }
        .padding(3)
        .overlay {
            if over {
                RoundedRectangle(cornerRadius: limit.unit == .mph ? 8 : 30, style: .continuous)
                    .strokeBorder(Theme.Status.bad, lineWidth: 1.5)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(limit, overBy: over ? overBy : nil))
        .accessibilityIdentifier("live.speedLimit")
    }

    static func label(_ limit: SpeedLimit, overBy: Int?) -> String {
        let base = "Tempolimit \(limit.value) \(limit.unitLabel) laut OpenStreetMap"
        guard let overBy else { return base }
        return "\(base), \(overBy) \(limit.unitLabel) darüber"
    }
}
