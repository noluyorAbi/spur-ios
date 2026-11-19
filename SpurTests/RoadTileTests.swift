import Foundation
import Testing
@testable import Spur

/// A clock tests can move; `sleep` advances it instead of waiting.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date
    private(set) var sleeps: [TimeInterval] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_420_000)) { time = start }

    var now: Date { lock.withLock { time } }

    func advance(_ s: TimeInterval) { lock.withLock { time = time.addingTimeInterval(s) } }

    func sleep(_ s: TimeInterval) {
        lock.withLock {
            sleeps.append(s)
            time = time.addingTimeInterval(s)
        }
    }
}

/// Answers Overpass requests from a script and records them.
nonisolated final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Answer { case status(Int), body(Data), timeout }

    private let lock = NSLock()
    private var script: [Answer]
    private(set) var requests: [URLRequest] = []

    init(_ script: [Answer]) { self.script = script }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer = lock.withLock {
            requests.append(request)
            return script.isEmpty ? .status(503) : script.removeFirst()
        }
        let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch answer {
        case .status(let code):
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        case .body(let data):
            return (data, ok)
        case .timeout:
            throw URLError(.timedOut)
        }
    }

    var count: Int { lock.withLock { requests.count } }
}

nonisolated enum OSMSamples {
    /// A small Overpass answer: two roads sharing a node, a signal, a boundary relation and a
    /// shop node whose tags Spur must not keep.
    static let overpass = Data("""
    {"version":0.6,"elements":[
      {"type":"node","id":1,"lat":32.7801,"lon":-96.8001},
      {"type":"node","id":2,"lat":32.7811,"lon":-96.8001,"tags":{"highway":"traffic_signals","traffic_signals:direction":"forward","name":"Ignored"}},
      {"type":"node","id":3,"lat":32.7821,"lon":-96.8001},
      {"type":"node","id":4,"lat":32.7811,"lon":-96.7991},
      {"type":"node","id":5,"lat":32.7815,"lon":-96.7995,"tags":{"shop":"car","name":"Somebody's Cars"}},
      {"type":"way","id":10,"nodes":[1,2,3],"tags":{"highway":"primary","name":"Main Street","maxspeed":"35 mph","oneway":"no","surface":"asphalt","source":"survey"}},
      {"type":"way","id":11,"nodes":[2,4],"tags":{"highway":"residential","name":"Elm Street"}},
      {"type":"relation","id":99,"members":[],"tags":{"boundary":"administrative","admin_level":"8"}}
    ]}
    """.utf8)
}

struct RoadTileTests {
    // MARK: Parser

    @Test func parserReadsNodesAndWaysAndKeepsOnlyTheTagsSpurReads() throws {
        let e = try OverpassParser.parse(OSMSamples.overpass)
        #expect(e.nodes.count == 5)
        #expect(e.ways.count == 2)
        #expect(e.nodes[1].id == 2 && e.nodes[1].lat == 32.7811 && e.nodes[1].lon == -96.8001)
        #expect(e.nodes[1].tags == ["highway": "traffic_signals", "traffic_signals:direction": "forward"])
        #expect(e.nodes[4].tags == nil) // shop tags dropped
        #expect(e.ways[0].nodes == [1, 2, 3])
        #expect(e.ways[0].tags == ["highway": "primary", "name": "Main Street", "maxspeed": "35 mph", "oneway": "no", "surface": "asphalt"])
        // Every tag on request (fixtures for the parity tests keep their raw tags).
        let all = try OverpassParser.parse(OSMSamples.overpass, keepAllTags: true)
        #expect(all.ways[0].tags?["source"] == "survey")
    }

    @Test func parserRejectsRuntimeErrorsAndNonOverpassAnswers() {
        #expect(throws: OverpassParseError.self) {
            try OverpassParser.parse(Data(#"{"elements":[],"remark":"runtime error: Query timed out in \"query\" at line 3"}"#.utf8))
        }
        #expect(throws: OverpassParseError.notJSON) { try OverpassParser.parse(Data("<html>busy</html>".utf8)) }
        #expect(throws: OverpassParseError.noElements) { try OverpassParser.parse(Data(#"{"osm3s":{}}"#.utf8)) }
    }

    @Test func encodedElementsParseBackToTheSameValue() throws {
        let e = try OverpassParser.parse(OSMSamples.overpass)
        #expect(try OverpassParser.parse(OverpassParser.encode(e)) == e)
    }

    // MARK: Tiles

    @Test func tileMathMatchesTheParent() {
        // Values printed by the parent's tileFor and tileBBox for this point.
        let key = TileKey.containing(lat: 32.7767, lon: -96.797)
        #expect(key == TileKey(z: 13, x: 1893, y: 3305))
        let b = key.bbox
        #expect(b.south == 32.76880048488168)
        #expect(b.west == -96.8115234375)
        #expect(b.north == 32.805744732906874)
        #expect(b.east == -96.767578125)
        #expect(key.withNeighbours.count == 9)
        #expect(Set(key.withNeighbours).contains(TileKey(x: 1894, y: 3306)))
    }

    @Test func preloadAreaCoversFifteenKilometersNearestFirst() {
        let keys = TileKey.within(radius: 15_000, ofLat: 32.7767, lon: -96.797)
        #expect(keys.first == TileKey.containing(lat: 32.7767, lon: -96.797))
        #expect(keys.count > 30 && keys.count < 80)
        #expect(keys.allSatisfy { $0.bbox.distance(toLat: 32.7767, lon: -96.797) <= 15_000 })
    }

    // MARK: Overpass query

    @Test func theQueryIsTheParentsRoadsQueryForTheTileBox() {
        let q = OverpassQuery.roads(TileKey(x: 1893, y: 3305).bbox)
        #expect(q.hasPrefix("[out:json][timeout:50];\n(\n  way[\"highway\"~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$\"](32.768800485,-96.811523438,32.805744733,-96.767578125);"))
        #expect(q.hasSuffix("(.neighbours; - .roads;);\nout body;"))
        #expect(q.components(separatedBy: "(32.768800485,-96.811523438,32.805744733,-96.767578125)").count == 5)
    }

    /// SPEC 14.0: only tile bounding boxes go to a server. The request body holds no number except
    /// the four tile edges and the server time limit.
    @Test func aRequestCarriesOnlyTheTileBox() throws {
        let key = TileKey(x: 1893, y: 3305)
        let request = OverpassClient.request(OverpassClient.endpoints[0], key: key)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Spur/1.1 (iOS)")
        #expect(request.timeoutInterval == 60)
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(headerNames == ["user-agent", "accept", "content-type"])
        let bodyData = try #require(request.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        #expect(body.hasPrefix("data="))
        let query = try #require(body.dropFirst(5).removingPercentEncoding)
        let box = OverpassQuery.boxArgs(key.bbox)
        var rest = query.replacingOccurrences(of: box, with: "")
        rest = rest.replacingOccurrences(of: "[timeout:50]", with: "")
        #expect(rest.rangeOfCharacter(from: .decimalDigits) == nil, "unexpected numbers in \(rest)")
        #expect(box == "(32.768800485,-96.811523438,32.805744733,-96.767578125)")
    }

    // MARK: Overpass client

    /// The failover mechanics on a fixed list of three endpoints (the list itself is tested below).
    static let threeEndpoints = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter",
                                 "https://overpass.kumi.systems/api/interpreter"].map { URL(string: $0)! }

    static func client(_ transport: FakeTransport, _ clock: TestClock, endpoints: [URL] = threeEndpoints) -> OverpassClient {
        OverpassClient(transport: transport, endpoints: endpoints, now: { clock.now }, sleep: { clock.sleep($0) })
    }

    /// 2026-11-17: overpass-api.de answered 502, two others timed out, maps.mail.ru answered. The
    /// server that answered goes first next time, the failed ones last for 5 min.
    @Test func theServerThatAnsweredGoesFirstAndFailedOnesLast() async throws {
        #expect(OverpassClient.endpoints.map { $0.host() } == ["overpass-api.de", "maps.mail.ru", "overpass.private.coffee", "overpass.kumi.systems"])
        let clock = TestClock()
        let t = FakeTransport([.status(502), .body(OSMSamples.overpass), .body(OSMSamples.overpass)])
        let client = Self.client(t, clock, endpoints: OverpassClient.endpoints)
        _ = try await client.fetch(TileKey(x: 1, y: 1))
        #expect(t.requests.map { $0.url!.host() } == ["overpass-api.de", "maps.mail.ru"])
        #expect(await client.order().map { $0.host() } == ["maps.mail.ru", "overpass.private.coffee", "overpass.kumi.systems", "overpass-api.de"])
        _ = try await client.fetch(TileKey(x: 2, y: 2))
        #expect(t.requests.last?.url?.host() == "maps.mail.ru", "the next tile asks the server that answered")
        clock.advance(301)
        #expect(await client.order().first?.host() == "maps.mail.ru")
        #expect(await client.order().last?.host() == "overpass.kumi.systems", "the penalty is over")
    }

    /// A server that timed out is left out for 5 min while another is available: the next tile
    /// does not wait 60 s on it again.
    @Test func aServerThatTimedOutIsLeftOut() async throws {
        let clock = TestClock()
        let t = FakeTransport([.timeout, .body(OSMSamples.overpass), .body(OSMSamples.overpass)])
        let client = Self.client(t, clock)
        _ = try await client.fetch(TileKey(x: 1, y: 1))
        #expect(!(await client.order()).contains { $0.host() == "overpass-api.de" })
        _ = try await client.fetch(TileKey(x: 2, y: 2))
        #expect(t.requests.map { $0.url!.host() } == ["overpass-api.de", "overpass.private.coffee", "overpass.private.coffee"])
        clock.advance(301)
        #expect(await client.order().contains { $0.host() == "overpass-api.de" })
    }

    @Test func clientFailsOverToTheNextEndpoint() async throws {
        let clock = TestClock()
        let t = FakeTransport([.status(502), .body(OSMSamples.overpass)])
        let e = try await Self.client(t, clock).fetch(TileKey(x: 1893, y: 3305))
        #expect(e.ways.count == 2)
        #expect(t.requests.map { $0.url!.host() } == ["overpass-api.de", "overpass.private.coffee"])
        // The second request waited for the 2 s spacing.
        #expect(clock.sleeps == [2])
    }

    @Test func clientBacksOffAndGivesUpSilentlyThenCoolsDown() async throws {
        let clock = TestClock()
        let t = FakeTransport(Array(repeating: .status(429), count: 6) + [.timeout, .status(504), .status(503), .body(OSMSamples.overpass)])
        let client = Self.client(t, clock)
        await #expect(throws: OverpassClientError.self) { try await client.fetch(TileKey(x: 1, y: 2)) }
        // Three rounds over three endpoints; 2 s and 4 s between the rounds, 2 s spacing inside them.
        #expect(t.count == 9)
        #expect(clock.sleeps.filter { $0 == 4 }.count == 1)
        #expect(clock.sleeps.reduce(0, +) >= 2 * 8)
        // The next call within the 30 s back-off sends nothing.
        let before = t.count
        await #expect(throws: OverpassClientError.self) { try await client.fetch(TileKey(x: 1, y: 2)) }
        #expect(t.count == before)
        // After it, the client tries again, and a success resets the back-off.
        clock.advance(31)
        let e = try await client.fetch(TileKey(x: 1, y: 2))
        #expect(e.ways.count == 2)
        #expect(await client.coolingUntil == nil)
    }

    @Test func clientStopsAfterNonRetryableAnswers() async throws {
        let clock = TestClock()
        let t = FakeTransport([.status(400), .status(403), .status(404)])
        await #expect(throws: OverpassClientError.self) { try await Self.client(t, clock).fetch(TileKey(x: 1, y: 2)) }
        #expect(t.count == 3) // one round only
    }

    @Test func clientSendsOneRequestAtATime() async throws {
        let clock = TestClock()
        let t = FakeTransport(Array(repeating: .body(OSMSamples.overpass), count: 4))
        let client = Self.client(t, clock)
        async let a = client.fetch(TileKey(x: 1, y: 1))
        async let b = client.fetch(TileKey(x: 2, y: 2))
        async let c = client.fetch(TileKey(x: 3, y: 3))
        _ = try await (a, b, c)
        #expect(t.count == 3)
        // Three requests: the second and third waited for the spacing.
        #expect(clock.sleeps == [2, 2])
    }

    // MARK: Pack

    @Test func packRoundTrip() throws {
        let dir = Fixtures.tempDir()
        let writer = try RoadPackWriter(scratch: dir.appendingPathComponent("blobs"))
        let e = try OverpassParser.parse(OSMSamples.overpass)
        var second = e
        second.ways.removeLast()
        let keys = [TileKey(x: 1893, y: 3305), TileKey(x: 1894, y: 3305), TileKey(x: 1893, y: 3306)]
        try writer.add(keys[0], json: OverpassParser.encode(e))
        try writer.add(keys[1], json: OverpassParser.encode(second))
        try writer.add(keys[2], json: Data(#"{"elements":[]}"#.utf8))
        let url = dir.appendingPathComponent("test.spurpack")
        try writer.finish(to: url, header: RoadPackHeader(area: "Testgebiet", source: "test", sourceDate: "2026-11-07T00:00:00Z",
                                                          createdAt: "2026-11-11T00:00:00Z",
                                                          bbox: BBox(south: 32, west: -97, north: 33, east: -96), tileCount: 0))
        let pack = try RoadPack(url: url)
        #expect(pack.header.tileCount == 3)
        #expect(pack.header.area == "Testgebiet")
        #expect(pack.header.compression == "lzfse")
        #expect(pack.header.rawBytes > 0)
        #expect(pack.tiles == keys.sorted())
        #expect(try pack.elements(for: keys[0]) == e)
        #expect(try pack.elements(for: keys[1]) == second)
        #expect(try pack.elements(for: keys[2])?.isEmpty == true)
        #expect(try pack.elements(for: TileKey(x: 1, y: 1)) == nil)
        #expect(!pack.covers(TileKey(x: 1, y: 1)))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("blobs").path))
    }

    @Test func aDamagedPackIsRejected() {
        #expect(throws: RoadPackError.badMagic) { try RoadPack(data: Data("NOTAPACK0000".utf8)) }
        var d = RoadPack.magic
        d.appendUInt32(500)
        #expect(throws: RoadPackError.truncated) { try RoadPack(data: d) }
    }

    // MARK: Cache

    @Test func cacheEvictsTheLeastRecentlyUsedTilesAboveTheCap() throws {
        let clock = TestClock()
        let dir = Fixtures.tempDir()
        let e = try OverpassParser.parse(OSMSamples.overpass)
        let probe = RoadTileCache(directory: dir.appendingPathComponent("probe"), now: { clock.now })
        try probe.write(TileKey(x: 0, y: 0), elements: e)
        let size = probe.totalBytes
        #expect(size > 0)

        // Room for three tiles.
        let cache = RoadTileCache(directory: dir.appendingPathComponent("c"), capBytes: size * 3 + size / 2, now: { clock.now })
        for x in 0..<3 {
            try cache.write(TileKey(x: x, y: 0), elements: e)
            clock.advance(10)
        }
        // Tile 0 is used again, so tile 1 is now the least recently used.
        #expect(cache.read(TileKey(x: 0, y: 0))?.elements == e)
        clock.advance(10)
        try cache.write(TileKey(x: 3, y: 0), elements: e)
        #expect(cache.keys == [TileKey(x: 0, y: 0), TileKey(x: 2, y: 0), TileKey(x: 3, y: 0)])
        #expect(cache.totalBytes <= cache.capBytes)

        // A fresh instance rebuilds the same index from the directory.
        let reopened = RoadTileCache(directory: dir.appendingPathComponent("c"), capBytes: cache.capBytes, now: { clock.now })
        #expect(reopened.keys == cache.keys)
        #expect(reopened.totalBytes == cache.totalBytes)

        cache.clear()
        #expect(cache.count == 0)
        #expect(cache.totalBytes == 0)
    }

    @Test func cacheTilesExpireAfterThirtyDaysButAreStillServed() throws {
        let clock = TestClock()
        let cache = RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now })
        let e = try OverpassParser.parse(OSMSamples.overpass)
        try cache.write(TileKey(x: 5, y: 5), elements: e)
        clock.advance(29 * 24 * 3600)
        #expect(cache.read(TileKey(x: 5, y: 5))?.isExpired == false)
        clock.advance(2 * 24 * 3600)
        let hit = try #require(cache.read(TileKey(x: 5, y: 5)))
        #expect(hit.isExpired)
        #expect(hit.elements == e)
        #expect(cache.isExpired(TileKey(x: 5, y: 5)))
    }

    // MARK: Provider (source chain)

    @Test func sourceChainIsCacheThenPackThenLive() async throws {
        let clock = TestClock()
        let dir = Fixtures.tempDir()
        let e = try OverpassParser.parse(OSMSamples.overpass)
        let inPack = TileKey(x: 1893, y: 3305)
        let inCacheAndPack = TileKey(x: 1894, y: 3305)
        let liveOnly = TileKey(x: 1895, y: 3305)

        let writer = try RoadPackWriter(scratch: dir.appendingPathComponent("blobs"))
        try writer.add(inPack, json: OverpassParser.encode(e))
        var packCopy = e
        packCopy.ways.removeLast()
        try writer.add(inCacheAndPack, json: OverpassParser.encode(packCopy))
        try writer.finish(to: dir.appendingPathComponent("p.spurpack"),
                          header: RoadPackHeader(area: "T", source: "t", sourceDate: "x", createdAt: "x", bbox: inPack.bbox, tileCount: 0))
        let pack = try RoadPack(url: dir.appendingPathComponent("p.spurpack"))
        let cache = RoadTileCache(directory: dir.appendingPathComponent("cache"), now: { clock.now })
        try cache.write(inCacheAndPack, elements: e)

        let transport = FakeTransport([.body(OSMSamples.overpass)])
        let provider = RoadTileProvider(cache: cache, pack: pack, client: Self.client(transport, clock), now: { clock.now })
        let updates = await provider.updates()

        let first = await provider.lookup([inPack, inCacheAndPack, liveOnly])
        #expect(first.sources == [inPack: .pack, inCacheAndPack: .cache])
        #expect(first.missing == [liveOnly])
        #expect(await !provider.needsLive(inPack))
        #expect(await provider.needsLive(liveOnly))

        await provider.want([inPack, inCacheAndPack, liveOnly])
        var it = updates.makeAsyncIterator()
        #expect(await it.next() == liveOnly)
        #expect(transport.count == 1) // only the tile no local source has
        #expect(cache.contains(liveOnly))
        let second = await provider.lookup([liveOnly])
        #expect(second.missing.isEmpty)
    }

    @Test func noRequestLeavesThePhoneWhenTheInternetSettingIsOff() async throws {
        let clock = TestClock()
        let transport = FakeTransport([.body(OSMSamples.overpass)])
        let provider = RoadTileProvider(cache: RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now }), pack: nil,
                                        client: Self.client(transport, clock), liveEnabled: false, now: { clock.now })
        await provider.want([TileKey(x: 9, y: 9)])
        let result = await provider.preload(lat: 32.7767, lon: -96.797, radius: 3000) { _, _ in }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.count == 0)
        #expect(result.available == 0 && result.failed == result.total)
    }
}

/// The pack this build bundles (built by scripts/build-osm-pack.sh; the app also works without one).
struct BundledPackTests {
    @Test func theBundledPackReadsWhenPresent() throws {
        guard let pack = RoadPack.bundled() else { return }
        #expect(pack.header.area == "Dallas")
        #expect(pack.header.tileCount == pack.tiles.count)
        let downtown = TileKey.containing(lat: 32.7767, lon: -96.797)
        #expect(pack.covers(downtown))
        let e = try #require(try pack.elements(for: downtown))
        #expect(e.ways.count > 100)
        #expect(e.nodes.contains { $0.tags?["highway"] == "traffic_signals" })
    }
}

struct TileRetryTests {
    /// SPEC 14.2: a failed live tile is retried later by itself, without the car changing tile.
    @Test func aFailedTileIsRetriedLater() async throws {
        let clock = TestClock()
        let transport = FakeTransport(Array(repeating: .status(503), count: 9) + [.body(OSMSamples.overpass)])
        let client = OverpassClient(transport: transport, now: { clock.now }, sleep: { clock.sleep($0) })
        let provider = RoadTileProvider(cache: RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now }), pack: nil,
                                        client: client, now: { clock.now }, sleep: { clock.sleep($0) })
        let updates = await provider.updates()
        let key = TileKey(x: 1900, y: 3300)
        await provider.want([key])
        var it = updates.makeAsyncIterator()
        let arrived = await it.next()
        #expect(arrived == key)
        #expect(transport.count == 10)
        #expect(await provider.isAvailable(key))
    }
}

/// SPEC 14.5: a trip analyzed while a tile was missing is analyzed again when the tile arrives.
struct ReanalysisTests {
    @Test func aTripIsAnalyzedAgainWhenItsMissingTileArrives() async throws {
        let c = try OracleCase.load(6)
        let fixes = RoadAnalysisTests.fixes(c.drives[0])
        // A trip on disk, finished, with the case 6 fixes.
        let store = TripStore(root: Fixtures.tempDir())
        var record = TripRecord(startedAt: fixes[0].date, isRecording: false)
        record.endedAt = fixes.last!.date
        try store.create(record)
        let writer = try store.openWriter(record.id)
        for f in fixes { try writer.append(f) }
        writer.close()
        // No pack, an empty cache, Overpass answering with the fixture after one failed call.
        let clock = TestClock()
        let fixture = try TestResources.data("downtown-grid")
        let transport = FakeTransport(Array(repeating: .status(503), count: 9) + Array(repeating: .body(fixture), count: 20))
        let client = OverpassClient(transport: transport, now: { clock.now }, sleep: { clock.sleep($0) })
        let settings = Settings(defaults: UserDefaults(suiteName: "spur-tests-\(UUID().uuidString)")!)
        let service = RoadService(store: store, settings: settings, pack: nil,
                                  cache: RoadTileCache(directory: Fixtures.tempDir(), now: { clock.now }), client: client,
                                  now: { clock.now }, sleep: { clock.sleep($0) })
        service.reanalysisDelay = .milliseconds(50)
        service.trips = { [(try? store.load(record.id))].compactMap { $0 } }

        service.analyze(record.id)
        var final: RoadStatistics?
        var first: RoadStatistics?
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(50))
            let r = try store.load(record.id).roads
            if first == nil, let r { first = r }
            if let r, r.missingTiles == nil, r.counts.signalSites > 0 {
                final = r
                break
            }
        }
        let missing = try #require(first?.missingTiles)
        #expect(!missing.isEmpty, "the first analysis had no road data")
        let done = try #require(final, "the trip was not analyzed again after its tiles arrived")
        print("REANALYSIS first run missing \(missing.count) tiles, second run signal sites \(done.counts.signalSites), live tiles \(done.tilesFromCache), Overpass requests \(transport.count)")
        #expect(done.counts.signalSites == 7)
        #expect(done.tilesFromCache == missing.count)
    }
}
