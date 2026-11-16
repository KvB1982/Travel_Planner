import Foundation

// MARK: Lists

public struct ChecklistItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var list: String
    public var title: String
    public var quantity: String?
    public var assignedTo: String?
    public var assignedParty: String?
    public var dueOn: String?
    public var done: Bool
    /// Only its author sees it.
    public var isPrivate: Bool
    public var position: Int?

    enum CodingKeys: String, CodingKey { case id, list, title, quantity, assignedTo, assignedParty, dueOn, done, isPrivate = "private", position }

    public init(id: String, list: String, title: String, quantity: String? = nil, assignedTo: String? = nil, assignedParty: String? = nil,
                dueOn: String? = nil, done: Bool = false, isPrivate: Bool = false, position: Int? = nil) {
        self.id = id; self.list = list; self.title = title; self.quantity = quantity; self.assignedTo = assignedTo
        self.assignedParty = assignedParty; self.dueOn = dueOn; self.done = done; self.isPrivate = isPrivate; self.position = position
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        list = try c.decodeIfPresent(String.self, forKey: .list) ?? "packing"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        quantity = try? c.decodeIfPresent(String.self, forKey: .quantity)
        assignedTo = try? c.decodeIfPresent(String.self, forKey: .assignedTo)
        assignedParty = try? c.decodeIfPresent(String.self, forKey: .assignedParty)
        dueOn = try? c.decodeIfPresent(String.self, forKey: .dueOn)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        isPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false
        position = try? c.decodeIfPresent(Int.self, forKey: .position)
    }
}

public struct Checklists: Decodable, Hashable, Sendable {
    public struct List: Decodable, Identifiable, Hashable, Sendable {
        public var list: String
        public var items: [ChecklistItem]
        public var id: String { list }
        public var done: Int { items.filter(\.done).count }

        public init(list: String, items: [ChecklistItem]) { self.list = list; self.items = items }

        /// "packing", "shopping" and "todo" always exist; any other name is a list of the group's own.
        public var label: String {
            switch list {
            case "packing": "Packen"
            case "shopping": "Einkauf"
            case "todo": "Aufgaben"
            default: list
            }
        }
        public var symbol: String {
            switch list {
            case "packing": "suitcase"
            case "shopping": "cart"
            case "todo": "checklist"
            default: "list.bullet"
            }
        }
    }
    public struct Template: Decodable, Identifiable, Hashable, Sendable {
        public var key: String
        public var label: String
        public var list: String
        public var count: Int?
        public var id: String { key }
        public init(key: String, label: String, list: String, count: Int? = nil) { self.key = key; self.label = label; self.list = list; self.count = count }
    }
    public var lists: [List]
    public var templates: [Template]

    public init(lists: [List], templates: [Template] = []) { self.lists = lists; self.templates = templates }

    enum CodingKeys: String, CodingKey { case lists, templates }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lists = try c.decodeIfPresent([List].self, forKey: .lists) ?? []
        templates = (try? c.decodeIfPresent([Template].self, forKey: .templates)) ?? []
    }
}

/// A change to one line of a list. Only what is set is sent.
public struct ChecklistChange: Encodable, Hashable, Sendable {
    public var title: String?
    public var quantity: String?
    public var done: Bool?
    public init(title: String? = nil, quantity: String? = nil, done: Bool? = nil) { self.title = title; self.quantity = quantity; self.done = done }
}

// MARK: Bookings

public enum BookingKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case accommodation, flight, car, ferry, train, insurance, activity, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .accommodation: "Unterkunft"
        case .flight: "Flug"
        case .car: "Mietwagen"
        case .ferry: "Fähre"
        case .train: "Bahn"
        case .insurance: "Versicherung"
        case .activity: "Aktivität"
        case .other: "Sonstiges"
        }
    }
    public var symbol: String {
        switch self {
        case .accommodation: "house"
        case .flight: "airplane"
        case .car: "car"
        case .ferry: "ferry"
        case .train: "tram"
        case .insurance: "shield"
        case .activity: "figure.hiking"
        case .other: "ticket"
        }
    }
}

public struct BookingPayment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var amountCents: Int
    public var dueOn: String?
    public var paidOn: String?
    public var paidByParty: String?
    /// A deposit that comes back: it does not count as cost.
    public var refundable: Bool?
    public var isPaid: Bool { paidOn != nil }

    public init(id: String, label: String, amountCents: Int, dueOn: String? = nil, paidOn: String? = nil, paidByParty: String? = nil, refundable: Bool? = false) {
        self.id = id; self.label = label; self.amountCents = amountCents; self.dueOn = dueOn; self.paidOn = paidOn
        self.paidByParty = paidByParty; self.refundable = refundable
    }
}

public struct TripDocument: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String?
    public var contentType: String?
    public var sizeBytes: Int?
    public init(id: String, title: String, kind: String? = nil, contentType: String? = nil, sizeBytes: Int? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.contentType = contentType; self.sizeBytes = sizeBytes
    }

    /// The ending a file of this type carries, so the preview knows what it is.
    public var fileExtension: String {
        switch contentType {
        case "application/pdf": "pdf"
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/heic", "image/heif": "heic"
        case "image/webp": "webp"
        default: "txt"
        }
    }

    /// The types the server takes, by file ending.
    public static func contentType(forExtension ending: String) -> String? {
        switch ending.lowercased() {
        case "pdf": "application/pdf"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "webp": "image/webp"
        case "txt": "text/plain"
        default: nil
        }
    }
}

public struct Booking: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: BookingKind
    public var title: String
    public var provider: String?
    public var reference: String?
    public var candidateId: String?
    /// "planned", "booked" or "cancelled".
    public var status: String
    public var startsAt: String?
    public var endsAt: String?
    public var place: String?
    public var totalCents: Int?
    public var depositCents: Int?
    public var freeCancellationUntil: String?
    public var notes: String?
    public var payments: [BookingPayment]
    public var documents: [TripDocument]

    public init(id: String, kind: BookingKind = .accommodation, title: String, provider: String? = nil, reference: String? = nil, candidateId: String? = nil,
                status: String = "planned", startsAt: String? = nil, endsAt: String? = nil, place: String? = nil, totalCents: Int? = nil,
                depositCents: Int? = nil, freeCancellationUntil: String? = nil, notes: String? = nil, payments: [BookingPayment] = [], documents: [TripDocument] = []) {
        self.id = id; self.kind = kind; self.title = title; self.provider = provider; self.reference = reference; self.candidateId = candidateId
        self.status = status; self.startsAt = startsAt; self.endsAt = endsAt; self.place = place; self.totalCents = totalCents
        self.depositCents = depositCents; self.freeCancellationUntil = freeCancellationUntil; self.notes = notes
        self.payments = payments; self.documents = documents
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, provider, reference, candidateId, status, startsAt, endsAt, place, totalCents, depositCents, freeCancellationUntil, notes, payments, documents
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(BookingKind.self, forKey: .kind)) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Buchung"
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        reference = try? c.decodeIfPresent(String.self, forKey: .reference)
        candidateId = try? c.decodeIfPresent(String.self, forKey: .candidateId)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "planned"
        startsAt = try? c.decodeIfPresent(String.self, forKey: .startsAt)
        endsAt = try? c.decodeIfPresent(String.self, forKey: .endsAt)
        place = try? c.decodeIfPresent(String.self, forKey: .place)
        totalCents = try? c.decodeIfPresent(Int.self, forKey: .totalCents)
        depositCents = try? c.decodeIfPresent(Int.self, forKey: .depositCents)
        freeCancellationUntil = try? c.decodeIfPresent(String.self, forKey: .freeCancellationUntil)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        payments = (try? c.decodeIfPresent([BookingPayment].self, forKey: .payments)) ?? []
        documents = (try? c.decodeIfPresent([TripDocument].self, forKey: .documents)) ?? []
    }

    public var statusLabel: String {
        switch status {
        case "booked": "gebucht"
        case "cancelled": "storniert"
        default: "geplant"
        }
    }
}

public struct BookingOverview: Decodable, Hashable, Sendable {
    public struct Deadline: Decodable, Identifiable, Hashable, Sendable {
        /// "payment", "cancellation" or "start".
        public var type: String
        public var on: String
        public var bookingId: String?
        public var paymentId: String?
        public var label: String
        public var amountCents: Int?
        public var overdue: Bool?
        public var id: String { "\(type)|\(on)|\(bookingId ?? "")|\(paymentId ?? "")" }
        public init(type: String, on: String, bookingId: String? = nil, paymentId: String? = nil, label: String, amountCents: Int? = nil, overdue: Bool? = false) {
            self.type = type; self.on = on; self.bookingId = bookingId; self.paymentId = paymentId; self.label = label; self.amountCents = amountCents; self.overdue = overdue
        }
    }
    public struct Totals: Decodable, Hashable, Sendable {
        public var bookedCents: Int?
        public var plannedCents: Int?
        public var paidCents: Int?
        public var openCents: Int?
        public var depositsOutCents: Int?
        public init(bookedCents: Int? = nil, plannedCents: Int? = nil, paidCents: Int? = nil, openCents: Int? = nil, depositsOutCents: Int? = nil) {
            self.bookedCents = bookedCents; self.plannedCents = plannedCents; self.paidCents = paidCents; self.openCents = openCents; self.depositsOutCents = depositsOutCents
        }
    }
    public var bookings: [Booking]
    public var documents: [TripDocument]
    public var deadlines: [Deadline]
    public var totals: Totals

    public init(bookings: [Booking], documents: [TripDocument] = [], deadlines: [Deadline] = [], totals: Totals = Totals()) {
        self.bookings = bookings; self.documents = documents; self.deadlines = deadlines; self.totals = totals
    }

    enum CodingKeys: String, CodingKey { case bookings, documents, deadlines, totals }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookings = try c.decodeIfPresent([Booking].self, forKey: .bookings) ?? []
        documents = (try? c.decodeIfPresent([TripDocument].self, forKey: .documents)) ?? []
        deadlines = (try? c.decodeIfPresent([Deadline].self, forKey: .deadlines)) ?? []
        totals = (try? c.decodeIfPresent(Totals.self, forKey: .totals)) ?? Totals()
    }
}

/// What the app sends for a booking. Everything that can be cleared is sent, so an emptied field arrives as null.
public struct BookingDraft: Encodable, Hashable, Sendable {
    public var kind: BookingKind
    public var title: String?
    public var provider: String?
    public var reference: String?
    /// Only when creating: the server takes title and place from the offer.
    public var candidateId: String?
    public var status: String
    public var startsAt: String?
    public var endsAt: String?
    public var place: String?
    public var totalCents: Int?
    public var depositCents: Int?
    public var freeCancellationUntil: String?
    public var notes: String?

    public init(kind: BookingKind = .accommodation, title: String? = nil, provider: String? = nil, reference: String? = nil, candidateId: String? = nil,
                status: String = "planned", startsAt: String? = nil, endsAt: String? = nil, place: String? = nil, totalCents: Int? = nil,
                depositCents: Int? = nil, freeCancellationUntil: String? = nil, notes: String? = nil) {
        self.kind = kind; self.title = title; self.provider = provider; self.reference = reference; self.candidateId = candidateId
        self.status = status; self.startsAt = startsAt; self.endsAt = endsAt; self.place = place; self.totalCents = totalCents
        self.depositCents = depositCents; self.freeCancellationUntil = freeCancellationUntil; self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case kind, title, provider, reference, candidateId, status, startsAt, endsAt, place, totalCents, depositCents, freeCancellationUntil, notes }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(status, forKey: .status)
        // Title and place may come from the offer, so they are only sent when given.
        try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(candidateId, forKey: .candidateId)
        if candidateId == nil || place != nil { try c.encode(place, forKey: .place) }
        try c.encode(provider, forKey: .provider); try c.encode(reference, forKey: .reference)
        try c.encode(startsAt, forKey: .startsAt); try c.encode(endsAt, forKey: .endsAt)
        try c.encode(totalCents, forKey: .totalCents); try c.encode(depositCents, forKey: .depositCents)
        try c.encode(freeCancellationUntil, forKey: .freeCancellationUntil); try c.encode(notes, forKey: .notes)
    }
}

/// The sums and deadlines behind the sample data, the way the server reckons them.
public enum BookingMath {
    public static func overview(bookings: [Booking], documents: [TripDocument], today: String) -> BookingOverview {
        let live = bookings.filter { $0.status != "cancelled" }
        var deadlines: [BookingOverview.Deadline] = []
        for booking in live {
            for payment in booking.payments where !payment.isPaid {
                if let due = payment.dueOn {
                    deadlines.append(.init(type: "payment", on: due, bookingId: booking.id, paymentId: payment.id, label: "\(payment.label): \(booking.title)",
                                           amountCents: payment.amountCents, overdue: due < today))
                }
            }
            if let until = booking.freeCancellationUntil, until >= today {
                deadlines.append(.init(type: "cancellation", on: until, bookingId: booking.id, label: "Kostenlos stornierbar bis: \(booking.title)"))
            }
            if let start = booking.startsAt.map({ String($0.prefix(10)) }), start >= today {
                deadlines.append(.init(type: "start", on: start, bookingId: booking.id, label: "Beginn: \(booking.title)"))
            }
        }
        let costs = live.flatMap(\.payments).filter { $0.refundable != true }
        let planned = live.reduce(0) { $0 + ($1.totalCents ?? 0) }
        let paid = costs.filter(\.isPaid).reduce(0) { $0 + $1.amountCents }
        let totals = BookingOverview.Totals(bookedCents: live.filter { $0.status == "booked" }.reduce(0) { $0 + ($1.totalCents ?? 0) }, plannedCents: planned,
                                            paidCents: paid, openCents: max(0, planned - paid),
                                            depositsOutCents: live.flatMap(\.payments).filter { $0.refundable == true && $0.isPaid }.reduce(0) { $0 + $1.amountCents })
        return BookingOverview(bookings: bookings, documents: documents, deadlines: deadlines.sorted { $0.on < $1.on }, totals: totals)
    }
}
