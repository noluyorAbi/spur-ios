import MapKit
import Observation

/// Search for the Planen tab (SPEC 18.3): suggestions while typing, then results with their
/// places, and for one place the driving time. Queries go to Apple only.
@MainActor @Observable
final class SearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" { didSet { completer.queryFragment = query } }
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var results: [MKMapItem] = []
    private(set) var searching = false
    private(set) var failed = false
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Biases suggestions to the visible map.
    func setRegion(_ region: MKCoordinateRegion) { completer.region = region }

    // The completer calls its delegate on the main thread, where it was created.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        nonisolated(unsafe) let c = completer
        MainActor.assumeIsolated { self.suggestions = Array(c.results.prefix(8)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { self.suggestions = [] }
    }

    func search(_ completion: MKLocalSearchCompletion? = nil, region: MKCoordinateRegion?) async {
        let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? {
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = query
            return r
        }()
        if let region { request.region = region }
        searching = true
        failed = false
        defer { searching = false }
        do {
            results = try await MKLocalSearch(request: request).start().mapItems
            suggestions = []
        } catch {
            results = []
            failed = true
        }
    }

    func clear() {
        query = ""
        suggestions = []
        results = []
        failed = false
    }

    /// The driving route from the current position to an item, nil when there is none.
    static func route(to item: MKMapItem, from origin: CLLocationCoordinate2D?) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? MKMapItem.forCurrentLocation()
        request.destination = item
        request.transportType = .automobile
        return try? await MKDirections(request: request).calculate().routes.first
    }
}

/// A route shown in Spur (SPEC 18.3 "Route in Spur zeigen"): on the live map over the coverage
/// layer, with a chip on the Fahrt tab to remove it.
struct PlannedRoute: Equatable {
    var name: String
    var coordinates: [CLLocationCoordinate2D]
    var seconds: TimeInterval
    var meters: Double

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.seconds == b.seconds && a.meters == b.meters && a.coordinates.count == b.coordinates.count
    }

    /// A discovery route (SPEC 18.5), with its waypoints for the live map.
    var waypoints: [CLLocationCoordinate2D] = []

    init(name: String, coordinates: [CLLocationCoordinate2D], seconds: TimeInterval, meters: Double, waypoints: [CLLocationCoordinate2D]) {
        self.name = name
        self.coordinates = coordinates
        self.seconds = seconds
        self.meters = meters
        self.waypoints = waypoints
    }

    init(name: String, route: MKRoute) {
        self.name = name
        let n = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: n)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        coordinates = coords
        seconds = route.expectedTravelTime
        meters = route.distance
    }
}

/// The hand-off to Google Maps: a URL with the destination only (SPEC 18.3 privacy).
enum GoogleMapsLink {
    static func url(destination c: CLLocationCoordinate2D) -> URL? {
        var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
        parts.queryItems = [URLQueryItem(name: "api", value: "1"),
                            URLQueryItem(name: "destination", value: String(format: "%.6f,%.6f", c.latitude, c.longitude)),
                            URLQueryItem(name: "travelmode", value: "driving")]
        return parts.url
    }
}
