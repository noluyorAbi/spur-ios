import Foundation
@testable import Spur

/// Hand-built fix sequences with exactly known geometry.
///
/// Points move due north along a meridian, where the haversine distance is exactly
/// `earthRadius * Δφ`, so a step of `Geo.latitudeDegrees(forMeters: d)` is exactly `d` meters.
enum Fixtures {
    static let baseMs: Int64 = 1_794_420_000_000 // 2026-11-11T18:00:00Z
    static let dallas = (lat: 32.7767, lon: -96.7970)

    /// One fix per entry of `speeds` (m/s), `dt` seconds apart, each moving `speed * dt` meters
    /// north of the previous one. The first fix sits at the start point.
    static func northbound(
        speeds: [Double], dt: Double = 1, startMs: Int64 = baseMs,
        lat: Double = dallas.lat, lon: Double = dallas.lon, accuracy: Double = 4
    ) -> [Fix] {
        var out: [Fix] = []
        var la = lat
        for (k, v) in speeds.enumerated() {
            if k > 0 { la += Geo.latitudeDegrees(forMeters: v * dt) }
            out.append(Fix(
                timestampMs: startMs + Int64((Double(k) * dt * 1000).rounded()),
                latitude: la, longitude: lon, horizontalAccuracy: accuracy,
                altitude: 150, verticalAccuracy: 3, speed: v, speedAccuracy: 0.5, course: 0
            ))
        }
        return out
    }

    /// Shifts fixes in time.
    static func shifted(_ fixes: [Fix], byMs ms: Int64) -> [Fix] {
        fixes.map { var f = $0; f.timestampMs += ms; return f }
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spur-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

func approx(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tol
}
