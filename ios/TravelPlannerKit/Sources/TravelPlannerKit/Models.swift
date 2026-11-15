import Foundation

// Mirrors docs/API.md and the response shapes in backend/src/routes.
// Calendar dates ("2027-05-22") stay strings: they are days, not moments in time.

public enum MemberRole: String, Codable, Sendable, CaseIterable {
    case organizer, member, guest

    public var canEdit: Bool { self != .guest }
}

public enum TripStatus: String, Codable, Sendable, CaseIterable {
    case planning, decided, booked, archived
}

public enum ListingKind: String, Codable, Sendable {
    case vacationHome = "vacation_home"
    case hotel
    case package
}

public enum CandidateStatus: String, Codable, Sendable, CaseIterable {
    case new, shortlist, favorite, rejected, booked
}

public enum ImportStatus: String, Codable, Sendable {
    case pending, ready, partial, failed
}

public enum Verdict: String, Codable, Sendable, CaseIterable {
    case yes, maybe, no
}

public enum PriceKind: String, Codable, Sendable {
    case total, from, range
}

public struct User: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var email: String?

    public init(id: String, name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}

public struct Trip: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var region: String?
    public var adults: Int
    public var children: Int
    public var pets: Int
    public var budgetTotalCents: Int?
    public var status: TripStatus
    public var voteDeadline: Date?
    public var createdAt: Date
    /// Only present in the list of trips.
    public var role: MemberRole?
    public var candidateCount: Int?
    public var favoriteCount: Int?

    public var persons: Int { adults + children }

    public init(id: String, title: String, region: String? = nil, adults: Int = 2, children: Int = 0, pets: Int = 0,
                budgetTotalCents: Int? = nil, status: TripStatus = .planning, voteDeadline: Date? = nil, createdAt: Date = .now,
                role: MemberRole? = nil, candidateCount: Int? = nil, favoriteCount: Int? = nil) {
        self.id = id; self.title = title; self.region = region; self.adults = adults; self.children = children; self.pets = pets
        self.budgetTotalCents = budgetTotalCents; self.status = status; self.voteDeadline = voteDeadline; self.createdAt = createdAt
        self.role = role; self.candidateCount = candidateCount; self.favoriteCount = favoriteCount
    }
}

public struct DateOption: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var startDate: String
    public var endDate: String

    public init(id: String, label: String? = nil, startDate: String, endDate: String) {
        self.id = id; self.label = label; self.startDate = startDate; self.endDate = endDate
    }
}

public struct Member: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: MemberRole
    public var joinedAt: Date?

    public init(id: String, name: String, role: MemberRole, joinedAt: Date? = nil) {
        self.id = id; self.name = name; self.role = role; self.joinedAt = joinedAt
    }
}

public struct TripDetail: Codable, Hashable, Sendable {
    public var trip: Trip
    public var role: MemberRole
    public var members: [Member]
    public var dateOptions: [DateOption]

    public init(trip: Trip, role: MemberRole, members: [Member], dateOptions: [DateOption]) {
        self.trip = trip; self.role = role; self.members = members; self.dateOptions = dateOptions
    }
}

public struct NewTrip: Codable, Sendable {
    public struct Dates: Codable, Sendable {
        public var label: String?
        public var startDate: String
        public var endDate: String
        public init(label: String? = nil, startDate: String, endDate: String) {
            self.label = label; self.startDate = startDate; self.endDate = endDate
        }
    }
    public var title: String
    public var region: String?
    public var adults: Int
    public var children: Int
    public var pets: Int
    public var budgetTotalCents: Int?
    public var dateOptions: [Dates]

    public init(title: String, region: String? = nil, adults: Int = 2, children: Int = 0, pets: Int = 0, budgetTotalCents: Int? = nil, dateOptions: [Dates] = []) {
        self.title = title; self.region = region; self.adults = adults; self.children = children; self.pets = pets
        self.budgetTotalCents = budgetTotalCents; self.dateOptions = dateOptions
    }
}

public struct Rating: Codable, Hashable, Sendable {
    public var value: Double?
    public var scale: Double?
    public var count: Double?
    public init(value: Double? = nil, scale: Double? = nil, count: Double? = nil) {
        self.value = value; self.scale = scale; self.count = count
    }
}

public struct VoteTally: Codable, Hashable, Sendable {
    public var yes: Int
    public var maybe: Int
    public var no: Int
    public var vetoes: Int
    public init(yes: Int = 0, maybe: Int = 0, no: Int = 0, vetoes: Int = 0) {
        self.yes = yes; self.maybe = maybe; self.no = no; self.vetoes = vetoes
    }
    public var total: Int { yes + maybe + no }
}

public struct Vote: Codable, Hashable, Sendable {
    public var verdict: Verdict
    public var veto: Bool
    public var updatedAt: Date?
    public init(verdict: Verdict, veto: Bool = false, updatedAt: Date? = nil) {
        self.verdict = verdict; self.veto = veto; self.updatedAt = updatedAt
    }
}

public struct PriceSummary: Codable, Hashable, Sendable {
    public var totalCents: Int?
    public var rangeMaxCents: Int?
    public var kind: PriceKind
    public var nights: Int?
    public var persons: Int?
    public var startDate: String?
    public var endDate: String?
    public var forThisTrip: Bool
    public var capturedAt: Date?

    public init(totalCents: Int?, rangeMaxCents: Int? = nil, kind: PriceKind = .total, nights: Int? = nil, persons: Int? = nil,
                startDate: String? = nil, endDate: String? = nil, forThisTrip: Bool = true, capturedAt: Date? = nil) {
        self.totalCents = totalCents; self.rangeMaxCents = rangeMaxCents; self.kind = kind; self.nights = nights; self.persons = persons
        self.startDate = startDate; self.endDate = endDate; self.forThisTrip = forThisTrip; self.capturedAt = capturedAt
    }
}

public struct ListingSummary: Codable, Hashable, Sendable {
    public var id: String
    public var kind: ListingKind
    public var title: String?
    public var place: String?
    public var country: String?
    public var lat: Double?
    public var lon: Double?
    public var coverImageUrl: String?
    public var fillPercent: Int
    public var maxGuests: Double?
    public var bedrooms: Double?
    public var bathrooms: Double?
    public var rating: Rating?
    public var platforms: [String]

    public init(id: String, kind: ListingKind = .vacationHome, title: String? = nil, place: String? = nil, country: String? = nil,
                lat: Double? = nil, lon: Double? = nil, coverImageUrl: String? = nil, fillPercent: Int = 0, maxGuests: Double? = nil,
                bedrooms: Double? = nil, bathrooms: Double? = nil, rating: Rating? = nil, platforms: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.place = place; self.country = country; self.lat = lat; self.lon = lon
        self.coverImageUrl = coverImageUrl; self.fillPercent = fillPercent; self.maxGuests = maxGuests; self.bedrooms = bedrooms
        self.bathrooms = bathrooms; self.rating = rating; self.platforms = platforms
    }
}

/// One row of `GET /trips/:id/candidates`.
public struct CandidateSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var status: CandidateStatus
    public var importStatus: ImportStatus
    public var importNote: String?
    public var tags: [String]
    public var addedBy: String
    public var createdAt: Date
    public var listing: ListingSummary
    public var price: PriceSummary?
    public var votes: VoteTally
    public var myVote: Vote?

    public init(id: String, status: CandidateStatus = .new, importStatus: ImportStatus = .ready, importNote: String? = nil, tags: [String] = [],
                addedBy: String, createdAt: Date = .now, listing: ListingSummary, price: PriceSummary? = nil, votes: VoteTally = .init(), myVote: Vote? = nil) {
        self.id = id; self.status = status; self.importStatus = importStatus; self.importNote = importNote; self.tags = tags
        self.addedBy = addedBy; self.createdAt = createdAt; self.listing = listing; self.price = price; self.votes = votes; self.myVote = myVote
    }
}

public struct CandidateRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var tripId: String
    public var listingId: String
    public var status: CandidateStatus
    public var importStatus: ImportStatus
    public var importNote: String?
    public var rejectionReason: String?
    public var notes: String?
    public var tags: [String]
    public var createdAt: Date

    public init(id: String, tripId: String, listingId: String, status: CandidateStatus = .new, importStatus: ImportStatus = .ready,
                importNote: String? = nil, rejectionReason: String? = nil, notes: String? = nil, tags: [String] = [], createdAt: Date = .now) {
        self.id = id; self.tripId = tripId; self.listingId = listingId; self.status = status; self.importStatus = importStatus
        self.importNote = importNote; self.rejectionReason = rejectionReason; self.notes = notes; self.tags = tags; self.createdAt = createdAt
    }
}

public struct Listing: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ListingKind
    public var title: String?
    public var place: String?
    public var country: String?
    public var lat: Double?
    public var lon: Double?
    public var coverImageUrl: String?
    public var profile: Profile
    public var fillPercent: Int

    public init(id: String, kind: ListingKind = .vacationHome, title: String? = nil, place: String? = nil, country: String? = nil,
                lat: Double? = nil, lon: Double? = nil, coverImageUrl: String? = nil, profile: Profile = .init(), fillPercent: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.place = place; self.country = country; self.lat = lat; self.lon = lon
        self.coverImageUrl = coverImageUrl; self.profile = profile; self.fillPercent = fillPercent
    }
}

public struct ListingSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var platform: String
    public var url: String
    public var canonicalUrl: String
    public var lastFetchedAt: Date?

    public init(id: String, platform: String, url: String, canonicalUrl: String, lastFetchedAt: Date? = nil) {
        self.id = id; self.platform = platform; self.url = url; self.canonicalUrl = canonicalUrl; self.lastFetchedAt = lastFetchedAt
    }
}

public struct PriceSnapshot: Codable, Identifiable, Hashable, Sendable {
    public struct Line: Codable, Hashable, Sendable {
        public var item: String
        public var amountCents: Int?
    }
    public var id: String
    public var tripId: String?
    public var startDate: String?
    public var endDate: String?
    public var nights: Int?
    public var persons: Int?
    public var totalCents: Int?
    public var rangeMaxCents: Int?
    public var kind: PriceKind
    public var breakdown: [Line]?
    public var available: Bool?
    public var capture: String
    public var capturedAt: Date

    public init(id: String, tripId: String? = nil, startDate: String? = nil, endDate: String? = nil, nights: Int? = nil, persons: Int? = nil,
                totalCents: Int?, rangeMaxCents: Int? = nil, kind: PriceKind = .total, breakdown: [Line]? = nil, available: Bool? = nil,
                capture: String = "import", capturedAt: Date = .now) {
        self.id = id; self.tripId = tripId; self.startDate = startDate; self.endDate = endDate; self.nights = nights; self.persons = persons
        self.totalCents = totalCents; self.rangeMaxCents = rangeMaxCents; self.kind = kind; self.breakdown = breakdown
        self.available = available; self.capture = capture; self.capturedAt = capturedAt
    }
}

public struct VoteEntry: Codable, Hashable, Sendable, Identifiable {
    public var userId: String
    public var name: String
    public var verdict: Verdict
    public var veto: Bool
    public var id: String { userId }
    public init(userId: String, name: String, verdict: Verdict, veto: Bool = false) {
        self.userId = userId; self.name = name; self.verdict = verdict; self.veto = veto
    }
}

public struct VoteOverview: Codable, Hashable, Sendable {
    public var yes: Int
    public var maybe: Int
    public var no: Int
    public var vetoes: Int
    public var entries: [VoteEntry]
    public init(yes: Int = 0, maybe: Int = 0, no: Int = 0, vetoes: Int = 0, entries: [VoteEntry] = []) {
        self.yes = yes; self.maybe = maybe; self.no = no; self.vetoes = vetoes; self.entries = entries
    }
}

public struct Comment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var body: String
    public var createdAt: Date
    public var userId: String
    public var name: String?
    public init(id: String, body: String, createdAt: Date = .now, userId: String, name: String? = nil) {
        self.id = id; self.body = body; self.createdAt = createdAt; self.userId = userId; self.name = name
    }
}

/// `GET /candidates/:id`.
public struct CandidateDetail: Codable, Hashable, Sendable {
    public var candidate: CandidateRecord
    public var role: MemberRole
    public var listing: Listing
    public var sources: [ListingSource]
    public var prices: [PriceSnapshot]
    public var votes: VoteOverview
    public var comments: [Comment]

    public init(candidate: CandidateRecord, role: MemberRole, listing: Listing, sources: [ListingSource] = [], prices: [PriceSnapshot] = [],
                votes: VoteOverview = .init(), comments: [Comment] = []) {
        self.candidate = candidate; self.role = role; self.listing = listing; self.sources = sources; self.prices = prices
        self.votes = votes; self.comments = comments
    }
}

public struct ImportResult: Codable, Hashable, Sendable {
    public var candidateId: String
    public var duplicate: Bool
    public var platform: String?
    public var warnings: [String]?
    public init(candidateId: String, duplicate: Bool = false, platform: String? = nil, warnings: [String]? = nil) {
        self.candidateId = candidateId; self.duplicate = duplicate; self.platform = platform; self.warnings = warnings
    }
}

public struct Invite: Codable, Hashable, Sendable, Identifiable {
    public var id: String { token }
    public var token: String
    public var url: String
    public var role: MemberRole
    public var expiresAt: Date?
    public var maxUses: Int?
}

public struct InviteInfo: Codable, Hashable, Sendable {
    public struct TripInfo: Codable, Hashable, Sendable {
        public var title: String
        public var region: String?
    }
    public var trip: TripInfo
    public var role: MemberRole
}

public struct AuthResult: Codable, Hashable, Sendable {
    /// Missing when an already signed-in user accepts an invite.
    public var token: String?
    public var user: User
    public var tripId: String?
}
