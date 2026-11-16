import Foundation

/// How a household gets there and back.
public struct TravelLeg: Decodable, Identifiable, Hashable, Sendable {
    public struct Stop: Codable, Hashable, Sendable {
        public var place: String
        public var note: String?
        public init(place: String, note: String? = nil) { self.place = place; self.note = note }
    }
    public var id: String
    public var partyId: String?
    /// "outbound", "return" or "during".
    public var direction: String
    /// "car", "flight", "train", "ferry", "bus" or "other".
    public var mode: String
    public var fromPlace: String?
    public var toPlace: String?
    public var departAt: String?
    public var arriveAt: String?
    public var stops: [Stop]
    public var notes: String?

    public init(id: String, partyId: String? = nil, direction: String = "outbound", mode: String = "car", fromPlace: String? = nil, toPlace: String? = nil,
                departAt: String? = nil, arriveAt: String? = nil, stops: [Stop] = [], notes: String? = nil) {
        self.id = id; self.partyId = partyId; self.direction = direction; self.mode = mode; self.fromPlace = fromPlace; self.toPlace = toPlace
        self.departAt = departAt; self.arriveAt = arriveAt; self.stops = stops; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, partyId, direction, mode, fromPlace, toPlace, departAt, arriveAt, stops, notes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        partyId = try? c.decodeIfPresent(String.self, forKey: .partyId)
        direction = (try? c.decodeIfPresent(String.self, forKey: .direction)) ?? "outbound"
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "other"
        fromPlace = try? c.decodeIfPresent(String.self, forKey: .fromPlace)
        toPlace = try? c.decodeIfPresent(String.self, forKey: .toPlace)
        departAt = try? c.decodeIfPresent(String.self, forKey: .departAt)
        arriveAt = try? c.decodeIfPresent(String.self, forKey: .arriveAt)
        stops = (try? c.decodeIfPresent([Stop].self, forKey: .stops)) ?? []
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
    }

    public static let directions = [("outbound", "Hinreise"), ("return", "Rückreise"), ("during", "Unterwegs")]
    public static let modes = [("car", "Auto", "car"), ("flight", "Flug", "airplane"), ("train", "Bahn", "tram"), ("ferry", "Fähre", "ferry"),
                               ("bus", "Bus", "bus"), ("other", "Sonstiges", "figure.walk")]
    public var directionLabel: String { Self.directions.first { $0.0 == direction }?.1 ?? direction }
    public var modeLabel: String { Self.modes.first { $0.0 == mode }?.1 ?? "Sonstiges" }
    public var modeSymbol: String { Self.modes.first { $0.0 == mode }?.2 ?? "figure.walk" }
}

public struct LegDraft: Encodable, Hashable, Sendable {
    public var partyId: String?
    public var direction: String
    public var mode: String
    public var fromPlace: String?
    public var toPlace: String?
    public var departAt: String?
    public var arriveAt: String?
    public var stops: [TravelLeg.Stop]
    public var notes: String?

    public init(partyId: String? = nil, direction: String = "outbound", mode: String = "car", fromPlace: String? = nil, toPlace: String? = nil,
                departAt: String? = nil, arriveAt: String? = nil, stops: [TravelLeg.Stop] = [], notes: String? = nil) {
        self.partyId = partyId; self.direction = direction; self.mode = mode; self.fromPlace = fromPlace; self.toPlace = toPlace
        self.departAt = departAt; self.arriveAt = arriveAt; self.stops = stops; self.notes = notes
    }

    // Emptied fields go as null, so a change can clear them.
    enum CodingKeys: String, CodingKey { case partyId, direction, mode, fromPlace, toPlace, departAt, arriveAt, stops, notes }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(partyId, forKey: .partyId); try c.encode(direction, forKey: .direction); try c.encode(mode, forKey: .mode)
        try c.encode(fromPlace, forKey: .fromPlace); try c.encode(toPlace, forKey: .toPlace); try c.encode(departAt, forKey: .departAt)
        try c.encode(arriveAt, forKey: .arriveAt); try c.encode(stops, forKey: .stops); try c.encode(notes, forKey: .notes)
    }
}

public struct Room: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var beds: String?
    public var partyId: String?
    public var occupants: [String]
    public var notes: String?

    public init(id: String, name: String, beds: String? = nil, partyId: String? = nil, occupants: [String] = [], notes: String? = nil) {
        self.id = id; self.name = name; self.beds = beds; self.partyId = partyId; self.occupants = occupants; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, name, beds, partyId, occupants, notes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Zimmer"
        beds = try? c.decodeIfPresent(String.self, forKey: .beds)
        partyId = try? c.decodeIfPresent(String.self, forKey: .partyId)
        occupants = (try? c.decodeIfPresent([String].self, forKey: .occupants)) ?? []
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
    }
}

public struct RoomDraft: Encodable, Hashable, Sendable {
    public var name: String
    public var beds: String?
    public var partyId: String?
    public var occupants: [String]
    public var notes: String?
    public init(name: String, beds: String? = nil, partyId: String? = nil, occupants: [String] = [], notes: String? = nil) {
        self.name = name; self.beds = beds; self.partyId = partyId; self.occupants = occupants; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case name, beds, partyId, occupants, notes }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(beds, forKey: .beds); try c.encode(partyId, forKey: .partyId)
        try c.encode(occupants, forKey: .occupants); try c.encode(notes, forKey: .notes)
    }

    /// Names as people type them in one line: "Oma, Opa und Lina".
    public static func names(from text: String) -> [String] {
        text.replacingOccurrences(of: " und ", with: ",").split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct Activity: Decodable, Identifiable, Hashable, Sendable {
    public struct Response: Decodable, Hashable, Sendable {
        public var userId: String?
        public var name: String?
        public var answer: String?
        public init(userId: String? = nil, name: String? = nil, answer: String? = nil) { self.userId = userId; self.name = name; self.answer = answer }
    }
    public struct Tally: Decodable, Hashable, Sendable {
        public var yes: Int?
        public var maybe: Int?
        public var no: Int?
        public init(yes: Int? = 0, maybe: Int? = 0, no: Int? = 0) { self.yes = yes; self.maybe = maybe; self.no = no }
    }
    public var id: String
    public var title: String
    public var place: String?
    public var url: String?
    /// "idea", "planned", "done" or "cancelled".
    public var status: String
    public var startsAt: String?
    public var endsAt: String?
    public var costCents: Int?
    public var costNote: String?
    public var notes: String?
    public var responses: [Response]
    public var tally: Tally
    public var myAnswer: String?

    public init(id: String, title: String, place: String? = nil, url: String? = nil, status: String = "idea", startsAt: String? = nil, endsAt: String? = nil,
                costCents: Int? = nil, costNote: String? = nil, notes: String? = nil, responses: [Response] = [], tally: Tally = Tally(), myAnswer: String? = nil) {
        self.id = id; self.title = title; self.place = place; self.url = url; self.status = status; self.startsAt = startsAt; self.endsAt = endsAt
        self.costCents = costCents; self.costNote = costNote; self.notes = notes; self.responses = responses; self.tally = tally; self.myAnswer = myAnswer
    }

    enum CodingKeys: String, CodingKey { case id, title, place, url, status, startsAt, endsAt, costCents, costNote, notes, responses, tally, myAnswer }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Aktivität"
        place = try? c.decodeIfPresent(String.self, forKey: .place)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "idea"
        startsAt = try? c.decodeIfPresent(String.self, forKey: .startsAt)
        endsAt = try? c.decodeIfPresent(String.self, forKey: .endsAt)
        costCents = try? c.decodeIfPresent(Int.self, forKey: .costCents)
        costNote = try? c.decodeIfPresent(String.self, forKey: .costNote)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        responses = (try? c.decodeIfPresent([Response].self, forKey: .responses)) ?? []
        tally = (try? c.decodeIfPresent(Tally.self, forKey: .tally)) ?? Tally()
        myAnswer = try? c.decodeIfPresent(String.self, forKey: .myAnswer)
    }

    public static let statuses = [("idea", "Idee"), ("planned", "geplant"), ("done", "gemacht"), ("cancelled", "abgesagt")]
    public var statusLabel: String { Self.statuses.first { $0.0 == status }?.1 ?? status }
}

public struct ActivityDraft: Encodable, Hashable, Sendable {
    public var title: String
    public var place: String?
    public var url: String?
    public var status: String
    public var startsAt: String?
    public var endsAt: String?
    public var costCents: Int?
    public var costNote: String?
    public var notes: String?
    public init(title: String, place: String? = nil, url: String? = nil, status: String = "idea", startsAt: String? = nil, endsAt: String? = nil,
                costCents: Int? = nil, costNote: String? = nil, notes: String? = nil) {
        self.title = title; self.place = place; self.url = url; self.status = status; self.startsAt = startsAt; self.endsAt = endsAt
        self.costCents = costCents; self.costNote = costNote; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case title, place, url, status, startsAt, endsAt, costCents, costNote, notes }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(place, forKey: .place); try c.encode(url, forKey: .url); try c.encode(status, forKey: .status)
        try c.encode(startsAt, forKey: .startsAt); try c.encode(endsAt, forKey: .endsAt); try c.encode(costCents, forKey: .costCents)
        try c.encode(costNote, forKey: .costNote); try c.encode(notes, forKey: .notes)
    }
}

public struct TripPlan: Decodable, Hashable, Sendable {
    public var legs: [TravelLeg]
    public var rooms: [Room]
    public var activities: [Activity]
    public init(legs: [TravelLeg] = [], rooms: [Room] = [], activities: [Activity] = []) { self.legs = legs; self.rooms = rooms; self.activities = activities }

    enum CodingKeys: String, CodingKey { case legs, rooms, activities }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legs = (try? c.decodeIfPresent([TravelLeg].self, forKey: .legs)) ?? []
        rooms = (try? c.decodeIfPresent([Room].self, forKey: .rooms)) ?? []
        activities = (try? c.decodeIfPresent([Activity].self, forKey: .activities)) ?? []
    }
}
