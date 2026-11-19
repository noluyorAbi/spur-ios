import SwiftUI
import UIKit

/// Files ready to hand to the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    var urls: [URL]
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    var urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A cancel request shared with an export running off the main actor.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Runs exports off the main actor, inside a background task (an export started just before the
/// phone locks still finishes), and reports a share item or an error message.
@Observable
final class ExportRunner {
    private(set) var busy = false
    var shareItem: ShareItem?
    var errorMessage: String?
    /// 0 to 1 while a sensor CSV is written, nil otherwise.
    private(set) var progress: Double?
    @ObservationIgnored private var cancelFlag: CancelFlag?

    /// Keeps the app running for an export that is still writing when the app goes to the background.
    private static func backgroundTask(_ name: String, onExpiry: @escaping () -> Void = {}) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpiry)
    }

    private static func end(_ task: UIBackgroundTaskIdentifier) {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    func cancel() { cancelFlag?.cancel() }

    func exportAll(store: TripStore, config: StatsConfig) {
        guard !busy else { return }
        busy = true
        let task = Self.backgroundTask("Alle Fahrten exportieren")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService.exportAll(store: store, config: config) }
            }.value
            Self.end(task)
            busy = false
            switch result {
            case .success(let url): shareItem = ShareItem(urls: [url])
            case .failure: errorMessage = "Der Export ist fehlgeschlagen."
            }
        }
    }

    /// The sensor CSV of a trip, with progress and a cancel.
    func exportMotionCSV(_ id: UUID, store: TripStore) {
        guard !busy else { return }
        busy = true
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag
        let task = Self.backgroundTask("Sensordaten exportieren") { flag.cancel() }
        Task {
            let result = await Task.detached(priority: .userInitiated) { [weak self] in
                var last = 0.0
                return Result {
                    try ExportService.exportMotionCSV(id, store: store) { share in
                        if share - last >= 0.01 {
                            last = share
                            Task { @MainActor in self?.progress = share }
                        }
                        return !flag.isCancelled
                    }
                }
            }.value
            Self.end(task)
            busy = false
            progress = nil
            cancelFlag = nil
            switch result {
            case .success(let url): shareItem = ShareItem(urls: [url])
            case .failure(let error) where error is CancellationError: break
            case .failure: errorMessage = "Der Export der Sensordaten ist fehlgeschlagen."
            }
        }
    }

    /// The progress line of a running sensor CSV export, with its cancel button.
    struct ProgressBanner: View {
        var runner: ExportRunner

        var body: some View {
            if let p = runner.progress {
                HStack(spacing: Theme.Space.s) {
                    ProgressView(value: p).tint(Theme.accentLight).frame(width: 80)
                    Text("Sensordaten werden exportiert · \(Format.percent(p))")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Text.primary)
                    Spacer(minLength: 0)
                    Button("Abbrechen") { runner.cancel() }
                        .font(Typography.caption)
                        .foregroundStyle(Theme.accentLight)
                        .frame(minHeight: Theme.touchTarget)
                }
                .padding(.horizontal, Theme.Space.m)
                .glassSurface(radius: 16)
                .padding(.horizontal, Theme.Space.m)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    func exportTrip(_ id: UUID, formats: [ExportService.Format], store: TripStore, config: StatsConfig) {
        guard !busy else { return }
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportService.exportTrip(id, formats: formats, store: store, config: config) }
            }.value
            busy = false
            switch result {
            case .success(let urls): shareItem = ShareItem(urls: urls)
            case .failure: errorMessage = "Der Export ist fehlgeschlagen."
            }
        }
    }
}

private struct ExportPresentation: ViewModifier {
    @Bindable var runner: ExportRunner

    func body(content: Content) -> some View {
        content
            .sheet(item: $runner.shareItem) { item in
                ActivityView(urls: item.urls)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .alert("Export", isPresented: Binding(get: { runner.errorMessage != nil }, set: { if !$0 { runner.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.errorMessage ?? "")
            }
    }
}

extension View {
    func exportPresentation(_ runner: ExportRunner) -> some View { modifier(ExportPresentation(runner: runner)) }
}

/// Toolbar button "Alle exportieren" (ZIP of every trip).
struct ExportAllButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @State private var runner = ExportRunner()

    var body: some View {
        Button {
            runner.exportAll(store: model.store, config: settings.statsConfig)
        } label: {
            if runner.busy {
                ProgressView().tint(Theme.accentLight)
            } else {
                Label("Alle exportieren", systemImage: "square.and.arrow.up.on.square")
            }
        }
        .disabled(model.finishedTrips.isEmpty || runner.busy)
        .accessibilityLabel("Alle Fahrten exportieren")
        .exportPresentation(runner)
    }
}

/// Settings row "Alle Fahrten exportieren".
struct ExportAllRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Settings.self) private var settings
    @State private var runner = ExportRunner()
    @State private var estimate: Int64 = 0

    var body: some View {
        Button {
            runner.exportAll(store: model.store, config: settings.statsConfig)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alle Fahrten exportieren")
                        .font(Typography.body)
                        .foregroundStyle(Theme.accentLight)
                    // Stated before the export starts: the raw motion data can make it large.
                    if estimate > 0 {
                        Text("ZIP bis etwa \(Format.bytes(estimate)); ältere ZIPs werden ersetzt")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                Spacer()
                if runner.busy { ProgressView().tint(Theme.accentLight) }
            }
        }
        .task(id: model.trips.count) {
            let store = model.store
            estimate = await Task.detached { ExportService.estimatedAllTripsBytes(store: store) }.value
        }
        .disabled(model.finishedTrips.isEmpty || runner.busy)
        .exportPresentation(runner)
    }
}
