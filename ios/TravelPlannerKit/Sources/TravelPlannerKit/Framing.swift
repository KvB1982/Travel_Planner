import Foundation

/// What the organiser may change about the frame of a trip. Region and budget can be cleared, so they are always sent.
public struct TripChanges: Encodable, Hashable, Sendable {
    public var title: String
    public var region: String?
    public var adults: Int
    public var children: Int
    public var pets: Int
    public var budgetTotalCents: Int?
    /// nil switches the flexible window off. Only sent when `sendsFlex` is set, so older callers leave it alone.
    public var flex: FlexWindow?
    public var sendsFlex = false

    public init(title: String, region: String?, adults: Int, children: Int, pets: Int, budgetTotalCents: Int?) {
        self.title = title; self.region = region; self.adults = adults; self.children = children; self.pets = pets
        self.budgetTotalCents = budgetTotalCents
    }

    public init(_ trip: Trip) {
        self.init(title: trip.title, region: trip.region, adults: trip.adults, children: trip.children, pets: trip.pets, budgetTotalCents: trip.budgetTotalCents)
        flex = trip.flexWindow
    }

    enum CodingKeys: String, CodingKey { case title, region, adults, children, pets, budgetTotalCents, flexStart, flexEnd, nightsMin, nightsMax }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(region, forKey: .region); try c.encode(adults, forKey: .adults)
        try c.encode(children, forKey: .children); try c.encode(pets, forKey: .pets); try c.encode(budgetTotalCents, forKey: .budgetTotalCents)
        if sendsFlex {
            // Both days go together; both null switches the window off.
            try c.encode(flex?.start, forKey: .flexStart); try c.encode(flex?.end, forKey: .flexEnd)
            try c.encode(flex?.nightsMin, forKey: .nightsMin); try c.encode(flex?.nightsMax, forKey: .nightsMax)
        }
    }
}

/// One line of the chronicle of a trip.
public struct ActivityEvent: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var createdAt: Date?
    public var userName: String?
    /// The numbers and words the server noted with the event; everything else is left out.
    public var numbers: [String: Double]
    public var words: [String: String]

    public init(id: String, type: String, createdAt: Date? = nil, userName: String? = nil, numbers: [String: Double] = [:], words: [String: String] = [:]) {
        self.id = id; self.type = type; self.createdAt = createdAt; self.userName = userName; self.numbers = numbers; self.words = words
    }

    enum CodingKeys: String, CodingKey { case id, type, createdAt, userName, payload }
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) { id = text }
        else if let number = try? c.decode(Int.self, forKey: .id) { id = String(number) }
        else { id = UUID().uuidString }
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        userName = try? c.decodeIfPresent(String.self, forKey: .userName)
        var numbers: [String: Double] = [:], words: [String: String] = [:]
        if let payload = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .payload) {
            for key in payload.allKeys {
                if let number = try? payload.decode(Double.self, forKey: key) { numbers[key.stringValue] = number }
                else if let word = try? payload.decode(String.self, forKey: key) { words[key.stringValue] = word }
            }
        }
        self.numbers = numbers; self.words = words
    }

    /// The event as a sentence, without the name of who did it.
    public var sentence: String {
        func count(_ key: String, _ one: String, _ many: String) -> String {
            guard let value = numbers[key].map({ Int($0) }) else { return many }
            return value == 1 ? "1 \(one)" : "\(value) \(many)"
        }
        let amount = numbers["amountCents"].map { " über \(Format.euroExact(cents: Int($0)))" } ?? ""
        switch type {
        case "trip_created": return "hat die Reise angelegt"
        case "candidate_added": return "hat ein Angebot hinzugefügt" + (words["platform"].map { " (\(Format.platformName($0)))" } ?? "")
        case "candidate_removed": return "hat ein Angebot gelöscht"
        case "candidate_moved_away": return "hat ein Angebot in eine andere Reise verschoben"
        case "candidate_moved_in": return "hat ein Angebot hierher verschoben"
        case "candidate_status":
            return "hat ein Angebot als „\(words["status"].flatMap(CandidateStatus.init(rawValue:))?.label ?? "geändert")“ markiert"
        case "source_added": return "hat eine weitere Quelle ergänzt" + (words["platform"].map { " (\(Format.platformName($0)))" } ?? "")
        case "vote": return numbers["veto"] == 1 ? "hat ein Veto eingelegt" : "hat abgestimmt"
        case "comment": return "hat kommentiert"
        case "criteria_changed": return "hat die Kriterien geändert (\(count("count", "Kriterium", "Kriterien")))"
        case "availability_checked": return "hat Verfügbarkeit und Preise geprüft (\(count("candidates", "Angebot", "Angebote")))"
        case "pitch_opened": return "hat die Entscheidungsrunde eröffnet (\(count("finalists", "Finalist", "Finalisten")))"
        case "ranking_set": return "hat eine Rangfolge abgegeben"
        case "decision_made": return "hat die Entscheidung festgehalten"
        case "decision_withdrawn": return "hat die Entscheidung zurückgenommen"
        case "parties_changed": return "hat die Haushalte der Kasse geändert"
        case "expense_added": return "hat eine Ausgabe\(amount) eingetragen"
        case "expense_removed": return "hat eine Ausgabe\(amount) gelöscht"
        case "payment_noted": return "hat eine Ausgleichszahlung\(amount) abgehakt"
        case "booking_added": return "hat eine Buchung eingetragen" + (words["kind"].flatMap(BookingKind.init(rawValue:)).map { " (\($0.label))" } ?? "")
        case "booking_removed": return "hat eine Buchung gelöscht"
        case "document_added": return "hat ein Dokument hochgeladen"
        case "document_removed": return "hat ein Dokument gelöscht"
        default: return "hat etwas geändert"
        }
    }
}
