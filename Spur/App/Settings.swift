import Foundation
import Observation

/// User settings (SPEC section 7.4), stored in UserDefaults.
@Observable
final class Settings {
    private enum Key {
        static let driver = "settings.driverName"
        static let vehicle = "settings.vehicleName"
        static let units = "settings.units"
        static let geocoding = "settings.geocoding"
        static let keepAwake = "settings.keepAwake"
        static let accuracy = "settings.usableAccuracy"
        static let showDriven = "settings.showDriven"
        static let courseUp = "settings.courseUp"
        static let alwaysHintDismissed = "settings.alwaysHintDismissed"
        static let alwaysRequested = "settings.alwaysRequested"
        static let roadDataOnline = "settings.roadDataOnline"
        static let showRoadFeatures = "settings.showRoadFeatures"
        static let showSpeedLimit = "settings.showSpeedLimit"
        static let mapStyle = "settings.mapStyle"
        static let showTraffic = "settings.showTraffic"
        static let mapType = "settings.mapType"
        static let coverageByFrequency = "settings.coverageByFrequency"
        static let showLiveActivity = "settings.showLiveActivity"
        static let coverageLegendSeen = "settings.coverageLegendSeen"
        static let recordMotion = "settings.recordMotion"
        static let motionRateHz = "settings.motionRateHz"
        static let autoPause = "settings.autoPause"
        static let autoPauseMinutes = "settings.autoPauseMinutes"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var driverName: String { didSet { defaults.set(driverName, forKey: Key.driver) } }
    var vehicleName: String { didSet { defaults.set(vehicleName, forKey: Key.vehicle) } }
    var units: UnitSystem { didSet { defaults.set(units.rawValue, forKey: Key.units) } }
    /// "Orte und Straßennamen ermitteln".
    var geocodingEnabled: Bool { didSet { defaults.set(geocodingEnabled, forKey: Key.geocoding) } }
    /// "Display während der Fahrt anlassen".
    var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Key.keepAwake) } }
    /// "Genauigkeitsfilter" in meters.
    var usableAccuracy: Double { didSet { defaults.set(usableAccuracy, forKey: Key.accuracy) } }
    /// Map layer "bereits gefahren".
    var showDrivenLayer: Bool { didSet { defaults.set(showDrivenLayer, forKey: Key.showDriven) } }
    /// Camera mode on the live map.
    var courseUp: Bool { didSet { defaults.set(courseUp, forKey: Key.courseUp) } }
    var alwaysHintDismissed: Bool { didSet { defaults.set(alwaysHintDismissed, forKey: Key.alwaysHintDismissed) } }
    /// iOS shows the "Immer" prompt once per install; afterwards only the iOS settings can grant it.
    var alwaysRequested: Bool { didSet { defaults.set(alwaysRequested, forKey: Key.alwaysRequested) } }
    /// "Straßendaten aus dem Internet laden" (SPEC 14.2): only tile boxes are sent, never the route.
    var roadDataOnline: Bool { didSet { defaults.set(roadDataOnline, forKey: Key.roadDataOnline) } }
    /// Map layer with signals, stop signs and skewed junctions (SPEC 14.6).
    var showRoadFeatures: Bool { didSet { defaults.set(showRoadFeatures, forKey: Key.showRoadFeatures) } }
    /// "Tempolimit anzeigen" (SPEC 16.2): the OSM limit of the matched way beside the speed.
    var showSpeedLimit: Bool { didSet { defaults.set(showSpeedLimit, forKey: Key.showSpeedLimit) } }
    /// "Kartenstil" (SPEC 18.1), Automatisch by default.
    var mapStyle: MapStyleChoice { didSet { defaults.set(mapStyle.rawValue, forKey: Key.mapStyle) } }
    /// The traffic layer (SPEC 18.2), off by default.
    var showTraffic: Bool { didSet { defaults.set(showTraffic, forKey: Key.showTraffic) } }
    /// "Kartentyp" (SPEC 18.2b), Standard by default.
    var mapType: MapTypeChoice { didSet { defaults.set(mapType.rawValue, forKey: Key.mapType) } }
    /// "Abdeckung: Richtung | Häufigkeit" (SPEC 18.7), Richtung by default.
    var coverageByFrequency: Bool { didSet { defaults.set(coverageByFrequency, forKey: Key.coverageByFrequency) } }
    /// Traffic as it can be drawn on the current map type.
    var trafficShown: Bool { showTraffic && mapType.showsTraffic }
    /// Live Activity on the lock screen and in the Dynamic Island while recording (SPEC 16.4).
    var showLiveActivity: Bool { didSet { defaults.set(showLiveActivity, forKey: Key.showLiveActivity) } }
    /// The legend of the driven directions was shown once (SPEC 15.2).
    var coverageLegendSeen: Bool { didSet { defaults.set(coverageLegendSeen, forKey: Key.coverageLegendSeen) } }
    /// "Bewegungssensor aufzeichnen" (SPEC 16.3.1).
    var recordMotion: Bool { didSet { defaults.set(recordMotion, forKey: Key.recordMotion) } }
    /// "Abtastrate": 100 or 50 Hz.
    var motionRateHz: Int { didSet { defaults.set(motionRateHz, forKey: Key.motionRateHz) } }
    /// "Automatisch pausieren" (SPEC 18.9), on by default.
    var autoPause: Bool { didSet { defaults.set(autoPause, forKey: Key.autoPause) } }
    /// A stop must last this long before it can be a break: 3, 5 or 10 minutes, default 5.
    var autoPauseMinutes: Int { didSet { defaults.set(autoPauseMinutes, forKey: Key.autoPauseMinutes) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        driverName = defaults.string(forKey: Key.driver) ?? ""
        vehicleName = defaults.string(forKey: Key.vehicle) ?? ""
        units = defaults.string(forKey: Key.units).flatMap(UnitSystem.init(rawValue:)) ?? .metric
        geocodingEnabled = defaults.object(forKey: Key.geocoding) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
        let acc = defaults.double(forKey: Key.accuracy)
        usableAccuracy = acc > 0 ? acc : StatsConstants.defaultUsableAccuracy
        showDrivenLayer = defaults.object(forKey: Key.showDriven) as? Bool ?? true
        courseUp = defaults.object(forKey: Key.courseUp) as? Bool ?? true
        alwaysHintDismissed = defaults.bool(forKey: Key.alwaysHintDismissed)
        alwaysRequested = defaults.bool(forKey: Key.alwaysRequested)
        roadDataOnline = defaults.object(forKey: Key.roadDataOnline) as? Bool ?? true
        showRoadFeatures = defaults.object(forKey: Key.showRoadFeatures) as? Bool ?? true
        showSpeedLimit = defaults.object(forKey: Key.showSpeedLimit) as? Bool ?? true
        mapStyle = defaults.string(forKey: Key.mapStyle).flatMap(MapStyleChoice.init(rawValue:)) ?? .automatic
        showTraffic = defaults.object(forKey: Key.showTraffic) as? Bool ?? false
        mapType = defaults.string(forKey: Key.mapType).flatMap(MapTypeChoice.init(rawValue:)) ?? .standard
        coverageByFrequency = defaults.bool(forKey: Key.coverageByFrequency)
        showLiveActivity = defaults.object(forKey: Key.showLiveActivity) as? Bool ?? true
        coverageLegendSeen = defaults.bool(forKey: Key.coverageLegendSeen)
        recordMotion = defaults.object(forKey: Key.recordMotion) as? Bool ?? true
        autoPause = defaults.object(forKey: Key.autoPause) as? Bool ?? true
        autoPauseMinutes = [3, 5, 10].contains(defaults.integer(forKey: Key.autoPauseMinutes)) ? defaults.integer(forKey: Key.autoPauseMinutes) : 5
        let rate = defaults.integer(forKey: Key.motionRateHz)
        motionRateHz = rate == 50 ? 50 : 100
    }

    var statsConfig: StatsConfig { StatsConfig(usableAccuracy: usableAccuracy) }
}
