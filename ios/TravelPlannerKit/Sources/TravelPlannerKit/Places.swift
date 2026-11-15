import Foundation

/// Where an offer is, as far as the advert says: exact coordinates, or only a place name to look up.
public struct PlaceHint: Hashable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    /// "Castellina in Chianti, Toskana, Italien": what a map search can find when there are no coordinates.
    public var query: String?
    /// True when the coordinates are a guess of the advert or the server, not a stated position.
    public var uncertain: Bool

    public init(latitude: Double?, longitude: Double?, place: String?, region: String?, country: String?, uncertain: Bool = false) {
        // 0/0 is what broken data looks like, not a house in the Gulf of Guinea.
        let usable = latitude.map { (-90...90).contains($0) } == true && longitude.map { (-180...180).contains($0) } == true
            && !(latitude == 0 && longitude == 0)
        self.latitude = usable ? latitude : nil
        self.longitude = usable ? longitude : nil
        var parts: [String] = []
        for part in [place, region, country] {
            guard let text = part?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !parts.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { continue }
            parts.append(text)
        }
        query = parts.isEmpty ? nil : parts.joined(separator: ", ")
        self.uncertain = uncertain
    }

    public init(listing: Listing) {
        let profile = listing.profile
        self.init(latitude: listing.lat ?? profile.lat, longitude: listing.lon ?? profile.lon, place: listing.place ?? profile.place,
                  region: profile.region, country: listing.country ?? profile.country,
                  uncertain: profile.isUncertain("lat") || profile.isUncertain("lon"))
    }

    public init(summary: ListingSummary) {
        self.init(latitude: summary.lat, longitude: summary.lon, place: summary.place, region: nil, country: summary.country)
    }

    public var hasCoordinates: Bool { latitude != nil && longitude != nil }

    /// Nothing to go on at all.
    public var isEmpty: Bool { !hasCoordinates && query == nil }
}

public enum MapLinks {
    /// Opens Google Maps (the app when installed, otherwise the website) at a position or for a search.
    public static func googleMaps(latitude: Double? = nil, longitude: Double? = nil, query: String? = nil) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        let target: String
        if let latitude, let longitude {
            target = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        } else if let query, !query.isEmpty {
            target = query
        } else {
            return nil
        }
        components?.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: target)]
        return components?.url
    }
}
