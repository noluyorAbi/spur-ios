import Foundation

/// The parent's road query (`src/lib/osm/overpass.ts`, `buildRoadsQuery`) for one box: the kept
/// road classes, the feature nodes, and (without their nodes) the other kept ways that share a
/// node with a road of the box, so junctions at tile edges are complete. Pure.
nonisolated enum OverpassQuery {
    static let roadClasses = [
        "motorway", "trunk", "primary", "secondary", "tertiary",
        "unclassified", "residential", "living_street",
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    ]
    static let excludedService = ["parking_aisle", "driveway", "drive-through"]
    static let nodeHighwayValues = ["traffic_signals", "stop", "give_way", "crossing", "mini_roundabout", "motorway_junction"]
    /// Server side limit in seconds, below the client's 60 s.
    static let serverTimeout = 50

    /// A coordinate as a plain decimal with at most 9 decimals (parent `coord`).
    static func coord(_ v: Double) -> String {
        var text = String(format: "%.9f", v)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    static func boxArgs(_ b: BBox) -> String { "(" + b.array.map(coord).joined(separator: ",") + ")" }

    static func roads(_ b: BBox) -> String {
        let box = boxArgs(b)
        let roads = "^(\(roadClasses.joined(separator: "|")))$"
        let service = "^(\(excludedService.joined(separator: "|")))$"
        let nodes = "^(\(nodeHighwayValues.joined(separator: "|")))$"
        return [
            "[out:json][timeout:\(serverTimeout)];",
            "(",
            "  way[\"highway\"~\"\(roads)\"]\(box);",
            "  way[\"highway\"=\"service\"][\"service\"!~\"\(service)\"]\(box);",
            ")->.roads;",
            "(",
            "  .roads;",
            "  node[\"highway\"~\"\(nodes)\"]\(box);",
            "  node[\"railway\"=\"level_crossing\"]\(box);",
            ");",
            "(._;>;);",
            "out body;",
            "node(w.roads)->.roadNodes;",
            "(",
            "  way(bn.roadNodes)[\"highway\"~\"\(roads)\"];",
            "  way(bn.roadNodes)[\"highway\"=\"service\"][\"service\"!~\"\(service)\"];",
            ")->.neighbours;",
            "(.neighbours; - .roads;);",
            "out body;",
        ].joined(separator: "\n")
    }

    /// The form body Overpass expects: `data=<query>`, percent encoded.
    static func body(for key: TileKey) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = roads(key.bbox).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return Data("data=\(q)".utf8)
    }
}

/// Sends one HTTP request. Injected so tests never touch the network.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = OverpassClient.timeout
        config.timeoutIntervalForResource = OverpassClient.timeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

nonisolated enum OverpassClientError: Error, Equatable {
    /// Every endpoint failed; `retryAt` is when the client accepts calls again.
    case unavailable(retryAt: Date)
    /// The client is still backing off after earlier failures; nothing was sent.
    case coolingDown(until: Date)
}

/// Live Overpass for tiles the pack does not cover (SPEC 14.2).
///
/// - Endpoints with failover: overpass-api.de, maps.mail.ru, overpass.private.coffee,
///   overpass.kumi.systems. The one that answered last goes first; one that answered with an error
///   (5xx, 429) goes last for 5 min, and one that timed out is left out for 5 min while another
///   is available, so no tile waits 60 s on a dead server again (2026-11-17: two timed out on
///   every request, one tile took 378 s).
/// - One request at a time and at most one per 2 s, across all callers.
/// - 429, 502, 503, 504, timeouts and network errors move on to the next endpoint; when all failed
///   the call waits 2 s, then 4 s, and tries a third and last round. After a failed call the client
///   backs off for 30 s, doubling per further failed call up to 10 min; a success resets it.
/// - Timeout 60 s per request. `User-Agent: Spur/1.1 (iOS)`, no other identifying header.
/// - Only the tile's bounding box is sent, never a fix or the track.
actor OverpassClient {
    static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]
    static let userAgent = "Spur/1.1 (iOS)"
    static let timeout: TimeInterval = 60
    static let minSpacing: TimeInterval = 2
    static let rounds = 3
    static let roundBackoff: [TimeInterval] = [2, 4]
    static let callBackoffBase: TimeInterval = 30
    static let callBackoffMax: TimeInterval = 600
    static let retryableStatus: Set<Int> = [429, 502, 503, 504]
    static let endpointPenalty: TimeInterval = 300

    private let transport: HTTPTransport
    private let endpoints: [URL]
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lastRequestAt: Date?
    private var failedCalls = 0
    private(set) var coolingUntil: Date?
    /// The endpoint that answered last: tried first.
    private(set) var preferred: URL?
    /// Endpoints that answered with an error recently: tried last until then.
    private var penalizedUntil: [URL: Date] = [:]
    /// Endpoints that timed out recently: left out until then while another is available.
    private var silentUntil: [URL: Date] = [:]

    /// This round's order: the last good endpoint, the others as configured, the ones that erred
    /// last; the ones that timed out left out, unless no other is left.
    func order() -> [URL] {
        let t = now()
        let silent = endpoints.filter { (silentUntil[$0] ?? .distantPast) > t }
        let awake = endpoints.filter { !silent.contains($0) }
        let pool = awake.isEmpty ? endpoints : awake
        let bad = pool.filter { (penalizedUntil[$0] ?? .distantPast) > t }
        var good = pool.filter { !bad.contains($0) }
        if let p = preferred, let i = good.firstIndex(of: p) { good.insert(good.remove(at: i), at: 0) }
        return good + bad
    }

    private func penalize(_ endpoint: URL) { penalizedUntil[endpoint] = now().addingTimeInterval(Self.endpointPenalty) }
    private func silence(_ endpoint: URL) { silentUntil[endpoint] = now().addingTimeInterval(Self.endpointPenalty) }

    init(transport: HTTPTransport = URLSessionTransport(), endpoints: [URL] = OverpassClient.endpoints,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport
        self.endpoints = endpoints
        self.now = now
        self.sleep = sleep
    }

    static func request(_ endpoint: URL, key: TileKey) -> URLRequest {
        var r = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpShouldHandleCookies = false
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = OverpassQuery.body(for: key)
        return r
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    /// Fetches one tile's road data and returns its elements. Throws `OverpassClientError`.
    func fetch(_ key: TileKey) async throws -> OSMElements {
        await acquire()
        defer { release() }
        if let until = coolingUntil, now() < until { throw OverpassClientError.coolingDown(until: until) }

        for round in 0..<Self.rounds {
            if round > 0 { try await sleep(Self.roundBackoff[min(round - 1, Self.roundBackoff.count - 1)]) }
            var anyRetryable = false
            for endpoint in order() {
                try Task.checkCancellation()
                if let last = lastRequestAt {
                    let wait = Self.minSpacing - now().timeIntervalSince(last)
                    if wait > 0 { try await sleep(wait) }
                }
                lastRequestAt = now()
                do {
                    let (data, http) = try await transport.send(Self.request(endpoint, key: key))
                    if http.statusCode == 200 {
                        do {
                            let elements = try OverpassParser.parse(data)
                            failedCalls = 0
                            coolingUntil = nil
                            preferred = endpoint
                            penalizedUntil[endpoint] = nil
                            silentUntil[endpoint] = nil
                            return elements
                        } catch OverpassParseError.runtimeError {
                            anyRetryable = true // the server ran out of time: worth another round
                            penalize(endpoint)
                        } catch {
                            continue // not Overpass JSON: try the next endpoint, not again
                        }
                    } else if Self.retryableStatus.contains(http.statusCode) {
                        anyRetryable = true
                        penalize(endpoint)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    anyRetryable = true // timeout or network error
                    silence(endpoint)
                }
            }
            if !anyRetryable { break }
        }
        // Cancelled during the last endpoint: not the servers' fault, so no client cool-down.
        if Task.isCancelled { throw CancellationError() }
        failedCalls += 1
        let wait = min(Self.callBackoffMax, Self.callBackoffBase * pow(2, Double(failedCalls - 1)))
        let until = now().addingTimeInterval(wait)
        coolingUntil = until
        throw OverpassClientError.unavailable(retryAt: until)
    }
}
