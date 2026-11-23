import Foundation

/// Offers of one trip side by side: one row per property, one value per offer.
public struct Comparison: Sendable, Equatable {
    public struct Row: Identifiable, Sendable, Equatable {
        public var id: String
        public var label: String
        /// One entry per offer, in the order of `Comparison.offers`. `nil` means not known.
        public var values: [String?]
        /// Positions of the best value, when "best" has a meaning (lowest price, most bedrooms, ...).
        /// Empty when every known value is equally good or the row cannot be ranked.
        public var best: Set<Int>
        /// False when all offers show the same thing, so the row tells nothing apart.
        public var differs: Bool
        /// Printed under the row, for example why a price is left out of the ranking.
        public var note: String?
    }

    public struct Section: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var rows: [Row]
    }

    public var offers: [CandidateDetail]
    public var sections: [Section]

    private enum Better { case lower, higher }

    public init(offers: [CandidateDetail], persons: Int?) {
        self.offers = offers
        let profiles = offers.map(\.listing.profile)

        func text(_ id: String, _ label: String, _ values: [String?], note: String? = nil) -> Row {
            let cleaned = values.map { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            return Row(id: id, label: label, values: cleaned, best: [], differs: Set(cleaned).count > 1, note: note)
        }

        func number(_ id: String, _ label: String, _ numbers: [Double?], _ better: Better?, note: String? = nil,
                    format: (Double) -> String) -> Row {
            var row = text(id, label, numbers.map { $0.map(format) }, note: note)
            let known = numbers.enumerated().compactMap { index, value in value.map { (index, $0) } }
            // A winner needs something to win against: at least two known values that are not all the same.
            if let better, known.count > 1, Set(known.map(\.1)).count > 1 {
                let target = better == .lower ? known.map(\.1).min() : known.map(\.1).max()
                row.best = Set(known.filter { $0.1 == target }.map(\.0))
            }
            return row
        }

        // The price that counts is the one asked for this trip; any other price is shown but not ranked.
        let prices: [PriceSnapshot?] = offers.map { offer in
            offer.prices.first { $0.tripId == offer.candidate.tripId && $0.totalCents != nil }
        }
        let otherPrices: [PriceSnapshot?] = offers.enumerated().map { index, offer in
            prices[index] == nil ? offer.prices.first { $0.totalCents != nil } : nil
        }
        // Compared is always the price for the whole group, whatever each offer was asked for.
        let shares = offers.map(\.share)
        let splits = shares.contains { $0.splits }
        let totals = offers.indices.map { index in shares[index].group(prices[index]?.totalCents).map(Double.init) }
        let shownTotals: [String?] = offers.indices.map { index in
            let share = shares[index]
            if let price = prices[index] {
                return Format.price(totalCents: share.group(price.totalCents), rangeMaxCents: share.group(price.rangeMaxCents), kind: price.kind)
            }
            if let other = otherPrices[index],
               let text = Format.price(totalCents: share.group(other.totalCents), rangeMaxCents: share.group(other.rangeMaxCents), kind: other.kind) {
                return "(\(text))"
            }
            return nil
        }
        var priceRow = number("price", splits ? "Gesamtpreis der Gruppe" : "Gesamtpreis", totals, .lower) { Format.euro(cents: Int($0)) }
        priceRow.values = shownTotals
        priceRow.differs = Set(shownTotals).count > 1
        var notes: [String] = []
        if otherPrices.contains(where: { $0 != nil }) { notes.append("Preise in Klammern gelten für einen anderen Zeitraum und zählen nicht für den Vergleich.") }
        if shares.contains(where: { $0.perHousehold }) { notes.append("Preise, die je Haushalt abgefragt wurden, sind auf die Gruppe hochgerechnet.") }
        if !notes.isEmpty { priceRow.note = notes.joined(separator: " ") }
        let perHousehold: [Double?] = offers.indices.map { index in shares[index].household(prices[index]?.totalCents).map(Double.init) }
        let perHead: [Double?] = offers.indices.map { index in
            guard let price = prices[index], let asked = price.totalCents, let nights = price.nights, nights > 0 else { return nil }
            // With the travellers of the trip the group's price is what gets shared; a price asked for one household
            // without them is shared among the people it was asked for.
            if let persons, persons > 0, let total = shares[index].group(asked) { return (Double(total) / Double(persons * nights)).rounded() }
            guard let people = price.persons, people > 0 else { return nil }
            return (Double(asked) / Double(people * nights)).rounded()
        }
        let dates = offers.indices.map { index -> String? in
            let price = prices[index] ?? otherPrices[index]
            let range = Format.dateRange(price?.startDate, price?.endDate)
            guard let range, let nights = price?.nights, nights > 0 else { return range }
            return "\(range) · \(nights == 1 ? "1 Nacht" : "\(nights) Nächte")"
        }
        // With a flexible window the stays differ in length, so the price per night is what compares.
        let perNight: [Double?] = offers.indices.map { index in
            guard let price = prices[index], let total = shares[index].group(price.totalCents), let nights = price.nights, nights > 0 else { return nil }
            return (Double(total) / Double(nights)).rounded()
        }
        let ratings: [Double?] = profiles.map { profile in
            guard let value = profile.rating?.value else { return nil }
            // Platforms rate out of 5 or out of 10; ten is assumed above 5 when the scale is missing.
            let scale = profile.rating?.scale ?? (value > 5 ? 10 : 5)
            // Brought to a common scale of ten, to one decimal, so 4,5 of 5 and 9,0 of 10 tie.
            return scale > 0 ? (value / scale * 100).rounded() / 10 : nil
        }
        var ratingRow = number("rating", "Bewertung", ratings, .higher) { Format.number($0) }
        ratingRow.values = profiles.map { profile in
            guard let value = profile.rating?.value else { return nil }
            let scale = profile.rating?.scale.map { " von \(Format.number($0))" } ?? ""
            let count = profile.rating?.count.map { " (\(Format.number($0)))" } ?? ""
            return "\(Format.number(value))\(scale)\(count)"
        }
        ratingRow.differs = Set(ratingRow.values).count > 1

        var sections: [Section] = []
        sections.append(Section(id: "price", title: "Preis", rows: [
            priceRow,
        ] + (splits ? [number("perHousehold", "Je Haushalt", perHousehold, nil) { Format.euro(cents: Int($0)) }] : []) + [
            // Shown, but not counted as a win of its own: total and price per person and night already are.
            number("perNight", "Pro Nacht", perNight, nil) { Format.euro(cents: Int($0)) },
            number("perHead", "Pro Person und Nacht", perHead, .lower) { Format.euro(cents: Int($0)) },
            text("dates", "Zeitraum des Preises", dates),
            number("deposit", "Kaution", profiles.map { $0.price?.depositEur }, nil) { Format.euro($0) },
            text("cancel", "Stornierung", profiles.map(\.cancellation)),
        ]))
        sections.append(Section(id: "group", title: "Eure Gruppe", rows: [
            text("status", "Status", offers.map { $0.candidate.status.label }),
            number("yes", "Ja-Stimmen", offers.map { Double($0.votes.yes) }, .higher) { Format.number($0) },
            number("maybe", "Vielleicht", offers.map { Double($0.votes.maybe) }, nil) { Format.number($0) },
            number("no", "Nein-Stimmen", offers.map { Double($0.votes.no) }, .lower) { Format.number($0) },
            text("veto", "Veto", offers.map { $0.votes.vetoes > 0 ? "Ja" : nil }),
        ]))
        sections.append(Section(id: "reviews", title: "Bewertungen", rows: [
            ratingRow,
            text("praise", "Gelobt", offers.map { $0.reviews?.positives?.joined(separator: ", ") }),
            text("critique", "Kritisiert", offers.map { $0.reviews?.negatives?.joined(separator: ", ") }),
        ]))
        sections.append(Section(id: "size", title: "Größe", rows: [
            text("type", "Art", offers.map { $0.listing.profile.objectType ?? $0.listing.kind.label }),
            number("guests", "Gäste", profiles.map(\.maxGuests), .higher) { Format.number($0) },
            number("bedrooms", "Schlafzimmer", profiles.map(\.bedrooms), .higher) { Format.number($0) },
            number("beds", "Betten", profiles.map(\.beds), .higher) { Format.number($0) },
            number("baths", "Bäder", profiles.map(\.bathrooms), .higher) { Format.number($0) },
            number("area", "Wohnfläche", profiles.map(\.livingAreaSqm), .higher) { "\(Format.number($0)) m²" },
            number("plot", "Grundstück", profiles.map(\.plotSqm), .higher) { "\(Format.number($0)) m²" },
        ]))
        sections.append(Section(id: "place", title: "Lage", rows: [
            text("where", "Ort", offers.map { [$0.listing.place, $0.listing.country].compactMap { $0 }.joined(separator: ", ") }),
            number("beach", "Strand", profiles.map { $0.distances?.beachM ?? $0.distances?.seaM }, .lower) { Format.distance(meters: $0) },
            number("town", "Ort (Entfernung)", profiles.map { $0.distances?.townM }, .lower) { Format.distance(meters: $0) },
            number("shop", "Einkaufen", profiles.map { $0.distances?.shopM }, .lower) { Format.distance(meters: $0) },
            number("restaurant", "Restaurant", profiles.map { $0.distances?.restaurantM }, .lower) { Format.distance(meters: $0) },
            number("airport", "Flughafen", profiles.map { $0.distances?.airportKm }, .lower) { "\(Format.number($0)) km" },
        ]))
        // Yes counts as the better answer for every amenity; "Nein" and "unbekannt" are kept apart on purpose.
        let amenityRows = Profile.amenityKeys.map { key -> Row in
            let answers = profiles.map { $0.amenity(key) }
            var row = text("amenity.\(key)", Format.amenityName(key), answers.map { $0.map { $0 ? "Ja" : "Nein" } })
            let yes = Set(answers.enumerated().filter { $0.element == true }.map(\.offset))
            if !yes.isEmpty, yes.count < answers.count { row.best = yes }
            return row
        }
        sections.append(Section(id: "amenities", title: "Ausstattung", rows: amenityRows))
        sections.append(Section(id: "rules", title: "Regeln", rows: [
            text("checkIn", "Anreise ab", profiles.map { $0.rules?.checkInFrom }),
            text("checkOut", "Abreise bis", profiles.map { $0.rules?.checkOutUntil }),
            text("arrival", "Anreisetage", profiles.map { $0.rules?.arrivalDays }),
            number("minNights", "Mindestaufenthalt", profiles.map { $0.rules?.minNights }, nil) { "\(Format.number($0)) Nächte" },
        ]))

        // Rows nobody has an answer for only add length.
        self.sections = sections.compactMap { section in
            let rows = section.rows.filter { row in row.values.contains { $0 != nil } }
            return rows.isEmpty ? nil : Section(id: section.id, title: section.title, rows: rows)
        }
    }

    /// The same comparison with only the rows that tell the offers apart.
    public func differencesOnly() -> Comparison {
        var copy = self
        copy.sections = sections.compactMap { section in
            let rows = section.rows.filter(\.differs)
            return rows.isEmpty ? nil : Section(id: section.id, title: section.title, rows: rows)
        }
        return copy
    }

    /// How often each offer holds a best value, as a rough pointer, not a verdict.
    public var wins: [Int] {
        offers.indices.map { index in sections.flatMap(\.rows).filter { $0.best.contains(index) }.count }
    }
}
