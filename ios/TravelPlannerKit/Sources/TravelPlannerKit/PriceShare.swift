import Foundation

/// Whom a price is for, and how it turns into the price for the whole group or for one household.
/// Hotels are mostly asked for one household, houses for everyone. The conversion multiplies or divides by the
/// number of households, so with households of different sizes it is an estimate.
public struct PriceShare: Equatable, Sendable {
    /// True when the price as asked is for one household.
    public var perHousehold: Bool
    public var households: Int

    public init(basis: String?, households: Int?) {
        self.households = max(1, households ?? 1)
        self.perHousehold = basis == "household" && self.households > 1
    }

    /// Whether there is anything to tell apart: with one household every price is simply the price.
    public var splits: Bool { households > 1 }

    public func group(_ cents: Int?) -> Int? {
        cents.map { perHousehold ? $0 * households : $0 }
    }

    public func household(_ cents: Int?) -> Int? {
        cents.map { perHousehold ? $0 : Int((Double($0) / Double(households)).rounded()) }
    }

    /// Whether a price asked for `asked` people fits neither the whole party nor one household of it, so it is
    /// worth a warning. A price per household for about a household's share of the travellers is as expected.
    public func partyMismatch(asked: Int?, persons: Int?) -> Bool {
        guard let asked, let persons, asked != persons else { return false }
        guard perHousehold else { return true }
        let expected = Double(persons) / Double(households)
        return abs(Double(asked) - expected) > 1
    }

    /// A few words on where the group's price comes from.
    public var note: String {
        perHousehold ? "hochgerechnet aus dem Preis je Haushalt, mal \(households)" : "Preis für die ganze Gruppe, je Haushalt geteilt durch \(households)"
    }
}

public extension CandidateSummary {
    var share: PriceShare { PriceShare(basis: priceBasis, households: households) }

    /// The price of the offer for the whole group, as text; nil without a price.
    var groupPriceText: String? {
        guard let price else { return nil }
        return Format.price(totalCents: share.group(price.totalCents), rangeMaxCents: share.group(price.rangeMaxCents), kind: price.kind)
    }
}

public extension CandidateDetail {
    var share: PriceShare { PriceShare(basis: priceBasis, households: households) }
}
