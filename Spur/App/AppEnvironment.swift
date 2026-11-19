import Foundation
import UIKit

/// Process facts and debug launch arguments.
enum AppEnvironment {
    /// True while the unit tests run inside the host app: no recording resumes, no seeding.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    #if DEBUG
    private static let defaults = UserDefaults.standard
    /// `-SpurSeedDemo YES`: create synthetic demo trips.
    static var seedDemo: Bool { !isRunningTests && defaults.bool(forKey: "SpurSeedDemo") }
    /// `-SpurAutoStart YES`: start recording right after launch (simulator automation).
    static var autoStart: Bool { !isRunningTests && defaults.bool(forKey: "SpurAutoStart") }
    /// `-SpurTab live|history|settings`: open a tab (screenshots).
    static var initialTab: String? { isRunningTests ? nil : defaults.string(forKey: "SpurTab") }
    /// `-SpurOpenTrip newest|<uuid>`: open a trip detail (screenshots).
    static var openTrip: String? { isRunningTests ? nil : defaults.string(forKey: "SpurOpenTrip") }
    /// `-SpurDetailScroll <section>`: scroll the trip detail to a section (screenshots).
    static var detailScroll: String? { isRunningTests ? nil : defaults.string(forKey: "SpurDetailScroll") }
    /// `-SpurSettingsScroll strassendaten`: scroll the settings to a section (screenshots).
    static var settingsScroll: String? { isRunningTests ? nil : defaults.string(forKey: "SpurSettingsScroll") }
    /// `-SpurRoadFixture <file>`: an Overpass JSON file in `Library/Caches` becomes the road pack;
    /// no bundled pack, no cache, no network (the simulator replay of SPEC 14.8).
    static var roadFixture: String? { isRunningTests ? nil : defaults.string(forKey: "SpurRoadFixture") }
    /// `-SpurExportDemo YES`: write the newest trip's exports into Documents/Exports (parent check).
    static var exportDemo: Bool { !isRunningTests && defaults.bool(forKey: "SpurExportDemo") }
    /// `-SpurImportDrives <absolute path>`: the drives of a parent oracle file (`oracle-caseN.json`)
    /// become finished demo trips, analyzed like any other (the SPEC 15 screenshots).
    static var importDrives: String? { isRunningTests ? nil : defaults.string(forKey: "SpurImportDrives") }
    /// `-SpurStressSeed YES`: 300 driven blocks around downtown Dallas and a resumed 2 h trip, to
    /// profile the map at full budgets (SPEC 15 review).
    static var stressSeed: Bool { !isRunningTests && defaults.bool(forKey: "SpurStressSeed") }
    /// `-SpurGapDemo YES`: a trip on real downtown Dallas roads with a 45 s gap (SPEC 18.8, ui-flow).
    static var gapDemo: Bool { !isRunningTests && defaults.bool(forKey: "SpurGapDemo") }
    /// `-SpurSynthMotion YES`: motion samples derived from the fixes (the simulator has no motion
    /// hardware), so recording and analysis run end to end (SPEC 16.3.1).
    static var synthMotion: Bool { !isRunningTests && defaults.bool(forKey: "SpurSynthMotion") }
    /// `-SpurStopRecording YES`: stop a resumed trip right away, so it is analyzed (sim-e2e).
    static var stopRecording: Bool { !isRunningTests && defaults.bool(forKey: "SpurStopRecording") }
    /// `-SpurLiveDetails medium|large`: open the live details panel at that height once the trip
    /// has recorded `-SpurLiveDetailsAfter` seconds (default 60; screenshots).
    static var liveDetails: String? { isRunningTests ? nil : defaults.string(forKey: "SpurLiveDetails") }
    static var liveDetailsAfter: Double { defaults.object(forKey: "SpurLiveDetailsAfter") == nil ? 60 : defaults.double(forKey: "SpurLiveDetailsAfter") }
    /// `-SpurMutedMap YES`: the map's muted emphasis of 1.3, for the like-for-like before and after
    /// of the dark map (a design review).
    static var mutedMap: Bool { !isRunningTests && defaults.bool(forKey: "SpurMutedMap") }
    /// `-SpurSynthPlace offRoad|minorRoad|majorRoad|unknown`: every stop stands at that place
    /// instead of looking it up in the road data (SPEC 18.9, ui-flow).
    static var synthPlace: BreakDetector.Place? {
        isRunningTests ? nil : defaults.string(forKey: "SpurSynthPlace").flatMap(BreakDetector.Place.init(rawValue:))
    }
    /// `-SpurAutoPauseMinutes 0.5`: a shorter break for ui-flow; the setting's 3, 5 and 10 are
    /// covered by the unit tests.
    static var autoPauseMinutes: Double? {
        isRunningTests || defaults.object(forKey: "SpurAutoPauseMinutes") == nil ? nil : defaults.double(forKey: "SpurAutoPauseMinutes")
    }
    #else
    static let seedDemo = false
    static let autoStart = false
    static let initialTab: String? = nil
    static let openTrip: String? = nil
    static let detailScroll: String? = nil
    static let settingsScroll: String? = nil
    static let roadFixture: String? = nil
    static let exportDemo = false
    static let importDrives: String? = nil
    static let stressSeed = false
    static let gapDemo = false
    static let synthMotion = false
    static let stopRecording = false
    static let liveDetails: String? = nil
    static let liveDetailsAfter = 60.0
    static let mutedMap = false
    static let synthPlace: BreakDetector.Place? = nil
    static let autoPauseMinutes: Double? = nil
    #endif

    /// Hardware model identifier, for example `iPhone17,1`.
    static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
