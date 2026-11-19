import SwiftUI

/// The tabs: Fahrt, Planen (SPEC 18.3), Historie, Einstellungen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Fahrt", systemImage: "location.north.line", value: AppTab.live) {
                LiveView()
            }
            Tab("Planen", systemImage: "magnifyingglass", value: AppTab.plan) {
                PlanView()
            }
            Tab("Historie", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                HistoryView()
            }
            Tab("Einstellungen", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Theme.accentLight)
        .background(Theme.background)
        .overlay(alignment: .top) {
            ExportRunner.ProgressBanner(runner: model.exporter)
                .animation(Theme.Motion.state, value: model.exporter.progress == nil)
        }
        .exportPresentation(model.exporter)
        .onChange(of: model.selectedTab, initial: true) { updateWarmUp() }
        .onChange(of: scenePhase) {
            updateWarmUp()
            // Live details refresh only with the app in front (SPEC 17.4).
            model.live.setInFront(scenePhase == .active)
            // The observed live state holds still in the background and catches up on return (17.4b).
            // Inactive (app switcher, Control Centre, notification shade) is still visible.
            model.engine.setDisplayActive(scenePhase != .background)
            model.roads.setDisplayActive(scenePhase != .background)
            // A Live Activity can only start in the foreground (SPEC 16.4).
            if scenePhase == .active { model.refreshActivity(activation: true) }
        }
        // The Live Activity opens the Fahrt tab.
        .onOpenURL { url in
            if url.scheme == "spur" { model.selectedTab = .live }
        }
        .task {
            #if DEBUG
            if AppEnvironment.autoStart, engine.phase == .idle { engine.requestStart() }
            #endif
        }
    }

    /// GPS warm-up (SPEC 14.1): only while the Fahrt tab is visible and the app is active.
    private func updateWarmUp() {
        guard !AppEnvironment.isRunningTests else { return }
        // Planen needs the position too, as the start of a route (SPEC 18.3).
        engine.warmUpWanted = (model.selectedTab == .live || model.selectedTab == .plan) && scenePhase == .active
    }
}
