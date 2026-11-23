import Foundation

/// People who travel together again and again. Every trip of the group is open to all its members.
public struct TravelGroup: Decodable, Identifiable, Hashable, Sendable {
    public struct Member: Decodable, Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// "admin" or "member".
        public var role: String
        public init(id: String, name: String, role: String = "member") { self.id = id; self.name = name; self.role = role }
        public var isAdmin: Bool { role == "admin" }
    }
    public struct TripRef: Decodable, Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public var id: String
    public var name: String
    /// The own role in the group.
    public var role: String
    public var members: [Member]
    public var trips: [TripRef]
    public var isAdmin: Bool { role == "admin" }

    public init(id: String, name: String, role: String = "member", members: [Member] = [], trips: [TripRef] = []) {
        self.id = id; self.name = name; self.role = role; self.members = members; self.trips = trips
    }

    enum CodingKeys: String, CodingKey { case id, name, role, members, trips }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Gruppe"
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "member"
        members = (try? c.decodeIfPresent([Member].self, forKey: .members)) ?? []
        trips = (try? c.decodeIfPresent([TripRef].self, forKey: .trips)) ?? []
    }
}

/// An advert only a device can read and no device has read yet.
public struct PendingReading: Decodable, Identifiable, Hashable, Sendable {
    public var candidateId: String
    public var tripId: String?
    public var platform: String?
    public var title: String?
    public var url: String
    public var id: String { candidateId }
    public init(candidateId: String, tripId: String? = nil, platform: String? = nil, title: String? = nil, url: String) {
        self.candidateId = candidateId; self.tripId = tripId; self.platform = platform; self.title = title; self.url = url
    }
}

/// One stay something is known about: a trip with a flexible window can have several per advert.
public struct Stay: Codable, Identifiable, Hashable, Sendable {
    public var startDate: String
    public var endDate: String
    public var nights: Int?
    public var totalCents: Int?
    public var perNightCents: Int?
    public var available: Bool?
    public var checkedAt: Date?
    /// The bookable stay with the lowest price per night.
    public var best: Bool?
    public var id: String { "\(startDate)|\(endDate)" }
    public init(startDate: String, endDate: String, nights: Int? = nil, totalCents: Int? = nil, perNightCents: Int? = nil,
                available: Bool? = nil, checkedAt: Date? = nil, best: Bool? = nil) {
        self.startDate = startDate; self.endDate = endDate; self.nights = nights; self.totalCents = totalCents
        self.perNightCents = perNightCents; self.available = available; self.checkedAt = checkedAt; self.best = best
    }
}

/// The flexible window of a trip: any stay inside it of an allowed length counts as a price for the trip.
public struct FlexWindow: Hashable, Sendable {
    /// Earliest day of arrival and latest day of departure, as `JJJJ-MM-TT`.
    public var start: String
    public var end: String
    public var nightsMin: Int
    public var nightsMax: Int
    public init(start: String, end: String, nightsMin: Int, nightsMax: Int) {
        self.start = start; self.end = end; self.nightsMin = nightsMin; self.nightsMax = nightsMax
    }

    /// Nights between the two days; nil when they are no dates.
    public var span: Int? {
        guard let from = Format.day(start), let to = Format.day(end) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: from, to: to).day
    }

    /// The window can hold a stay of the shortest allowed length.
    public var isValid: Bool {
        guard let span else { return false }
        return nightsMin >= 1 && nightsMax >= nightsMin && span >= nightsMin
    }

    /// Whether a stay lies inside the window and has an allowed length.
    public func holds(start stayStart: String, end stayEnd: String) -> Bool {
        guard let from = Format.day(stayStart), let to = Format.day(stayEnd),
              let nights = Calendar(identifier: .gregorian).dateComponents([.day], from: from, to: to).day else { return false }
        return stayStart >= start && stayEnd <= end && nights >= nightsMin && nights <= nightsMax
    }

    public var summary: String {
        let range = Format.dateRange(start, end) ?? "\(start) – \(end)"
        let nights = nightsMin == nightsMax ? (nightsMin == 1 ? "1 Nacht" : "\(nightsMin) Nächte") : "\(nightsMin) bis \(nightsMax) Nächte"
        return "\(nights) zwischen \(range)"
    }
}
