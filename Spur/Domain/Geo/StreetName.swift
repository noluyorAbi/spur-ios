import Foundation

/// Street name from a reverse geocoding result (pure, tested).
///
/// MapKit's iOS 26 `MKAddress.shortAddress` reads "<street line>, <city>", for example
/// "1313 Jackson St, Dallas" or "Marienplatz 7-11, München". The street is the first comma
/// separated part without a leading or trailing house number token. A first part that equals
/// the city, or has no letters, means no street was found.
nonisolated enum StreetName {
    static func from(shortAddress: String?, city: String?) -> String? {
        guard let shortAddress else { return nil }
        guard let first = shortAddress.split(separator: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty
        else { return nil }
        if let city, first.caseInsensitiveCompare(city) == .orderedSame { return nil }

        var tokens = first.split(whereSeparator: \.isWhitespace).map(String.init)
        var strippedLeading = false
        while let t = tokens.first, isHouseNumber(t), tokens.count > 1 {
            tokens.removeFirst()
            strippedLeading = true
        }
        // A house number sits either before the street (US) or after it (Germany), never both.
        // A number after a route word ("Highway 75", "FM 2551", "County Rd 470") is part of the name.
        if !strippedLeading {
            while tokens.count > 1, let t = tokens.last, isHouseNumber(t),
                  !routeWords.contains(tokens[tokens.count - 2].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                tokens.removeLast()
            }
        }
        let street = tokens.joined(separator: " ")
        guard street.contains(where: \.isLetter) else { return nil }
        return street
    }

    /// Words after which a number names a route, not a house.
    static let routeWords: Set<String> = [
        "highway", "hwy", "route", "rte", "road", "rd", "fm", "rm", "interstate", "i", "us", "sh",
        "loop", "spur", "beltway", "state", "county", "b", "a", "bundesstraße", "staatsstraße",
        "landesstraße", "kreisstraße",
    ]

    /// "12", "12a", "7-11", "7\u{2013}11", "1/2": starts with a digit and is short.
    static func isHouseNumber(_ token: String) -> Bool {
        guard let c = token.first, c.isNumber else { return false }
        return token.count <= 9
    }
}
