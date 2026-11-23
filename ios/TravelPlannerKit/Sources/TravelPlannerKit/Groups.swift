import Foundation

/// People who travel together again and again. Every trip of the group is open to all its members.
public struct TravelGroup: Decodable, Identifiable, Hashable, Sendable {
    public struct Member: Decodable, Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// "admin" or "member".
        public var role: String
        public var joinedAt: Date?
        public init(id: String, name: String, role: String = "member", joinedAt: Date? = nil) { self.id = id; self.name = name; self.role = role; self.joinedAt = joinedAt }
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
    /// The watchlist all members of the group see and keep.
    public var watchlistId: String?
    public var isAdmin: Bool { role == "admin" }

    public init(id: String, name: String, role: String = "member", members: [Member] = [], trips: [TripRef] = [], watchlistId: String? = nil) {
        self.id = id; self.name = name; self.role = role; self.members = members; self.trips = trips; self.watchlistId = watchlistId
    }

    enum CodingKeys: String, CodingKey { case id, name, role, members, trips, watchlistId }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Gruppe"
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "member"
        members = (try? c.decodeIfPresent([Member].self, forKey: .members)) ?? []
        trips = (try? c.decodeIfPresent([TripRef].self, forKey: .trips)) ?? []
        watchlistId = try? c.decodeIfPresent(String.self, forKey: .watchlistId)
    }
}

/// An invite link into a group that has not been used up. The link itself is shown only once, when it is made.
public struct GroupInvite: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date?
    public var expiresAt: Date?
    public var maxUses: Int?
    public var usedCount: Int?
    /// For an invite to a trip: the role it grants ("member" or "guest").
    public var role: String?
    public init(id: String, createdAt: Date? = nil, expiresAt: Date? = nil, maxUses: Int? = nil, usedCount: Int? = nil, role: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.expiresAt = expiresAt; self.maxUses = maxUses; self.usedCount = usedCount; self.role = role
    }

    /// "gültig bis 7. Dez. · 0 von 1 genutzt", for lists of open invites.
    public var summary: String {
        var parts: [String] = []
        if let expiresAt { parts.append("gültig bis \(expiresAt.formatted(.dateTime.day().month().locale(Locale(identifier: "de_DE"))))") }
        if let maxUses { parts.append("\(usedCount ?? 0) von \(maxUses) genutzt") }
        if role == "guest" { parts.append("als Gast") }
        return parts.joined(separator: " · ")
    }
}

/// How trips are laid out wherever one is picked: every group with its trips and its watchlist, then what is private.
public struct TripShelf: Hashable, Sendable {
    public struct Section: Identifiable, Hashable, Sendable {
        /// The group's id, or "private".
        public var id: String
        public var title: String
        public var group: TravelGroup?
        public var trips: [Trip]
        public var watchlist: Trip?
        public init(id: String, title: String, group: TravelGroup?, trips: [Trip], watchlist: Trip?) {
            self.id = id; self.title = title; self.group = group; self.trips = trips; self.watchlist = watchlist
        }
    }
    public var sections: [Section]
    public var archived: [Trip]

    /// `includeArchived: false` leaves the archive out, for lists of destinations.
    public init(trips: [Trip], groups: [TravelGroup]) {
        let live = trips.filter { $0.status != .archived || $0.isWatchlist }
        var sections: [Section] = []
        // Groups the server lists, then groups only known from their trips (an older server, or a list not loaded yet).
        var known = groups.map { ($0.id, $0.name, Optional($0)) }
        for trip in live {
            if let id = trip.groupId, !known.contains(where: { $0.0 == id }) { known.append((id, trip.groupName ?? "Gruppe", nil)) }
        }
        for (id, name, group) in known {
            let own = live.filter { $0.groupId == id }
            sections.append(Section(id: id, title: name, group: group, trips: own.filter { !$0.isWatchlist }, watchlist: own.first(where: \.isWatchlist)))
        }
        let personal = live.filter { $0.groupId == nil }
        if !personal.isEmpty || sections.isEmpty {
            sections.append(Section(id: "private", title: sections.isEmpty ? "Reisen" : "Privat", group: nil,
                                    trips: personal.filter { !$0.isWatchlist }, watchlist: personal.first(where: \.isWatchlist)))
        }
        self.sections = sections
        self.archived = trips.filter { $0.status == .archived && !$0.isWatchlist }
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
    /// The length of stay the group would like best, between the two; nil when any length is as good as another.
    public var nightsPreferred: Int?
    public init(start: String, end: String, nightsMin: Int, nightsMax: Int, nightsPreferred: Int? = nil) {
        self.start = start; self.end = end; self.nightsMin = nightsMin; self.nightsMax = nightsMax; self.nightsPreferred = nightsPreferred
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
        let wish = nightsPreferred.flatMap { nightsMin == nightsMax ? nil : ", am liebsten \($0)" } ?? ""
        return "\(nights)\(wish) zwischen \(range)"
    }
}

public extension Trip {
    /// Whether another trip in the same place already carries this name. Names are unique within a group, and among
    /// a person's private trips; case and surrounding spaces do not count, archived trips do.
    static func nameTaken(_ name: String, inGroup groupId: String?, among trips: [Trip], except id: String? = nil) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        return trips.contains {
            $0.id != id && !$0.isWatchlist && $0.groupId == groupId && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }
}
