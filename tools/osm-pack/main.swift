import Foundation

// Reads the parent's tile extractor output on stdin (one `{"x","y","elements"}` object per line)
// and writes the bundled road pack. Keeps the Overpass JSON shape, drops relations and the
// boundary ways that carry no highway tag, and keeps only the tags Spur reads. --bbox (the
// extract's own box) becomes the header box: tiles that cross it hold only part of their roads,
// and the app treats them as partial (served, listed as missing, fetched live: RoadPack.isComplete).
//
// Usage: osm-pack --out <file> --area <name> --source <url> --source-date <ISO> --bbox s,w,n,e

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

guard let out = arg("--out"), let area = arg("--area"), let source = arg("--source"), let sourceDate = arg("--source-date") else {
    FileHandle.standardError.write(Data("usage: osm-pack --out <file> --area <name> --source <url> --source-date <ISO> [--bbox s,w,n,e]\n".utf8))
    exit(2)
}
var extract: BBox?
if let given = arg("--bbox") {
    let v = given.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else {
        FileHandle.standardError.write(Data("osm-pack: --bbox needs s,w,n,e\n".utf8))
        exit(2)
    }
    extract = BBox(south: v[0], west: v[1], north: v[2], east: v[3])
}
let outURL = URL(fileURLWithPath: out)
let writer = try RoadPackWriter(scratch: outURL.appendingPathExtension("blobs"))
var box = BBox(south: 90, west: 180, north: -90, east: -180)
var lines = 0
var dropped = 0
var partial: [TileKey] = []
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let x = obj["x"] as? Int, let y = obj["y"] as? Int, let raw = obj["elements"] as? [Any] else { continue }
    var e = OverpassParser.parse(elements: raw)
    let before = e.ways.count
    e.ways.removeAll { $0.tags?["highway"] == nil }
    dropped += before - e.ways.count
    let key = TileKey(x: x, y: y)
    if let extract, !RoadPackCoverage.isComplete(key, extract: extract) { partial.append(key) }
    try writer.add(key, json: OverpassParser.encode(e))
    let b = key.bbox
    box = BBox(south: min(box.south, b.south), west: min(box.west, b.west), north: max(box.north, b.north), east: max(box.east, b.east))
    lines += 1
    if lines % 50 == 0 { FileHandle.standardError.write(Data("osm-pack: \(lines) tiles\n".utf8)) }
}
if let extract { box = extract }
let iso = ISO8601DateFormatter()
let header = RoadPackHeader(area: area, source: source, sourceDate: sourceDate, createdAt: iso.string(from: Date()), bbox: box, tileCount: 0)
try writer.finish(to: outURL, header: header)
let pack = try RoadPack(url: outURL)
FileHandle.standardError.write(Data("osm-pack: wrote \(pack.header.tileCount) tiles, \(pack.fileSize) bytes (raw \(pack.header.rawBytes)), dropped \(dropped) boundary ways, \(partial.count) partial edge tiles\n".utf8))
if !partial.isEmpty {
    FileHandle.standardError.write(Data("osm-pack: partial edge tiles: \(partial.sorted().map { "\($0.x)-\($0.y)" }.joined(separator: " "))\n".utf8))
}
