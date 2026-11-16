import Foundation

/// What the group needs to know at the house: how to get in, the Wi-Fi, who to call.
public struct House: Decodable, Hashable, Sendable {
    public var address: String?
    public var lat: Double?
    public var lon: Double?
    public var checkInFrom: String?
    public var checkOutUntil: String?
    public var keyInfo: String?
    public var wifiName: String?
    public var wifiPassword: String?
    public var contactName: String?
    public var contactPhone: String?
    public var rules: String?
    public var waste: String?
    public var emergency: String?
    public var notes: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case address, lat, lon, checkInFrom, checkOutUntil, keyInfo, wifiName, wifiPassword, contactName, contactPhone, rules, waste, emergency, notes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        address = text(.address); checkInFrom = text(.checkInFrom); checkOutUntil = text(.checkOutUntil); keyInfo = text(.keyInfo)
        wifiName = text(.wifiName); wifiPassword = text(.wifiPassword); contactName = text(.contactName); contactPhone = text(.contactPhone)
        rules = text(.rules); waste = text(.waste); emergency = text(.emergency); notes = text(.notes)
        lat = (try? c.decodeIfPresent(Double.self, forKey: .lat)) ?? nil
        lon = (try? c.decodeIfPresent(Double.self, forKey: .lon)) ?? nil
    }

    /// The text fields in the order they are shown and edited.
    public struct Field: Identifiable, Hashable, Sendable {
        public var key: String
        public var label: String
        public var symbol: String
        /// Long texts get room for several lines.
        public var long: Bool
        public var id: String { key }
    }

    public static let fields: [Field] = [
        Field(key: "address", label: "Adresse", symbol: "mappin.and.ellipse", long: false),
        Field(key: "checkInFrom", label: "Anreise ab", symbol: "arrow.down.to.line", long: false),
        Field(key: "checkOutUntil", label: "Abreise bis", symbol: "arrow.up.to.line", long: false),
        Field(key: "keyInfo", label: "Schlüssel", symbol: "key", long: true),
        Field(key: "wifiName", label: "WLAN", symbol: "wifi", long: false),
        Field(key: "wifiPassword", label: "WLAN-Passwort", symbol: "lock", long: false),
        Field(key: "contactName", label: "Ansprechperson", symbol: "person", long: false),
        Field(key: "contactPhone", label: "Telefon", symbol: "phone", long: false),
        Field(key: "rules", label: "Hausregeln", symbol: "list.bullet.clipboard", long: true),
        Field(key: "waste", label: "Müll", symbol: "trash", long: true),
        Field(key: "emergency", label: "Notfall", symbol: "cross.case", long: true),
        Field(key: "notes", label: "Sonstiges", symbol: "note.text", long: true),
    ]

    public func text(_ key: String) -> String? {
        let value: String?
        switch key {
        case "address": value = address
        case "checkInFrom": value = checkInFrom
        case "checkOutUntil": value = checkOutUntil
        case "keyInfo": value = keyInfo
        case "wifiName": value = wifiName
        case "wifiPassword": value = wifiPassword
        case "contactName": value = contactName
        case "contactPhone": value = contactPhone
        case "rules": value = rules
        case "waste": value = waste
        case "emergency": value = emergency
        case "notes": value = notes
        default: value = nil
        }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    public mutating func set(_ key: String, _ value: String?) {
        switch key {
        case "address": address = value
        case "checkInFrom": checkInFrom = value
        case "checkOutUntil": checkOutUntil = value
        case "keyInfo": keyInfo = value
        case "wifiName": wifiName = value
        case "wifiPassword": wifiPassword = value
        case "contactName": contactName = value
        case "contactPhone": contactPhone = value
        case "rules": rules = value
        case "waste": waste = value
        case "emergency": emergency = value
        case "notes": notes = value
        default: break
        }
    }
}

public struct HouseBook: Decodable, Hashable, Sendable {
    /// What fact sheet and booking already know, offered for empty fields.
    public struct Suggestions: Decodable, Hashable, Sendable {
        public var title: String?
        public var address: String?
        public var lat: Double?
        public var lon: Double?
        public var checkInFrom: String?
        public var checkOutUntil: String?
        public var arrival: String?
        public var departure: String?
        public var reference: String?
        public init(title: String? = nil, address: String? = nil, lat: Double? = nil, lon: Double? = nil, checkInFrom: String? = nil,
                    checkOutUntil: String? = nil, arrival: String? = nil, departure: String? = nil, reference: String? = nil) {
            self.title = title; self.address = address; self.lat = lat; self.lon = lon; self.checkInFrom = checkInFrom
            self.checkOutUntil = checkOutUntil; self.arrival = arrival; self.departure = departure; self.reference = reference
        }

        public func text(_ key: String) -> String? {
            switch key {
            case "address": address
            case "checkInFrom": checkInFrom
            case "checkOutUntil": checkOutUntil
            default: nil
            }
        }
    }
    public var house: House
    public var suggestions: Suggestions

    public init(house: House = House(), suggestions: Suggestions = Suggestions()) { self.house = house; self.suggestions = suggestions }

    enum CodingKeys: String, CodingKey { case house, suggestions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        house = ((try? c.decodeIfPresent(House.self, forKey: .house)) ?? nil) ?? House()
        suggestions = ((try? c.decodeIfPresent(Suggestions.self, forKey: .suggestions)) ?? nil) ?? Suggestions()
    }

    /// Only what differs from the book, emptied fields as null.
    public func changes(typed: [String: String]) -> [String: PatchValue] {
        var result: [String: PatchValue] = [:]
        for field in House.fields {
            let new = (typed[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard new != (house.text(field.key) ?? "") else { continue }
            result[field.key] = new.isEmpty ? .null : .text(new)
        }
        return result
    }
}

/// One day on the road: what happens today.
public struct TripDay: Decodable, Hashable, Sendable {
    public struct BookingMark: Decodable, Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: BookingKind
        public var title: String
        public var startsAt: String?
        public var endsAt: String?
        public var place: String?
        public var reference: String?
        public var begins: Bool?
        public var ends: Bool?
        public init(id: String, kind: BookingKind = .accommodation, title: String, startsAt: String? = nil, endsAt: String? = nil, place: String? = nil,
                    reference: String? = nil, begins: Bool? = nil, ends: Bool? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.startsAt = startsAt; self.endsAt = endsAt; self.place = place
            self.reference = reference; self.begins = begins; self.ends = ends
        }
        enum CodingKeys: String, CodingKey { case id, kind, title, startsAt, endsAt, place, reference, begins, ends }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = (try? c.decode(BookingKind.self, forKey: .kind)) ?? .other
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Buchung"
            startsAt = try? c.decodeIfPresent(String.self, forKey: .startsAt); endsAt = try? c.decodeIfPresent(String.self, forKey: .endsAt)
            place = try? c.decodeIfPresent(String.self, forKey: .place); reference = try? c.decodeIfPresent(String.self, forKey: .reference)
            begins = try? c.decodeIfPresent(Bool.self, forKey: .begins); ends = try? c.decodeIfPresent(Bool.self, forKey: .ends)
        }
    }
    public var date: String
    public var arrivalDay: Bool
    public var departureDay: Bool
    public var legs: [TravelLeg]
    public var activities: [Activity]
    public var bookings: [BookingMark]
    /// Ideas without a date, waiting to be planned.
    public var ideas: Int

    public init(date: String, arrivalDay: Bool = false, departureDay: Bool = false, legs: [TravelLeg] = [], activities: [Activity] = [],
                bookings: [BookingMark] = [], ideas: Int = 0) {
        self.date = date; self.arrivalDay = arrivalDay; self.departureDay = departureDay; self.legs = legs; self.activities = activities
        self.bookings = bookings; self.ideas = ideas
    }

    enum CodingKeys: String, CodingKey { case date, arrivalDay, departureDay, legs, activities, bookings, ideas }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        arrivalDay = (try? c.decodeIfPresent(Bool.self, forKey: .arrivalDay)) ?? false
        departureDay = (try? c.decodeIfPresent(Bool.self, forKey: .departureDay)) ?? false
        legs = (try? c.decodeIfPresent([TravelLeg].self, forKey: .legs)) ?? []
        activities = (try? c.decodeIfPresent([Activity].self, forKey: .activities)) ?? []
        bookings = (try? c.decodeIfPresent([BookingMark].self, forKey: .bookings)) ?? []
        ideas = (try? c.decodeIfPresent(Int.self, forKey: .ideas)) ?? 0
    }

    public var isEmpty: Bool { legs.isEmpty && activities.isEmpty && bookings.isEmpty && !arrivalDay && !departureDay }
}
