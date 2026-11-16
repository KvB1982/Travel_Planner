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
    /// "trip" or "watchlist". The watchlist is a personal place for offers that belong to no trip (yet).
    public var kind: String?
    /// Where the trip stands today, as the server sees it (it moves on by itself on arrival and departure day).
    public var currentPhase: String?
    /// The phase as stored, set by a decision or by hand.
    public var phase: String?
    public var decidedCandidateId: String?

    /// The phase to open: today's, falling back to research on servers that know no phases.
    public var activePhase: TripPhase { TripPhase(rawValue: currentPhase ?? phase ?? "") ?? .research }

    public var persons: Int { adults + children }
    public var isWatchlist: Bool { kind == "watchlist" }

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
    /// False when the platform said the offer cannot be booked for these dates. Nil when it said nothing.
    public var available: Bool?

    public init(totalCents: Int?, rangeMaxCents: Int? = nil, kind: PriceKind = .total, nights: Int? = nil, persons: Int? = nil,
                startDate: String? = nil, endDate: String? = nil, forThisTrip: Bool = true, capturedAt: Date? = nil, available: Bool? = nil) {
        self.available = available
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
    public var photoCount: Double?
    /// The position is only roughly known: derived from text, or a platform that shows the area on purpose.
    public var locationApproximate: Bool?
    /// "Toskana", "Dubrovnik-Neretva". Nil on servers that do not send it in the list.
    public var region: String?

    public init(id: String, kind: ListingKind = .vacationHome, title: String? = nil, place: String? = nil, country: String? = nil,
                lat: Double? = nil, lon: Double? = nil, coverImageUrl: String? = nil, fillPercent: Int = 0, maxGuests: Double? = nil,
                bedrooms: Double? = nil, bathrooms: Double? = nil, rating: Rating? = nil, platforms: [String] = [], photoCount: Double? = nil,
                region: String? = nil) {
        self.photoCount = photoCount
        self.region = region
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
    /// "available", "unavailable" or "unknown" for the dates and party of the trip. Nil on servers that do not check.
    public var availability: String?
    public var availabilityCheckedAt: Date?
    /// The platform turns the server away; checking needs a device.
    public var needsDevice: Bool?
    /// The advert's page for the dates and party of the trip.
    public var checkUrl: String?
    /// Chosen for the decision round of the trip.
    public var finalist: Bool?
    /// How the offer does against the trip's criteria; nil when the trip has none.
    public var criteria: CriteriaVerdict?
    /// Price and availability for each period of the trip.
    public var periods: [OfferPeriod]?

    /// The offer cannot be booked for the trip's dates, as far as the last check knows.
    public var isUnavailable: Bool {
        availability == "unavailable" || (price?.forThisTrip == true && price?.available == false)
    }

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

/// One advert of the offer on one platform. The first source is the link the offer was shared with.
public struct ListingSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var platform: String
    public var url: String
    public var canonicalUrl: String
    public var lastFetchedAt: Date?
    /// The leading source, which fills title, pictures and price of the profile. Nil on older servers.
    public var primary: Bool?
    /// Whether the page has been read at all.
    public var read: Bool?
    /// The platform turned the server away; the page has to be read on a device.
    public var needsDevice: Bool?
    public var title: String?
    public var rating: Rating?
    public var reviewCount: Double?

    public init(id: String, platform: String, url: String, canonicalUrl: String, lastFetchedAt: Date? = nil, primary: Bool? = nil,
                read: Bool? = nil, needsDevice: Bool? = nil, title: String? = nil, rating: Rating? = nil, reviewCount: Double? = nil) {
        self.id = id; self.platform = platform; self.url = url; self.canonicalUrl = canonicalUrl; self.lastFetchedAt = lastFetchedAt
        self.primary = primary; self.read = read; self.needsDevice = needsDevice; self.title = title; self.rating = rating
        self.reviewCount = reviewCount
    }
}

/// The search for the same house on other platforms, and what it found.
public struct OtherPlatforms: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case idle, running, done, failed }
    public enum Confidence: String, Codable, Sendable { case high, medium, low }
    public enum Decision: String, Codable, Sendable { case proposed, accepted, rejected }

    /// A page that may show the same house. A person decides whether it does.
    public struct Suggestion: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var url: String
        public var platform: String
        public var title: String?
        public var reason: String?
        public var confidence: Confidence?
        public var status: Decision?

        public init(id: String, url: String, platform: String, title: String? = nil, reason: String? = nil,
                    confidence: Confidence? = nil, status: Decision? = .proposed) {
            self.id = id; self.url = url; self.platform = platform; self.title = title; self.reason = reason
            self.confidence = confidence; self.status = status
        }
    }

    /// False when the server cannot search (no key for the search service).
    public var available: Bool?
    public var status: Status?
    public var searchedAt: Date?
    public var note: String?
    public var suggestions: [Suggestion]?

    public init(available: Bool? = true, status: Status? = .idle, searchedAt: Date? = nil, note: String? = nil, suggestions: [Suggestion]? = []) {
        self.available = available; self.status = status; self.searchedAt = searchedAt; self.note = note; self.suggestions = suggestions
    }

    public var isRunning: Bool { status == .running }
    /// Suggestions still waiting for a yes or no.
    public var open: [Suggestion] { (suggestions ?? []).filter { ($0.status ?? .proposed) == .proposed } }
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

/// One picture of an offer. `url` is the full-quality image, `thumbUrl` a small version for strips and lists.
/// Both may be absolute or start with "/" (then relative to the server address).
public struct Photo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var thumbUrl: String?
    public var width: Double?
    public var height: Double?
    public var caption: String?

    public init(id: String, url: String, thumbUrl: String? = nil, width: Double? = nil, height: Double? = nil, caption: String? = nil) {
        self.id = id; self.url = url; self.thumbUrl = thumbUrl; self.width = width; self.height = height; self.caption = caption
    }

    /// Width divided by height, when the server knows the size.
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }
}

/// The stages a trip goes through, each with a surface of its own.
public enum TripPhase: String, CaseIterable, Sendable, Identifiable {
    case framing, research, decision, booking, preparation, travelling, review, archived
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .framing: "Rahmen"
        case .research: "Recherche"
        case .decision: "Entscheidung"
        case .booking: "Buchung"
        case .preparation: "Vorbereitung"
        case .travelling: "Unterwegs"
        case .review: "Rückblick"
        case .archived: "Archiv"
        }
    }

    public var symbol: String {
        switch self {
        case .framing: "calendar.badge.clock"
        case .research: "magnifyingglass"
        case .decision: "trophy"
        case .booking: "checkmark.seal"
        case .preparation: "checklist"
        case .travelling: "car"
        case .review: "book.closed"
        case .archived: "archivebox"
        }
    }

    /// What the phase is for, shown where its surface is not built yet.
    public var purpose: String {
        switch self {
        case .framing: "Wer fährt wann wohin, und was darf es kosten? Mitreisende, Zeiträume, Budget und Kriterien."
        case .research: "Angebote sammeln, vergleichen und bewerten."
        case .decision: "Aus den Fundstücken werden Finalisten, und die Gruppe entscheidet sich."
        case .booking: "Buchung festhalten, Zahlungsplan, Fristen und Belege."
        case .preparation: "Anreise, Packlisten, Einkauf, Zimmerverteilung, Aktivitäten und Aufgaben."
        case .travelling: "Hausmappe, Dokumente, Kalender, gemeinsame Kasse und Fotos."
        case .review: "Abrechnung in der Gruppe, Fotobuch und Bewertung."
        case .archived: "Die abgeschlossene Reise zum Nachlesen."
        }
    }

    /// The phases shown in the bar of a trip; the archive is a state, not a place to work in.
    public static let shown: [TripPhase] = [.framing, .research, .decision, .booking, .preparation, .travelling, .review]
}

/// The state of the decision round: finalists with their points, who ranked how, and who is missing.
public struct Pitch: Decodable, Hashable, Sendable {
    public struct Finalist: Decodable, Hashable, Sendable, Identifiable {
        public var place: Int?
        public var points: Double?
        public var firstPlaces: Int?
        public var candidate: CandidateSummary
        public var summary: String?
        public var highlights: [String]?
        public var warnings: [String]?
        public var id: String { candidate.id }

        public init(place: Int? = nil, points: Double? = nil, firstPlaces: Int? = nil, candidate: CandidateSummary,
                    summary: String? = nil, highlights: [String]? = nil, warnings: [String]? = nil) {
            self.place = place; self.points = points; self.firstPlaces = firstPlaces; self.candidate = candidate
            self.summary = summary; self.highlights = highlights; self.warnings = warnings
        }
    }
    public struct Person: Decodable, Hashable, Sendable, Identifiable {
        public var userId: String
        public var name: String
        public var order: [String]?
        public var id: String { userId }
        public init(userId: String, name: String, order: [String]? = nil) { self.userId = userId; self.name = name; self.order = order }
    }

    public var phase: String?
    public var voteDeadline: Date?
    /// The winner, once the organizer has recorded the decision.
    public var decidedCandidateId: String?
    public var maxPoints: Double?
    public var finalists: [Finalist]
    public var rankings: [Person]
    public var myRanking: [String]
    public var missing: [Person]

    public init(phase: String? = nil, decidedCandidateId: String? = nil, maxPoints: Double? = nil, finalists: [Finalist] = [],
                rankings: [Person] = [], myRanking: [String] = [], missing: [Person] = []) {
        self.phase = phase; self.decidedCandidateId = decidedCandidateId; self.maxPoints = maxPoints; self.finalists = finalists
        self.rankings = rankings; self.myRanking = myRanking; self.missing = missing
    }

    private enum CodingKeys: String, CodingKey { case phase, voteDeadline, decided, maxPoints, finalists, rankings, myRanking, missing }
    private struct Decided: Decodable { var candidateId: String? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        voteDeadline = (try? container.decodeIfPresent(Date.self, forKey: .voteDeadline)) ?? nil
        // "decided" is null, an id, or an object naming the winner.
        if let id = try? container.decodeIfPresent(String.self, forKey: .decided) {
            decidedCandidateId = id
        } else {
            decidedCandidateId = ((try? container.decodeIfPresent(Decided.self, forKey: .decided)) ?? nil)?.candidateId
        }
        maxPoints = try container.decodeIfPresent(Double.self, forKey: .maxPoints)
        finalists = try container.decodeIfPresent([Finalist].self, forKey: .finalists) ?? []
        rankings = (try? container.decodeIfPresent([Person].self, forKey: .rankings)) ?? []
        myRanking = (try? container.decodeIfPresent([String].self, forKey: .myRanking)) ?? []
        missing = (try? container.decodeIfPresent([Person].self, forKey: .missing)) ?? []
    }
}

/// One requirement of the trip: a must or a wish, measured by the server or judged by people.
public struct Criterion: Codable, Identifiable, Hashable, Sendable {
    /// Empty for a criterion that has not been saved yet.
    public var id: String
    /// What is measured, such as "bedrooms" or "amenities.pool"; "custom" for one only people can judge.
    public var key: String
    public var label: String?
    /// "must" or "wish".
    public var level: String
    public var target: Double?

    public init(id: String = "", key: String, label: String? = nil, level: String = "must", target: Double? = nil) {
        self.id = id; self.key = key; self.label = label; self.level = level; self.target = target
    }

    public var isMust: Bool { level == "must" }
}

/// Something the server can measure on a profile, offered when a criterion is added.
public struct Measurable: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var group: String?
    public var format: String?
    /// "min": at least the target. "max": at most. "yes": has to be there, no target.
    public var rule: String?
    public var id: String { key }

    public init(key: String, label: String, group: String? = nil, format: String? = nil, rule: String? = nil) {
        self.key = key; self.label = label; self.group = group; self.format = format; self.rule = rule
    }
}

public struct CriteriaList: Codable, Hashable, Sendable {
    public var criteria: [Criterion]
    public var measurable: [Measurable]?
    public init(criteria: [Criterion], measurable: [Measurable]? = nil) { self.criteria = criteria; self.measurable = measurable }
}

/// How an offer does against the criteria of its trip.
public struct CriteriaVerdict: Codable, Hashable, Sendable {
    public struct Count: Codable, Hashable, Sendable {
        public var met: Int
        public var missed: Int
        public var unknown: Int
        public init(met: Int = 0, missed: Int = 0, unknown: Int = 0) { self.met = met; self.missed = missed; self.unknown = unknown }
    }
    public struct Result: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var key: String
        public var label: String?
        public var level: String
        public var rule: String?
        public var format: String?
        public var target: Double?
        /// The measured value: a number, yes or no, or text. Kept as shown text.
        public var value: ShownValue?
        /// "met", "missed" or "unknown".
        public var status: String
        public var manual: Bool?
    }
    /// "green", "yellow" or "red".
    public var light: String
    public var must: Count?
    public var wish: Count?
    public var results: [Result]?

    public init(light: String, must: Count? = nil, wish: Count? = nil, results: [Result]? = nil) {
        self.light = light; self.must = must; self.wish = wish; self.results = results
    }

    /// For sorting: green first.
    public var rank: Int { light == "green" ? 0 : light == "yellow" ? 1 : 2 }
}

/// A value of unknown type from the server, turned into text once.
public struct ShownValue: Codable, Hashable, Sendable {
    public var text: String
    public init(_ text: String) { self.text = text }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { text = flag ? "Ja" : "Nein" }
        else if let number = try? container.decode(Double.self) { text = Format.number(number) }
        else { text = (try? container.decode(String.self)) ?? "" }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Price and availability of an offer for one of the trip's possible periods.
public struct OfferPeriod: Codable, Hashable, Sendable, Identifiable {
    public var dateOptionId: String
    public var label: String?
    public var startDate: String?
    public var endDate: String?
    public var availability: String?
    public var totalCents: Int?
    public var kind: PriceKind?
    public var checkedAt: Date?
    public var checkUrl: String?
    public var id: String { dateOptionId }
}

/// A hint on an offer, such as "price is for six people". The group can hide hints it has dealt with.
public struct Hint: Codable, Hashable, Sendable, Identifiable {
    public var text: String
    public var hidden: Bool
    public var id: String { text }

    public init(text: String, hidden: Bool = false) {
        self.text = text; self.hidden = hidden
    }
}

/// What guests wrote about an offer: a summary written by the server and the individual reviews.
public struct Reviews: Codable, Hashable, Sendable {
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var author: String?
        /// Day of the review, "2026-08-14", or the page's own wording ("August 2026") where it gives no exact day.
        public var date: String?
        public var rating: Double?
        public var scale: Double?
        public var title: String?
        public var text: String
        public var language: String?
        /// German version of a review written in another language.
        public var translatedText: String?
        public var stayType: String?
        public var ownerReply: String?
        public var platform: String?

        public init(id: String, author: String? = nil, date: String? = nil, rating: Double? = nil, scale: Double? = nil, title: String? = nil,
                    text: String, language: String? = nil, translatedText: String? = nil, stayType: String? = nil, ownerReply: String? = nil,
                    platform: String? = nil) {
            self.id = id; self.author = author; self.date = date; self.rating = rating; self.scale = scale; self.title = title
            self.text = text; self.language = language; self.translatedText = translatedText; self.stayType = stayType
            self.ownerReply = ownerReply; self.platform = platform
        }
    }

    public var summary: String?
    public var positives: [String]?
    public var negatives: [String]?
    public var basedOn: Double?
    public var generatedAt: Date?
    public var items: [Item]?

    public init(summary: String? = nil, positives: [String]? = nil, negatives: [String]? = nil, basedOn: Double? = nil,
                generatedAt: Date? = nil, items: [Item]? = nil) {
        self.summary = summary; self.positives = positives; self.negatives = negatives; self.basedOn = basedOn
        self.generatedAt = generatedAt; self.items = items
    }

    /// Nothing to show: no summary, no points, no reviews.
    public var isEmpty: Bool {
        (summary ?? "").isEmpty && (positives ?? []).isEmpty && (negatives ?? []).isEmpty && (items ?? []).isEmpty
    }
}

/// `GET /candidates/:id`.
public struct CandidateDetail: Decodable, Hashable, Sendable {
    public var candidate: CandidateRecord
    public var role: MemberRole
    public var listing: Listing
    public var sources: [ListingSource]
    public var prices: [PriceSnapshot]
    public var votes: VoteOverview
    public var comments: [Comment]
    /// In the order of the advert. Missing on servers that do not import pictures yet.
    public var photos: [Photo]?
    /// Missing on servers that do not read reviews yet, or when the advert has none.
    public var reviews: Reviews?
    /// All hints with their hidden state; nil when the server only sends them inside the profile.
    public var warnings: [Hint]?
    /// Nil on servers without the search for other platforms.
    public var otherPlatforms: OtherPlatforms?
    /// The offer against the trip's criteria, with one result per criterion.
    public var criteria: CriteriaVerdict?

    /// Hints of the offer, taken from the profile when the server sent no list of its own.
    public var hints: [Hint] {
        warnings ?? (listing.profile.warnings ?? []).map { Hint(text: $0) }
    }

    public init(candidate: CandidateRecord, role: MemberRole, listing: Listing, sources: [ListingSource] = [], prices: [PriceSnapshot] = [],
                votes: VoteOverview = .init(), comments: [Comment] = [], photos: [Photo]? = nil, otherPlatforms: OtherPlatforms? = nil,
                reviews: Reviews? = nil) {
        self.candidate = candidate; self.role = role; self.listing = listing; self.sources = sources; self.prices = prices
        self.votes = votes; self.comments = comments; self.photos = photos; self.reviews = reviews
        self.otherPlatforms = otherPlatforms
    }

    private enum CodingKeys: String, CodingKey {
        case candidate, role, listing, sources, prices, votes, comments, photos, reviewSummary, reviews, warnings, otherPlatforms, criteria
    }

    /// The server sends the summary (`reviewSummary`) and the single reviews (`reviews`, a list) side by side.
    /// Pictures and reviews are extras: if their shape is ever off, the offer itself must still open.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidate = try container.decode(CandidateRecord.self, forKey: .candidate)
        role = try container.decode(MemberRole.self, forKey: .role)
        listing = try container.decode(Listing.self, forKey: .listing)
        sources = try container.decodeIfPresent([ListingSource].self, forKey: .sources) ?? []
        prices = try container.decodeIfPresent([PriceSnapshot].self, forKey: .prices) ?? []
        votes = try container.decodeIfPresent(VoteOverview.self, forKey: .votes) ?? .init()
        comments = try container.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        photos = (try? container.decodeIfPresent([Photo].self, forKey: .photos)) ?? nil
        warnings = (try? container.decodeIfPresent([Hint].self, forKey: .warnings)) ?? nil
        otherPlatforms = (try? container.decodeIfPresent(OtherPlatforms.self, forKey: .otherPlatforms)) ?? nil
        criteria = (try? container.decodeIfPresent(CriteriaVerdict.self, forKey: .criteria)) ?? nil

        var combined = ((try? container.decodeIfPresent(Reviews.self, forKey: .reviewSummary)) ?? nil) ?? Reviews()
        if let items = (try? container.decodeIfPresent([Reviews.Item].self, forKey: .reviews)) ?? nil {
            combined.items = items
        } else if let whole = (try? container.decodeIfPresent(Reviews.self, forKey: .reviews)) ?? nil {
            // Older shape: everything inside one `reviews` object.
            combined = whole
        }
        reviews = combined.isEmpty ? nil : combined
    }

    /// All pictures; falls back to the cover image alone when the server sent no list.
    public var gallery: [Photo] {
        if let photos, !photos.isEmpty { return photos }
        if let cover = listing.coverImageUrl, !cover.isEmpty { return [Photo(id: "cover", url: cover)] }
        return []
    }
}

/// Answer to "check all offers of the trip": who checks what.
public struct TripCheck: Codable, Hashable, Sendable {
    public struct Check: Codable, Hashable, Sendable, Identifiable {
        public var candidateId: String
        public var platform: String?
        /// "server": read in the background. "device": only a device can read it. "skipped": read a moment ago.
        public var mode: String
        public var needsDevice: Bool?
        public var checkUrl: String?
        public var id: String { candidateId }

        public init(candidateId: String, platform: String? = nil, mode: String, needsDevice: Bool? = nil, checkUrl: String? = nil) {
            self.candidateId = candidateId; self.platform = platform; self.mode = mode; self.needsDevice = needsDevice; self.checkUrl = checkUrl
        }

        /// Worth opening on the device: the server cannot read it, or sees too little on this platform to tell
        /// whether the dates are free.
        public var wantsDevice: Bool {
            guard let checkUrl, !checkUrl.isEmpty, mode != "skipped" else { return false }
            return mode == "device" || needsDevice == true || platform == "airbnb" || platform == "vrbo"
        }
    }
    public var checks: [Check]

    public init(checks: [Check]) { self.checks = checks }
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
