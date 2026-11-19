import Foundation

/// A slippy map tile (SPEC 14.2: z13, the parent's tiling). Formulas follow the parent's
/// `src/lib/geo.ts` exactly so tile keys and boxes match the parent bit for bit.
nonisolated struct TileKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    static let zoom = 13

    var z: Int
    var x: Int
    var y: Int

    init(z: Int = TileKey.zoom, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    var description: String { "\(z)/\(x)/\(y)" }
    /// File name stem in the cache.
    var fileStem: String { "\(z)-\(x)-\(y)" }

    static func < (a: TileKey, b: TileKey) -> Bool { (a.z, a.x, a.y) < (b.z, b.x, b.y) }

    /// The tile that contains a point (parent `tileFor`).
    static func containing(lat: Double, lon: Double, z: Int = TileKey.zoom) -> TileKey {
        let n = pow(2.0, Double(z))
        let x = Int(floor((lon + 180) / 360 * n))
        let latR = lat * .pi / 180
        let y = Int(floor((1 - log(tan(latR) + 1 / cos(latR)) / .pi) / 2 * n))
        let maxIndex = Int(n) - 1
        return TileKey(z: z, x: max(0, min(maxIndex, x)), y: max(0, min(maxIndex, y)))
    }

    /// [south, west, north, east] in degrees (parent `tileBBox`).
    var bbox: BBox {
        let n = pow(2.0, Double(z))
        let lon: (Double) -> Double = { $0 / n * 360 - 180 }
        let lat: (Double) -> Double = { atan(sinh(.pi * (1 - 2 * $0 / n))) * 180 / .pi }
        return BBox(south: lat(Double(y + 1)), west: lon(Double(x)), north: lat(Double(y)), east: lon(Double(x + 1)))
    }

    /// This tile and its eight neighbours (SPEC 14.2, while recording).
    var withNeighbours: [TileKey] {
        let maxIndex = (1 << z) - 1
        var out: [TileKey] = []
        for dx in -1...1 {
            for dy in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx <= maxIndex, ny <= maxIndex else { continue }
                out.append(TileKey(z: z, x: nx, y: ny))
            }
        }
        return out
    }

    /// All tiles intersecting a box (parent `tilesForBBox`).
    static func covering(_ b: BBox, z: Int = TileKey.zoom) -> [TileKey] {
        let a = containing(lat: b.north, lon: b.west, z: z)
        let c = containing(lat: b.south, lon: b.east, z: z)
        var out: [TileKey] = []
        for x in a.x...max(a.x, c.x) {
            for y in a.y...max(a.y, c.y) { out.append(TileKey(z: z, x: x, y: y)) }
        }
        return out
    }

    /// Tiles whose box comes within `radius` meters of a point ("Gebiet vorladen": 15 km), nearest first.
    static func within(radius: Double, ofLat lat: Double, lon: Double, z: Int = TileKey.zoom) -> [TileKey] {
        let dLat = radius / OSMGeo.R * 180 / .pi
        let dLon = dLat / max(0.01, cos(lat * .pi / 180))
        let box = BBox(south: lat - dLat, west: lon - dLon, north: lat + dLat, east: lon + dLon)
        let keys = covering(box, z: z).filter { $0.bbox.distance(toLat: lat, lon: lon) <= radius }
        return keys.sorted { $0.bbox.distance(toLat: lat, lon: lon) < $1.bbox.distance(toLat: lat, lon: lon) }
    }
}

/// A box in degrees, [south, west, north, east] like the parent's `BBox`.
nonisolated struct BBox: Equatable, Sendable, Codable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double

    var array: [Double] { [south, west, north, east] }

    /// True when `other` lies entirely within this box (edges included).
    func contains(_ other: BBox) -> Bool {
        other.south >= south && other.north <= north && other.west >= west && other.east <= east
    }

    func contains(lat: Double, lon: Double) -> Bool {
        lat >= south && lat <= north && lon >= west && lon <= east
    }

    /// Distance in meters from a point to the nearest point of the box (0 inside).
    func distance(toLat lat: Double, lon: Double) -> Double {
        let cLat = min(max(lat, south), north)
        let cLon = min(max(lon, west), east)
        return OSMGeo.haversine(lat1: lat, lon1: lon, lat2: cLat, lon2: cLon)
    }
}
