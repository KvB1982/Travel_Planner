import Foundation

/// The offers of a trip sorted into sections by country and, where known, region.
public struct OfferGroup: Identifiable, Equatable, Sendable {
    public var country: String?
    public var region: String?
    public var offers: [CandidateSummary]

    public var id: String { "\(country ?? "?")|\(region ?? "")" }

    /// "Italien · Toskana", "Kroatien", or a plain label for offers whose advert names no country.
    public var title: String {
        guard let country else { return "Land unbekannt" }
        return region.map { "\(country) · \($0)" } ?? country
    }
}

public enum OfferGrouping {
    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func country(of offer: CandidateSummary) -> String? { clean(offer.listing.country) }

    /// The countries that occur, in alphabetical order.
    public static func countries(in offers: [CandidateSummary]) -> [String] {
        Set(offers.compactMap(country(of:))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Sections by country, then region; inside a section the offers keep the order they came in.
    /// Offers without a country go last. A country is only split by region when it has more than one.
    public static func groups(_ offers: [CandidateSummary]) -> [OfferGroup] {
        var byCountry: [String?: [CandidateSummary]] = [:]
        for offer in offers { byCountry[country(of: offer), default: []].append(offer) }
        let order = byCountry.keys.sorted { a, b in
            switch (a, b) {
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?): return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        var result: [OfferGroup] = []
        for country in order {
            let members = byCountry[country] ?? []
            let regions = Set(members.compactMap { clean($0.listing.region) })
            guard country != nil, regions.count > 1 else {
                result.append(OfferGroup(country: country, region: regions.count == 1 && members.allSatisfy { clean($0.listing.region) != nil } ? regions.first : nil,
                                         offers: members))
                continue
            }
            var byRegion: [String?: [CandidateSummary]] = [:]
            for offer in members { byRegion[clean(offer.listing.region), default: []].append(offer) }
            let regionOrder = byRegion.keys.sorted { a, b in
                switch (a, b) {
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
            }
            for region in regionOrder {
                result.append(OfferGroup(country: country, region: region, offers: byRegion[region] ?? []))
            }
        }
        return result
    }
}

public extension Format {
    /// The flag for a country as adverts name it in German or English; nil when the name is not known.
    static func flag(forCountry name: String?) -> String? {
        guard let key = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else { return nil }
        let codes: [String: String] = [
            "deutschland": "DE", "germany": "DE", "österreich": "AT", "austria": "AT", "schweiz": "CH", "switzerland": "CH",
            "italien": "IT", "italy": "IT", "italia": "IT", "frankreich": "FR", "france": "FR", "spanien": "ES", "spain": "ES", "españa": "ES",
            "portugal": "PT", "kroatien": "HR", "croatia": "HR", "hrvatska": "HR", "slowenien": "SI", "slovenia": "SI",
            "griechenland": "GR", "greece": "GR", "türkei": "TR", "turkey": "TR", "dänemark": "DK", "denmark": "DK", "danmark": "DK",
            "schweden": "SE", "sweden": "SE", "norwegen": "NO", "norway": "NO", "finnland": "FI", "finland": "FI",
            "niederlande": "NL", "netherlands": "NL", "holland": "NL", "belgien": "BE", "belgium": "BE", "luxemburg": "LU",
            "polen": "PL", "poland": "PL", "tschechien": "CZ", "czechia": "CZ", "ungarn": "HU", "hungary": "HU",
            "großbritannien": "GB", "vereinigtes königreich": "GB", "united kingdom": "GB", "england": "GB", "irland": "IE", "ireland": "IE",
            "island": "IS", "iceland": "IS", "malta": "MT", "zypern": "CY", "cyprus": "CY", "montenegro": "ME", "albanien": "AL",
            "bulgarien": "BG", "rumänien": "RO", "usa": "US", "vereinigte staaten": "US", "united states": "US", "kanada": "CA", "canada": "CA",
            "marokko": "MA", "ägypten": "EG", "thailand": "TH", "mexiko": "MX",
        ]
        guard let code = codes[key] else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
}

public enum PictureQuality {
    /// What a Check24 picture address shows, told from the address packed into its `source=` part.
    public enum Check24Kind: Equatable, Sendable { case hotel, guest, map }

    /// The `source=` part of a Check24 picture address: the same picture carries the same one in every size.
    public static func check24Source(_ address: String) -> String? {
        guard let parts = URLComponents(string: address), parts.host?.contains("check24") == true else { return nil }
        return packedSource(in: parts.path)
    }

    /// The Base64 text after `/source=`. It ends at the `!` that starts the signature (which differs from size
    /// to size), or at the next `/`.
    private static func packedSource(in text: String) -> String? {
        guard let start = text.range(of: "/source=") else { return nil }
        let packed = text[start.upperBound...].prefix { $0 != "!" && $0 != "/" && $0 != "?" }
        return packed.isEmpty ? nil : String(packed)
    }

    /// The width a Check24 address asks for (`size=1920x`), or 0.
    public static func check24Width(_ address: String) -> Int {
        guard let parts = URLComponents(string: address) else { return 0 }
        guard let size = parts.path.split(separator: "/").map(String.init).first(where: { $0.hasPrefix("size=") }) else { return 0 }
        return Int(size.dropFirst(5).prefix { $0.isNumber }) ?? 0
    }

    public static func check24Kind(_ address: String) -> Check24Kind? {
        guard var packed = check24Source(address) else { return nil }
        // The source is an address in Base64, which may pack another one inside: unpack up to three times.
        var seen = ""
        for _ in 0..<3 {
            var padded = packed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded), let text = String(data: data, encoding: .utf8) else { break }
            seen += " " + text
            guard let inner = packedSource(in: text) else { break }
            packed = inner
        }
        let all = seen.lowercased()
        if all.contains("maps.google") || all.contains("staticmap") { return .map }
        if all.contains("cts-ratings") || all.contains("travellerpictures") { return .guest }
        return .hotel
    }

    /// From everything collected on a Check24 page: the hotel's own pictures only, each once in its widest
    /// version, in the order they came, at most `limit`. Guest photos and maps are left out.
    public static func check24Selection(_ addresses: [String], limit: Int) -> [String] {
        var order: [String] = [], best: [String: String] = [:]
        for address in addresses {
            guard let source = check24Source(address), check24Kind(address) == .hotel else { continue }
            if let known = best[source] {
                if check24Width(address) > check24Width(known) { best[source] = address }
            } else {
                order.append(source); best[source] = address
            }
        }
        return order.prefix(limit).compactMap { best[$0] }
    }

    /// Whether a picture address of Check24 names only a preview: its `size=` step is narrower than 600.
    /// Check24 signs every size on its own, so a larger version only exists once a device has seen its address.
    public static func isSmallCheck24(_ address: String?) -> Bool {
        guard let address, let parts = URLComponents(string: address), parts.host?.contains("check24") == true else { return false }
        let places = parts.path.split(separator: "/").map(String.init) + (parts.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
        guard let size = places.first(where: { $0.hasPrefix("size=") }) else { return false }
        let digits = size.dropFirst(5).prefix { $0.isNumber }
        guard let width = Int(digits) else { return false }
        return width < 600
    }
}
