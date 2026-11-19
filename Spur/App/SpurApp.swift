import SwiftUI

@main
struct SpurApp: App {
    /// Created in `init` so a background relaunch by a location event resumes the trip at once.
    private let model: AppModel

    init() {
        model = AppModel()
        #if DEBUG
        PerfCounters.startIfWanted()
        #endif
        Self.applyTypefaceToSystemBars()
    }

    /// Navigation titles and segmented controls in the UI typeface (Regular only, no synthesized
    /// bold).
    private static func applyTypefaceToSystemBars() {
        // The title ink follows light and dark (SPEC 18.1).
        let lightInk = Theme.rgb(0x0B0D10, 0.92)
        let darkInk = UIColor.white.withAlphaComponent(Theme.Text.primaryOpacity)
        let white = UIColor(dynamicProvider: { @Sendable trait in trait.userInterfaceStyle == .light ? lightInk : darkInk })
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: Typography.uiFont(34), .foregroundColor: white, .kern: 0.2]
        appearance.titleTextAttributes = [.font: Typography.uiFont(17), .foregroundColor: white, .kern: 0.4]
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes([.font: Typography.uiFont(14)], for: .normal)
        segmented.setTitleTextAttributes([.font: Typography.uiFont(14)], for: .selected)
        // Tab labels stay in the system font: Liquid Glass applies an appearance font only off the
        // map, so the labels would switch faces between tabs.
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.settings)
                .environment(model.engine)
                .environment(model.roads)
                // SPEC 18.1: the whole app follows "Kartenstil" (Automatisch by the sun).
                .preferredColorScheme(model.isLight ? .light : .dark)
                .onChange(of: model.settings.mapStyle) { _, _ in model.updateAppearance() }
        }
    }
}
