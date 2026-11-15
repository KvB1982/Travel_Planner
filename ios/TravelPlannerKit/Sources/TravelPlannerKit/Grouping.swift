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
