import CoreLocation
import Foundation
import MapKit

/// Reverse geocoding with MapKit (iOS 26 `MKReverseGeocodingRequest`). Failures are silent:
/// the result is nil and recording is never affected.
final class PlaceGeocoder {
    private var inFlight: MKReverseGeocodingRequest?

    var isBusy: Bool { inFlight != nil }

    func sample(_ fix: Fix, kind: PlaceSample.Kind) async -> PlaceSample? {
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "de_DE")
        inFlight = request
        defer { inFlight = nil }
        guard let item = try? await request.mapItems.first else { return nil }
        let city = item.addressRepresentations?.cityName
        let street = StreetName.from(shortAddress: item.address?.shortAddress, city: city)
        return PlaceSample(
            timestampMs: fix.timestampMs, latitude: fix.latitude, longitude: fix.longitude,
            kind: kind, locality: city, street: street
        )
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}
