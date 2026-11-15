import Foundation

public enum Format {
    private static let german = Locale(identifier: "de_DE")

    public static func euro(cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(german))
    }

    public static func euro(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(german))
    }

    /// "ab 2.400 €", "2.400 – 3.100 €" or "2.400 €".
    public static func price(totalCents: Int?, rangeMaxCents: Int?, kind: PriceKind) -> String? {
        guard let totalCents else { return nil }
        switch kind {
        case .from: return "ab \(euro(cents: totalCents))"
        case .range: return rangeMaxCents.map { "\(euro(cents: totalCents)) – \(euro(cents: $0))" } ?? euro(cents: totalCents)
        case .total: return euro(cents: totalCents)
        }
    }

    public static func perPersonNight(totalCents: Int?, persons: Int?, nights: Int?) -> String? {
        guard let totalCents, let persons, let nights, persons > 0, nights > 0 else { return nil }
        return "\(euro(cents: totalCents / (persons * nights))) pro Person und Nacht"
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func day(_ iso: String) -> Date? { dayParser.date(from: iso) }

    public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "22.05. – 05.06.2027"
    public static func dateRange(_ start: String?, _ end: String?) -> String? {
        guard let start, let end, let from = day(start), let to = day(end) else { return nil }
        let short = Date.FormatStyle(date: .omitted, time: .omitted, locale: german, timeZone: TimeZone(identifier: "UTC")!).day(.twoDigits).month(.twoDigits)
        let long = short.year()
        return "\(from.formatted(short)) – \(to.formatted(long))"
    }

    public static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(german))
    }

    public static func distance(meters: Double) -> String {
        meters >= 1000 ? "\(number(meters / 1000)) km" : "\(number(meters)) m"
    }

    public static func platformName(_ platform: String) -> String {
        switch platform {
        case "airbnb": "Airbnb"
        case "vrbo": "FeWo-direkt"
        case "novasol": "Novasol"
        case "check24": "Check24"
        case "casamundo": "Casamundo"
        case "booking": "Booking.com"
        default: "Andere Seite"
        }
    }

    public static func amenityName(_ key: String) -> String {
        switch key {
        case "pool": "Pool"
        case "poolHeated": "Pool beheizt"
        case "airConditioning": "Klimaanlage"
        case "wifi": "WLAN"
        case "dishwasher": "Spülmaschine"
        case "washingMachine": "Waschmaschine"
        case "grill": "Grill"
        case "fireplace": "Kamin"
        case "sauna": "Sauna"
        case "hotTub": "Whirlpool"
        case "parking": "Parkplatz"
        case "evCharger": "Wallbox"
        case "seaView": "Meerblick"
        case "cot": "Kinderbett"
        case "highChair": "Hochstuhl"
        case "fenced": "Eingezäunt"
        case "petsAllowed": "Haustiere erlaubt"
        default: key
        }
    }
}

public extension CandidateStatus {
    var label: String {
        switch self {
        case .new: "Neu"
        case .shortlist: "Engere Wahl"
        case .favorite: "Favorit"
        case .rejected: "Verworfen"
        case .booked: "Gebucht"
        }
    }
}

public extension Verdict {
    var label: String {
        switch self {
        case .yes: "Ja"
        case .maybe: "Vielleicht"
        case .no: "Nein"
        }
    }
}

public extension MemberRole {
    var label: String {
        switch self {
        case .organizer: "Organisation"
        case .member: "Mitglied"
        case .guest: "Gast"
        }
    }
}

public extension ListingKind {
    var label: String {
        switch self {
        case .vacationHome: "Ferienhaus"
        case .hotel: "Hotel"
        case .package: "Pauschalreise"
        }
    }
}
