import Foundation

/// The order of the offer list.
public enum OfferSort: String, CaseIterable, Sendable, Identifiable {
    case added, price, rating, criteria, votes
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .added: "Zuletzt hinzugefügt"
        case .price: "Preis, günstigste zuerst"
        case .rating: "Bewertung, beste zuerst"
        case .criteria: "Kriterien, passendste zuerst"
        case .votes: "Stimmen, beliebteste zuerst"
        }
    }

    /// Sorts without losing anything: offers that lack the value sorted by come last, in their old order.
    public func sorted(_ offers: [CandidateSummary]) -> [CandidateSummary] {
        func ordered<Value: Comparable>(_ value: (CandidateSummary) -> Value?, ascending: Bool) -> [CandidateSummary] {
            let indexed = Array(offers.enumerated())
            return indexed.sorted { a, b in
                switch (value(a.element), value(b.element)) {
                case let (x?, y?): return x == y ? a.offset < b.offset : (ascending ? x < y : x > y)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }
        switch self {
        case .added:
            return offers
        case .price:
            // Only a price for the trip's dates is a price to compare; an unavailable offer has none.
            return ordered({ $0.isUnavailable || $0.price?.forThisTrip != true ? nil : $0.price?.totalCents }, ascending: true)
        case .rating:
            return ordered({ offer -> Double? in
                guard let value = offer.listing.rating?.value else { return nil }
                let scale = offer.listing.rating?.scale ?? (value > 5 ? 10 : 5)
                return scale > 0 ? value / scale : nil
            }, ascending: false)
        case .criteria:
            return ordered({ offer -> Int? in
                guard let verdict = offer.criteria else { return nil }
                // Light first, then fewer missed musts, then more wishes met.
                return verdict.rank * 10_000 + (verdict.must?.missed ?? 0) * 100 - (verdict.wish?.met ?? 0)
            }, ascending: true)
        case .votes:
            return ordered({ $0.votes.total == 0 ? nil : $0.votes.yes * 2 + $0.votes.maybe - $0.votes.no * 2 - $0.votes.vetoes * 10 }, ascending: false)
        }
    }
}
