import Foundation

/// Solar position after the NOAA solar calculator equations (Meeus based). Pure, offline.
nonisolated enum SunPosition {
    /// Geometric sun altitude (degrees above the horizon, no refraction) at a place and time.
    static func elevation(latitude: Double, longitude: Double, unixTime: Double) -> Double {
        let jd = unixTime / 86_400 + 2_440_587.5
        let jc = (jd - 2_451_545) / 36_525

        let l0 = (280.46646 + jc * (36000.76983 + jc * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
        let mr = Geo.rad(m)
        let center = sin(mr) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(2 * mr) * (0.019993 - 0.000101 * jc)
            + sin(3 * mr) * 0.000289
        let trueLong = l0 + center
        let omega = 125.04 - 1934.136 * jc
        let appLong = trueLong - 0.00569 - 0.00478 * sin(Geo.rad(omega))
        let meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(Geo.rad(omega))
        let decl = asin(sin(Geo.rad(obliq)) * sin(Geo.rad(appLong)))

        let y = pow(tan(Geo.rad(obliq / 2)), 2)
        let l0r = Geo.rad(l0)
        let eqTime = 4 * Geo.deg(
            y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
                - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr)
        )

        // Minutes past midnight UTC.
        var minutes = (unixTime / 60).truncatingRemainder(dividingBy: 1440)
        if minutes < 0 { minutes += 1440 }
        var trueSolar = (minutes + eqTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }
        let hourAngle = trueSolar / 4 < 0 ? trueSolar / 4 + 180 : trueSolar / 4 - 180

        let latr = Geo.rad(latitude)
        let cosZenith = sin(latr) * sin(decl) + cos(latr) * cos(decl) * cos(Geo.rad(hourAngle))
        let zenith = Geo.deg(acos(min(1, max(-1, cosZenith))))
        return 90 - zenith
    }
}

/// Day and night (SPEC section 5): share of moving time with the sun above -0.833°.
nonisolated struct DayNightStats: Codable, Sendable, Equatable {
    var daySeconds: Double
    var nightSeconds: Double

    /// Day share of moving time, 0 to 1, nil without moving time.
    var dayShare: Double? {
        let total = daySeconds + nightSeconds
        return total > 0 ? daySeconds / total : nil
    }

    static func compute(_ track: Track) -> DayNightStats {
        let f = track.fixes
        var day = 0.0, night = 0.0
        var cache: [Int64: Bool] = [:]
        for i in 1..<max(1, f.count) {
            guard let v = track.intervalSpeed[i], v >= StatsConstants.movingSpeed else { continue }
            // One sun computation per minute is plenty for a day or night decision.
            let minute = f[i].timestampMs / 60_000
            let isDay: Bool
            if let cached = cache[minute] {
                isDay = cached
            } else {
                isDay = SunPosition.elevation(latitude: f[i].latitude, longitude: f[i].longitude, unixTime: f[i].time)
                    > StatsConstants.sunHorizon
                cache[minute] = isDay
            }
            if isDay { day += track.dt[i] } else { night += track.dt[i] }
        }
        return DayNightStats(daySeconds: day, nightSeconds: night)
    }
}
