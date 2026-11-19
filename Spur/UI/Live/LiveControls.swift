import SwiftUI

/// The blue Start button, at least 72 pt tall.
struct StartButton: View {
    var busy: Bool
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "record.circle")
                    .font(.system(size: 20))
                Text(busy ? "Warte auf Freigabe" : "Start")
                    .font(Typography.font(22, relativeTo: .title3))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.primaryControl)
            .background(Theme.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .disabled(busy)
        .accessibilityHint("Startet die Aufzeichnung der Fahrt")
    }
}

/// Stop as press-and-hold (1.2 s) with a progress ring: it cannot trigger by accident and needs
/// no confirmation dialog.
struct HoldToStopButton: View {
    static let holdDuration: Double = 1.2
    /// The primary control while recording: at least 72 pt.
    static let size: CGFloat = 72
    var onStop: () -> Void
    /// A press let go before the hold completed: the caller says how to stop instead of nothing
    /// happening (a tap on the ring read as "did not register").
    var onTooShort: () -> Void = {}

    @State private var progress: CGFloat = 0
    @State private var completed = false
    /// Counts presses, for a light tick the moment the hold begins.
    @State private var presses = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Halten zum Beenden")
                .eyebrow(Theme.Text.secondaryOpacity)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 110, alignment: .trailing)
            ZStack {
                Circle().fill(Theme.Text.ink(0.08))
                Circle()
                    .stroke(Theme.Text.ink(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.Text.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.Text.primary)
                    .frame(width: 22, height: 22)
                    .scaleEffect(progress > 0 && !reduceMotion ? 0.86 : 1)
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 60) {
                completed = true
                onStop()
            } onPressingChanged: { pressing in
                if pressing {
                    presses += 1
                    completed = false
                    withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
                } else if !completed {
                    withAnimation(.spring(duration: 0.25, bounce: 0)) { progress = 0 }
                    onTooShort()
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: completed) { _, new in new }
            .sensoryFeedback(.impact(weight: .light), trigger: presses)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fahrt beenden")
        .accessibilityHint("Gedrückt halten, um die Aufzeichnung zu beenden")
        .accessibilityAction { onStop() }
    }
}

/// Opens the compact tag picker during a trip.
struct EventButton: View {
    /// Without its caption when the Pause circle sits beside it (SPEC 18.9).
    var showsLabel = true
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "flag")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Text.primary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.Text.ink(0.08)))
                    .overlay(Circle().strokeBorder(Theme.Text.ink(0.16), lineWidth: 1))
                if showsLabel { Text("Ereignis").eyebrow(Theme.Text.secondaryOpacity) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityLabel("Ereignis markieren")
    }
}

/// Pause and Fortsetzen (SPEC 18.9): a light action beside Ereignis; Stop stays hold-to-stop.
struct PauseButton: View {
    var paused: Bool
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 20))
                .foregroundStyle(paused ? Color.white : Theme.Text.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .background(Circle().fill(paused ? Theme.accent : Theme.Text.ink(0.08)))
                .overlay(Circle().strokeBorder(Theme.Text.ink(paused ? 0 : 0.16), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(paused ? "Fahrt fortsetzen" : "Fahrt pausieren")
        .accessibilityIdentifier("trip.pause")
    }
}

/// One tap per tag.
struct EventPickerSheet: View {
    var onPick: (TripEvent.Tag) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Ereignis markieren")
                    .font(Typography.headline)
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                }
                .accessibilityLabel("Schließen")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(TripEvent.Tag.allCases) { tag in
                    Button {
                        onPick(tag)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tag.symbol)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.accentLight)
                                .frame(width: 22)
                            Text(tag.label)
                                .font(Typography.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(Theme.Space.m)
        .presentationDetents([.height(380)])
        .presentationBackground(Theme.surface)
        .presentationCornerRadius(Theme.Radius.sheet)
    }
}

/// The short summary after stopping.
struct StopSummarySheet: View {
    var trip: TripRecord
    var units: UnitSystem
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = trip.statistics
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fahrt beendet").eyebrow()
                    Text(trip.customTitle ?? trip.placeTitle ?? trip.startedAt.formatted(.dateTime.locale(Format.locale).day().month(.wide).hour().minute()))
                        .font(Typography.title)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                }
                .accessibilityLabel("Schließen")
            }
            HStack(alignment: .top) {
                Metric(label: "Strecke", value: Format.distance(s?.distance ?? 0, units), unit: units.distanceUnit, size: 30)
                Spacer()
                Metric(label: "Dauer", value: Format.duration(s?.time.totalDuration ?? 0), size: 30)
                Spacer()
                Metric(label: "Ø Fahrt", value: Format.speed(s?.speed.movingAverage, units), unit: units.speedUnit, size: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                RoadShareBar(stats: s?.roadType, height: 6)
                if let roads = s?.roadType {
                    RoadLegend(stats: roads, units: units, estimated: true)
                }
            }
            Button {
                onOpen()
                dismiss()
            } label: {
                Text("Fahrt ansehen")
                    .font(Typography.font(17, relativeTo: .headline))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(Theme.Space.l)
        .presentationDetents([.height(360)])
        .presentationBackground(Theme.surface)
        .presentationCornerRadius(Theme.Radius.sheet)
    }
}
