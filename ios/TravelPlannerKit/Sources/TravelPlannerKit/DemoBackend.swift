import Foundation

/// Sample data that behaves like the server, for trying the app before the backend is reachable.
/// Nothing leaves the device and nothing is kept after the app closes.
public actor DemoBackend: TravelBackend {
    private let user = User(id: "u-1", name: "Du")
    private var trips: [Trip]
    private var details: [String: CandidateDetail]
    private var order: [String]
    private var counter = 100

    public init() {
        let trip1 = Trip(id: "t-1", title: "Pfingstferien 2027", region: "Toskana", adults: 4, children: 4, pets: 0, budgetTotalCents: 600_000, role: .organizer)
        let trip2 = Trip(id: "t-2", title: "Sommerurlaub 2027", region: "Dänemark, Nordsee", adults: 6, children: 5, pets: 1, role: .member)
        var watchlist = Trip(id: "t-w", title: "Merkliste", adults: 2, role: .organizer)
        watchlist.kind = "watchlist"
        trips = [trip1, trip2, watchlist]
        let samples = DemoBackend.samples()
        details = Dictionary(uniqueKeysWithValues: samples.map { ($0.candidate.id, $0) })
        order = samples.map(\.candidate.id)
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func detail(_ id: String) throws -> CandidateDetail {
        guard let detail = details[id] else { throw APIError(status: 404, code: "not_found", message: "Dieses Angebot gibt es nicht mehr.") }
        return detail
    }

    public func me() async throws -> User { user }

    /// Sample pictures are drawn by the app itself (`demo://photo/<n>`), so the demo needs no network.
    public nonisolated func imageRequest(for address: String) -> URLRequest? {
        URL(string: address).map { URLRequest(url: $0) }
    }

    public func logout() async throws {}

    public func trips() async throws -> [Trip] {
        trips.map { trip in
            var trip = trip
            let own = details.values.filter { $0.candidate.tripId == trip.id }
            trip.candidateCount = own.count
            trip.favoriteCount = own.filter { $0.candidate.status == .favorite }.count
            return trip
        }
    }

    public func trip(_ id: String) async throws -> TripDetail {
        guard let trip = trips.first(where: { $0.id == id }) else { throw APIError(status: 404, code: "not_found", message: "Diese Reise gibt es nicht.") }
        let options = periods[id] ?? []
        let members = [Member(id: "u-1", name: "Du", role: trip.role ?? .member), Member(id: "u-2", name: "Anna", role: .member), Member(id: "u-3", name: "Jonas", role: .guest)]
        return TripDetail(trip: trip, role: trip.role ?? .member, members: members, dateOptions: options)
    }

    public func createTrip(_ new: NewTrip) async throws -> Trip {
        let trip = Trip(id: nextID("t"), title: new.title, region: new.region, adults: new.adults, children: new.children, pets: new.pets,
                        budgetTotalCents: new.budgetTotalCents, role: .organizer)
        trips.insert(trip, at: 0)
        return trip
    }

    public func createInvite(tripId: String, role: MemberRole) async throws -> Invite {
        Invite(token: "demo", url: "https://reisen.example/einladung/demo", role: role, expiresAt: nil, maxUses: 1)
    }

    public func candidates(tripId: String, dateOptionId: String?) async throws -> [CandidateSummary] {
        order.compactMap { details[$0] }.filter { $0.candidate.tripId == tripId }.map { detail in
            var summary = summarize(detail, tripId: tripId)
            summary.criteria = verdict(for: detail, results: false)
            summary.finalist = finalists[tripId]?.contains(detail.candidate.id) ?? false
            return summary
        }
    }

    private func summarize(_ detail: CandidateDetail, tripId: String) -> CandidateSummary {
        [detail].map { detail in
            let profile = detail.listing.profile
            let price = detail.prices.first
            return CandidateSummary(
                id: detail.candidate.id, status: detail.candidate.status, importStatus: detail.candidate.importStatus,
                importNote: detail.candidate.importNote, tags: detail.candidate.tags, addedBy: "Anna", createdAt: detail.candidate.createdAt,
                listing: ListingSummary(id: detail.listing.id, kind: detail.listing.kind, title: detail.listing.title, place: detail.listing.place,
                                        country: detail.listing.country, lat: detail.listing.lat, lon: detail.listing.lon,
                                        coverImageUrl: detail.listing.coverImageUrl, fillPercent: detail.listing.fillPercent,
                                        maxGuests: profile.maxGuests, bedrooms: profile.bedrooms, bathrooms: profile.bathrooms,
                                        rating: profile.rating, platforms: detail.sources.map(\.platform),
                                        photoCount: detail.photos.map { Double($0.count) },
                                        region: profile.region),
                price: price.map { PriceSummary(totalCents: $0.totalCents, rangeMaxCents: $0.rangeMaxCents, kind: $0.kind, nights: $0.nights,
                                                persons: $0.persons, startDate: $0.startDate, endDate: $0.endDate,
                                                forThisTrip: $0.tripId == tripId, capturedAt: $0.capturedAt, available: $0.available) },
                votes: VoteTally(yes: detail.votes.yes, maybe: detail.votes.maybe, no: detail.votes.no, vetoes: detail.votes.vetoes),
                myVote: detail.votes.entries.first { $0.userId == user.id }.map { Vote(verdict: $0.verdict, veto: $0.veto) })
        }[0]
    }

    public func correctProfile(candidateId: String, changes: [String: PatchValue]) async throws {
        var detail = try detail(candidateId)
        for (key, value) in changes {
            var number: Double?, text: String?
            switch value {
            case .number(let n): number = n
            case .text(let t): text = t
            case .null: break
            }
            switch key {
            case "title": detail.listing.profile.title = text; detail.listing.title = text
            case "place": detail.listing.profile.place = text; detail.listing.place = text
            case "region": detail.listing.profile.region = text
            case "country": detail.listing.profile.country = text; detail.listing.country = text
            case "maxGuests": detail.listing.profile.maxGuests = number
            case "bedrooms": detail.listing.profile.bedrooms = number
            case "beds": detail.listing.profile.beds = number
            case "bathrooms": detail.listing.profile.bathrooms = number
            case "livingAreaSqm": detail.listing.profile.livingAreaSqm = number
            case "plotSqm": detail.listing.profile.plotSqm = number
            default: throw APIError(status: 400, code: "invalid_request", message: "\(key): unbekannt")
            }
            detail.listing.profile.uncertain?.removeAll { $0 == key }
        }
        details[candidateId] = detail
    }

    public func addPrice(candidateId: String, price: ManualPrice) async throws {
        var detail = try detail(candidateId)
        let nights = price.startDate.flatMap(Format.day).flatMap { start in
            price.endDate.flatMap(Format.day).flatMap { Calendar.current.dateComponents([.day], from: start, to: $0).day }
        }
        detail.prices.insert(PriceSnapshot(id: nextID("pr"), tripId: detail.candidate.tripId, startDate: price.startDate, endDate: price.endDate,
                                           nights: nights, persons: price.persons, totalCents: price.totalCents, available: price.available,
                                           capture: "manual"), at: 0)
        details[candidateId] = detail
    }

    // MARK: Lists and bookings

    private var listItems: [String: [ChecklistItem]] = ["t-1": [
        ChecklistItem(id: "i-1", list: "packing", title: "Badesachen", done: true),
        ChecklistItem(id: "i-2", list: "packing", title: "Reiseapotheke"),
        ChecklistItem(id: "i-3", list: "packing", title: "Ladegeräte und Kabel"),
        ChecklistItem(id: "i-4", list: "shopping", title: "Frühstück für den ersten Tag", quantity: "für 8"),
        ChecklistItem(id: "i-5", list: "todo", title: "Zeitung abbestellen", dueOn: "2027-05-10")]]
    private let listTemplates: [String: (String, String, [String])] = [
        "basics": ("Grundausstattung", "packing", ["Ausweise und Reisepässe", "Krankenversicherungskarten", "Ladegeräte und Kabel", "Reiseapotheke", "Sonnencreme"]),
        "beach": ("Strand und Pool", "packing", ["Badesachen", "Strandtücher", "Sonnenhüte", "Badeschuhe", "Kühltasche"]),
        "firstDay": ("Einkauf für den ersten Tag", "shopping", ["Brot", "Butter", "Kaffee", "Milch", "Nudeln"])]

    private func sheets(_ tripId: String) throws -> Checklists {
        _ = try tripIndex(tripId)
        let items = listItems[tripId] ?? []
        let names = ["packing", "shopping", "todo"] + Array(Set(items.map(\.list)).subtracting(["packing", "shopping", "todo"])).sorted()
        return Checklists(lists: names.map { name in Checklists.List(list: name, items: items.filter { $0.list == name }) },
                          templates: listTemplates.sorted { $0.key < $1.key }.map { Checklists.Template(key: $0.key, label: $0.value.0, list: $0.value.1, count: $0.value.2.count) })
    }

    public func checklists(tripId: String) async throws -> Checklists { try sheets(tripId) }

    public func addChecklistItem(tripId: String, list: String, title: String, quantity: String?, isPrivate: Bool) async throws -> Checklists {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError(status: 400, code: "invalid_request", message: "Der Eintrag braucht einen Namen.") }
        listItems[tripId, default: []].append(ChecklistItem(id: nextID("i"), list: list, title: title, quantity: quantity, isPrivate: isPrivate))
        return try sheets(tripId)
    }

    private func tripOfItem(_ id: String) throws -> String {
        guard let key = listItems.first(where: { $0.value.contains { $0.id == id } })?.key else { throw APIError(status: 404, code: "not_found", message: "Eintrag nicht gefunden.") }
        return key
    }

    public func updateChecklistItem(itemId: String, change: ChecklistChange) async throws -> Checklists {
        let key = try tripOfItem(itemId)
        if let index = listItems[key]?.firstIndex(where: { $0.id == itemId }) {
            if let title = change.title { listItems[key]?[index].title = title }
            if let quantity = change.quantity { listItems[key]?[index].quantity = quantity }
            if let done = change.done { listItems[key]?[index].done = done }
        }
        return try sheets(key)
    }

    public func deleteChecklistItem(itemId: String) async throws -> Checklists {
        let key = try tripOfItem(itemId)
        listItems[key]?.removeAll { $0.id == itemId }
        return try sheets(key)
    }

    public func applyChecklistTemplate(tripId: String, template: String) async throws -> Checklists {
        guard let entry = listTemplates[template] else { throw APIError(status: 400, code: "invalid_request", message: "Diese Vorlage gibt es nicht.") }
        let there = Set((listItems[tripId] ?? []).filter { $0.list == entry.1 }.map { $0.title.lowercased() })
        for title in entry.2 where !there.contains(title.lowercased()) {
            listItems[tripId, default: []].append(ChecklistItem(id: nextID("i"), list: entry.1, title: title))
        }
        return try sheets(tripId)
    }

    private var booked: [String: [Booking]] = ["t-1": [
        Booking(id: "b-1", kind: .accommodation, title: "Casa Olivia mit Pool", provider: "Airbnb", reference: "HM4X9K2", candidateId: "c-1", status: "planned",
                startsAt: "2027-05-15T16:00", endsAt: "2027-05-29T10:00", place: "Castellina in Chianti, Italien", totalCents: 486_000, depositCents: 50_000,
                freeCancellationUntil: "2027-03-01",
                payments: [BookingPayment(id: "bp-1", label: "Anzahlung", amountCents: 145_800, dueOn: "2027-01-12", paidOn: "2027-01-12", paidByParty: "p-1"),
                           BookingPayment(id: "bp-2", label: "Restzahlung", amountCents: 340_200, dueOn: "2027-04-15"),
                           BookingPayment(id: "bp-3", label: "Kaution", amountCents: 50_000, dueOn: "2027-05-15", refundable: true)],
                documents: [TripDocument(id: "doc-1", title: "Buchungsbestätigung", contentType: "text/plain", sizeBytes: 64)])]]
    private var papers: [String: [TripDocument]] = [:]
    private var files: [String: Data] = ["doc-1": Data("Beispiel: Buchungsbestätigung für Casa Olivia mit Pool.".utf8)]

    private func plan(_ tripId: String) throws -> BookingOverview {
        _ = try tripIndex(tripId)
        return BookingMath.overview(bookings: booked[tripId] ?? [], documents: papers[tripId] ?? [], today: Format.isoDay(.now))
    }

    private func place(ofBooking id: String) throws -> (String, Int) {
        for (key, list) in booked { if let index = list.firstIndex(where: { $0.id == id }) { return (key, index) } }
        throw APIError(status: 404, code: "not_found", message: "Buchung nicht gefunden.")
    }

    private func place(ofPayment id: String) throws -> (String, Int, Int) {
        for (key, list) in booked {
            for (index, booking) in list.enumerated() { if let p = booking.payments.firstIndex(where: { $0.id == id }) { return (key, index, p) } }
        }
        throw APIError(status: 404, code: "not_found", message: "Zahlung nicht gefunden.")
    }

    private func apply(_ draft: BookingDraft, to booking: inout Booking) {
        booking.kind = draft.kind; booking.provider = draft.provider; booking.reference = draft.reference; booking.status = draft.status
        booking.startsAt = draft.startsAt; booking.endsAt = draft.endsAt; booking.totalCents = draft.totalCents; booking.depositCents = draft.depositCents
        booking.freeCancellationUntil = draft.freeCancellationUntil; booking.notes = draft.notes
        if let title = draft.title { booking.title = title }
        if draft.candidateId == nil || draft.place != nil { booking.place = draft.place }
    }

    public func bookings(tripId: String) async throws -> BookingOverview { try plan(tripId) }

    public func addBooking(tripId: String, booking draft: BookingDraft) async throws -> BookingOverview {
        var booking = Booking(id: nextID("b"), title: draft.title ?? "")
        if let candidate = draft.candidateId {
            let listing = try detail(candidate).listing
            booking.candidateId = candidate
            booking.title = listing.title ?? ""
            booking.place = [listing.place, listing.country].compactMap { $0 }.joined(separator: ", ")
        }
        apply(draft, to: &booking)
        guard !booking.title.isEmpty else { throw APIError(status: 400, code: "invalid_request", message: "Die Buchung braucht eine Bezeichnung.") }
        booked[tripId, default: []].append(booking)
        if booking.kind == .accommodation, booking.status == "booked" { try await setPhase(tripId: tripId, phase: .preparation) }
        return try plan(tripId)
    }

    public func updateBooking(bookingId: String, booking draft: BookingDraft) async throws -> BookingOverview {
        let (key, index) = try place(ofBooking: bookingId)
        if var booking = booked[key]?[index] {
            apply(draft, to: &booking)
            booked[key]?[index] = booking
            if booking.kind == .accommodation, booking.status == "booked" { try await setPhase(tripId: key, phase: .preparation) }
        }
        return try plan(key)
    }

    public func deleteBooking(bookingId: String) async throws -> BookingOverview {
        let (key, index) = try place(ofBooking: bookingId)
        booked[key]?.remove(at: index)
        return try plan(key)
    }

    public func addBookingPayment(bookingId: String, label: String, amountCents: Int, dueOn: String?, refundable: Bool) async throws -> BookingOverview {
        let (key, index) = try place(ofBooking: bookingId)
        booked[key]?[index].payments.append(BookingPayment(id: nextID("bp"), label: label, amountCents: amountCents, dueOn: dueOn, refundable: refundable))
        return try plan(key)
    }

    public func setBookingPaymentPaid(paymentId: String, paidOn: String?, paidByParty: String?) async throws -> BookingOverview {
        let (key, index, payment) = try place(ofPayment: paymentId)
        booked[key]?[index].payments[payment].paidOn = paidOn
        booked[key]?[index].payments[payment].paidByParty = paidByParty
        return try plan(key)
    }

    public func deleteBookingPayment(paymentId: String) async throws -> BookingOverview {
        let (key, index, payment) = try place(ofPayment: paymentId)
        booked[key]?[index].payments.remove(at: payment)
        return try plan(key)
    }

    public func uploadDocument(tripId: String, title: String, bookingId: String?, contentType: String, data: Data) async throws {
        let document = TripDocument(id: nextID("doc"), title: title, contentType: contentType, sizeBytes: data.count)
        files[document.id] = data
        if let bookingId {
            let (key, index) = try place(ofBooking: bookingId)
            booked[key]?[index].documents.append(document)
        } else {
            _ = try tripIndex(tripId)
            papers[tripId, default: []].append(document)
        }
    }

    public func documentFile(documentId: String) async throws -> Data {
        guard let data = files[documentId] else { throw APIError(status: 404, code: "not_found", message: "Dokument nicht gefunden.") }
        return data
    }

    public func deleteDocument(documentId: String) async throws {
        files[documentId] = nil
        for key in papers.keys { papers[key]?.removeAll { $0.id == documentId } }
        for key in booked.keys { for index in (booked[key] ?? []).indices { booked[key]?[index].documents.removeAll { $0.id == documentId } } }
    }

    // MARK: Preparation

    private var plans: [String: TripPlan] = ["t-1": TripPlan(
        legs: [TravelLeg(id: "l-1", partyId: "p-1", direction: "outbound", mode: "car", fromPlace: "München", toPlace: "Castellina in Chianti",
                         departAt: "2027-05-15T06:00", stops: [TravelLeg.Stop(place: "Gardasee", note: "Mittagspause")]),
               TravelLeg(id: "l-2", partyId: "p-3", direction: "outbound", mode: "flight", fromPlace: "Hamburg", toPlace: "Florenz",
                         departAt: "2027-05-15T09:40", arriveAt: "2027-05-15T11:35")],
        rooms: [Room(id: "r-1", name: "Schlafzimmer 1", beds: "1 Doppelbett", partyId: "p-1", occupants: ["Du", "Lena"]),
                Room(id: "r-2", name: "Schlafzimmer 2", beds: "2 Einzelbetten", occupants: [])],
        activities: [Activity(id: "x-1", title: "Weinprobe in Radda", place: "Radda in Chianti", status: "planned", startsAt: "2027-05-18T16:00",
                              costCents: 2_500, costNote: "pro Person"),
                     Activity(id: "x-2", title: "Tagesausflug nach Siena", status: "idea")])]
    private var answers: [String: [String: String]] = ["x-1": ["u-2": "yes", "u-3": "maybe"]]

    private func preparation(_ tripId: String) throws -> TripPlan {
        _ = try tripIndex(tripId)
        var plan = plans[tripId] ?? TripPlan()
        let names = ["u-1": "Du", "u-2": "Anna", "u-3": "Jonas"]
        plan.activities = plan.activities.map { activity in
            var activity = activity
            let given = answers[activity.id] ?? [:]
            activity.responses = given.sorted { $0.key < $1.key }.map { Activity.Response(userId: $0.key, name: names[$0.key], answer: $0.value) }
            activity.tally = Activity.Tally(yes: given.values.filter { $0 == "yes" }.count, maybe: given.values.filter { $0 == "maybe" }.count,
                                            no: given.values.filter { $0 == "no" }.count)
            activity.myAnswer = given[user.id]
            return activity
        }
        // With a date they stand in the order of the calendar, ideas without one after them.
        plan.activities.sort { ($0.startsAt ?? "9999") < ($1.startsAt ?? "9999") }
        return plan
    }

    private func tripOfPlan(_ has: (TripPlan) -> Bool, _ what: String) throws -> String {
        guard let key = plans.first(where: { has($0.value) })?.key else { throw APIError(status: 404, code: "not_found", message: "\(what) nicht gefunden.") }
        return key
    }

    public func plan(tripId: String) async throws -> TripPlan { try preparation(tripId) }

    public func saveLeg(tripId: String, legId: String?, leg draft: LegDraft) async throws -> TripPlan {
        let key = try legId.map { id in try tripOfPlan({ $0.legs.contains { $0.id == id } }, "Strecke") } ?? tripId
        let leg = TravelLeg(id: legId ?? nextID("l"), partyId: draft.partyId, direction: draft.direction, mode: draft.mode, fromPlace: draft.fromPlace,
                            toPlace: draft.toPlace, departAt: draft.departAt, arriveAt: draft.arriveAt, stops: draft.stops, notes: draft.notes)
        if let index = plans[key]?.legs.firstIndex(where: { $0.id == leg.id }) { plans[key]?.legs[index] = leg } else { plans[key, default: TripPlan()].legs.append(leg) }
        return try preparation(key)
    }

    public func deleteLeg(legId: String) async throws -> TripPlan {
        let key = try tripOfPlan({ $0.legs.contains { $0.id == legId } }, "Strecke")
        plans[key]?.legs.removeAll { $0.id == legId }
        return try preparation(key)
    }

    public func saveRoom(tripId: String, roomId: String?, room draft: RoomDraft) async throws -> TripPlan {
        let key = try roomId.map { id in try tripOfPlan({ $0.rooms.contains { $0.id == id } }, "Zimmer") } ?? tripId
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError(status: 400, code: "invalid_request", message: "Das Zimmer braucht einen Namen.") }
        let room = Room(id: roomId ?? nextID("r"), name: draft.name, beds: draft.beds, partyId: draft.partyId, occupants: draft.occupants, notes: draft.notes)
        if let index = plans[key]?.rooms.firstIndex(where: { $0.id == room.id }) { plans[key]?.rooms[index] = room } else { plans[key, default: TripPlan()].rooms.append(room) }
        return try preparation(key)
    }

    public func deleteRoom(roomId: String) async throws -> TripPlan {
        let key = try tripOfPlan({ $0.rooms.contains { $0.id == roomId } }, "Zimmer")
        plans[key]?.rooms.removeAll { $0.id == roomId }
        return try preparation(key)
    }

    public func suggestRooms(tripId: String) async throws -> TripPlan {
        guard (plans[tripId]?.rooms ?? []).isEmpty else { throw APIError(status: 409, code: "already_set_up", message: "Es gibt schon Zimmer.") }
        guard let chosen = decided[tripId] else { throw APIError(status: 409, code: "no_decision", message: "Die Reise hat noch kein entschiedenes Angebot.") }
        let profile = try detail(chosen).listing.profile
        let count = Int(profile.bedrooms ?? 0)
        guard count > 0 else { throw APIError(status: 409, code: "nothing_known", message: "Der Steckbrief nennt keine Zimmer.") }
        plans[tripId, default: TripPlan()].rooms = (1...count).map { Room(id: nextID("r"), name: "Schlafzimmer \($0)") }
        return try preparation(tripId)
    }

    public func saveActivity(tripId: String, activityId: String?, activity draft: ActivityDraft) async throws -> TripPlan {
        let key = try activityId.map { id in try tripOfPlan({ $0.activities.contains { $0.id == id } }, "Aktivität") } ?? tripId
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError(status: 400, code: "invalid_request", message: "Die Aktivität braucht einen Namen.") }
        let activity = Activity(id: activityId ?? nextID("x"), title: draft.title, place: draft.place, url: draft.url, status: draft.status, startsAt: draft.startsAt,
                                endsAt: draft.endsAt, costCents: draft.costCents, costNote: draft.costNote, notes: draft.notes)
        if let index = plans[key]?.activities.firstIndex(where: { $0.id == activity.id }) { plans[key]?.activities[index] = activity }
        else { plans[key, default: TripPlan()].activities.append(activity) }
        return try preparation(key)
    }

    public func deleteActivity(activityId: String) async throws -> TripPlan {
        let key = try tripOfPlan({ $0.activities.contains { $0.id == activityId } }, "Aktivität")
        plans[key]?.activities.removeAll { $0.id == activityId }
        answers[activityId] = nil
        return try preparation(key)
    }

    public func respond(activityId: String, answer: String?) async throws -> TripPlan {
        let key = try tripOfPlan({ $0.activities.contains { $0.id == activityId } }, "Aktivität")
        answers[activityId, default: [:]][user.id] = answer
        return try preparation(key)
    }

    // MARK: Frame of the trip

    private var periods: [String: [DateOption]] = [
        "t-1": [DateOption(id: "d-1", label: "Pfingsten", startDate: "2027-05-15", endDate: "2027-05-29")],
        "t-2": [DateOption(id: "d-2", label: "Erste Hälfte", startDate: "2027-07-31", endDate: "2027-08-14"),
                DateOption(id: "d-3", label: "Zweite Hälfte", startDate: "2027-08-14", endDate: "2027-08-28")]]

    public func updateTrip(tripId: String, changes: TripChanges) async throws -> Trip {
        let index = try tripIndex(tripId)
        guard !changes.title.trimmingCharacters(in: .whitespaces).isEmpty, changes.adults >= 1 else {
            throw APIError(status: 400, code: "invalid_request", message: "Titel und mindestens ein Erwachsener sind nötig.")
        }
        trips[index].title = changes.title; trips[index].region = changes.region; trips[index].adults = changes.adults
        trips[index].children = changes.children; trips[index].pets = changes.pets; trips[index].budgetTotalCents = changes.budgetTotalCents
        return trips[index]
    }

    public func addDateOption(tripId: String, label: String?, startDate: String, endDate: String) async throws -> DateOption {
        _ = try tripIndex(tripId)
        guard endDate > startDate else { throw APIError(status: 400, code: "invalid_request", message: "Die Abreise muss nach der Anreise liegen.") }
        let option = DateOption(id: nextID("d"), label: label, startDate: startDate, endDate: endDate)
        periods[tripId, default: []].append(option)
        return option
    }

    public func removeDateOption(tripId: String, optionId: String) async throws {
        guard periods[tripId]?.contains(where: { $0.id == optionId }) == true else { throw APIError(status: 404, code: "not_found", message: "Diesen Zeitraum gibt es nicht.") }
        periods[tripId]?.removeAll { $0.id == optionId }
    }

    public func activity(tripId: String) async throws -> [ActivityEvent] {
        _ = try tripIndex(tripId)
        return [ActivityEvent(id: "a-4", type: "expense_added", createdAt: .now.addingTimeInterval(-3_600), userName: "Anna", numbers: ["amountCents": 23_460]),
                ActivityEvent(id: "a-3", type: "vote", createdAt: .now.addingTimeInterval(-86_400), userName: "Jonas"),
                ActivityEvent(id: "a-2", type: "candidate_added", createdAt: .now.addingTimeInterval(-172_800), userName: "Du", words: ["platform": "airbnb"]),
                ActivityEvent(id: "a-1", type: "trip_created", createdAt: .now.addingTimeInterval(-604_800), userName: "Du")]
    }

    // MARK: Shared purse

    private struct Purse {
        var parties: [LedgerParty] = []
        var expenses: [Expense] = []
        var payments: [LedgerPayment] = []
        var splitMode = "equal"
        var childWeight = 1.0
    }
    /// The first trip comes with households and a few expenses, so the purse has something to show.
    private var purses: [String: Purse] = ["t-1": Purse(
        parties: [LedgerParty(id: "p-1", name: "Familie von B.", adults: 2, children: 2, memberIds: ["u-1"]),
                  LedgerParty(id: "p-2", name: "Anna und Tom", adults: 2, children: 2, memberIds: ["u-2"]),
                  LedgerParty(id: "p-3", name: "Jonas", adults: 1, children: 0, memberIds: ["u-3"])],
        expenses: [Expense(id: "e-1", title: "Anzahlung Haus", amountCents: 145_800, paidBy: "p-1", spentOn: "2027-01-12", category: "Unterkunft"),
                   Expense(id: "e-2", title: "Großeinkauf", amountCents: 23_460, paidBy: "p-2", spentOn: "2027-05-15", category: "Lebensmittel", mode: "heads"),
                   Expense(id: "e-3", title: "Weinprobe", amountCents: 9_000, paidBy: "p-3", spentOn: "2027-05-18", category: "Ausflug",
                           mode: "custom", weights: ["p-1": 2, "p-2": 1, "p-3": 1])])]

    private func bill(_ tripId: String) throws -> Ledger {
        _ = try tripIndex(tripId)
        let purse = purses[tripId] ?? Purse()
        return LedgerMath.ledger(parties: purse.parties, expenses: purse.expenses, payments: purse.payments, splitMode: purse.splitMode,
                                 childWeight: purse.childWeight, myPartyId: purse.parties.first { $0.memberIds.contains(user.id) }?.id)
    }

    public func ledger(tripId: String) async throws -> Ledger { try bill(tripId) }

    public func suggestParties(tripId: String) async throws -> Ledger {
        guard (purses[tripId]?.parties ?? []).isEmpty else { throw APIError(status: 409, code: "already_set_up", message: "Es gibt schon Haushalte.") }
        let members = try await trip(tripId).members
        purses[tripId, default: Purse()].parties = members.map { LedgerParty(id: nextID("p"), name: $0.name, adults: 1, children: 0, memberIds: [$0.id]) }
        return try bill(tripId)
    }

    public func setParties(tripId: String, parties: [PartyDraft]) async throws -> Ledger {
        purses[tripId, default: Purse()].parties = parties.map {
            LedgerParty(id: $0.serverID ?? nextID("p"), name: $0.name, adults: $0.adults, children: $0.children, memberIds: $0.memberIds)
        }
        return try bill(tripId)
    }

    private func expense(_ id: String, from draft: ExpenseDraft) -> Expense {
        Expense(id: id, title: draft.title, amountCents: draft.amountCents, paidBy: draft.paidBy, spentOn: draft.spentOn, category: draft.category,
                mode: draft.mode, among: draft.among, weights: draft.weights, note: draft.note)
    }

    public func addExpense(tripId: String, expense draft: ExpenseDraft) async throws -> Ledger {
        guard !(purses[tripId]?.parties ?? []).isEmpty else { throw APIError(status: 409, code: "no_parties", message: "Lege zuerst die Haushalte an.") }
        purses[tripId, default: Purse()].expenses.append(expense(nextID("e"), from: draft))
        return try bill(tripId)
    }

    private func purse(ofExpense id: String) throws -> String {
        guard let key = purses.first(where: { $0.value.expenses.contains { $0.id == id } })?.key else {
            throw APIError(status: 404, code: "not_found", message: "Diese Ausgabe gibt es nicht.")
        }
        return key
    }

    public func updateExpense(expenseId: String, expense draft: ExpenseDraft) async throws -> Ledger {
        let key = try purse(ofExpense: expenseId)
        if let index = purses[key]?.expenses.firstIndex(where: { $0.id == expenseId }) { purses[key]?.expenses[index] = expense(expenseId, from: draft) }
        return try bill(key)
    }

    public func deleteExpense(expenseId: String) async throws -> Ledger {
        let key = try purse(ofExpense: expenseId)
        purses[key]?.expenses.removeAll { $0.id == expenseId }
        return try bill(key)
    }

    public func addPayment(tripId: String, from: String, to: String, amountCents: Int) async throws -> Ledger {
        purses[tripId, default: Purse()].payments.append(LedgerPayment(id: nextID("z"), fromParty: from, toParty: to, amountCents: amountCents))
        return try bill(tripId)
    }

    public func deletePayment(tripId: String, paymentId: String) async throws -> Ledger {
        purses[tripId]?.payments.removeAll { $0.id == paymentId }
        return try bill(tripId)
    }

    public func setSplit(tripId: String, splitMode: String, childWeight: Double) async throws {
        _ = try tripIndex(tripId)
        purses[tripId, default: Purse()].splitMode = splitMode
        purses[tripId, default: Purse()].childWeight = childWeight
    }

    // MARK: Phases and pitch

    private var finalists: [String: [String]] = [:]
    private var rankings: [String: [String: [String]]] = [:]
    private var decided: [String: String] = [:]
    /// Two fellow travellers who have already ranked, so the result has something to show.
    private let others = [("u-2", "Anna"), ("u-3", "Jonas")]

    private func tripIndex(_ id: String) throws -> Int {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { throw APIError(status: 404, code: "not_found", message: "Diese Reise gibt es nicht.") }
        return index
    }

    public func setPhase(tripId: String, phase: TripPhase) async throws {
        let index = try tripIndex(tripId)
        trips[index].phase = phase.rawValue
        trips[index].currentPhase = phase.rawValue
    }

    public func pitch(tripId: String) async throws -> Pitch {
        _ = try tripIndex(tripId)
        let ids = finalists[tripId] ?? []
        let own = rankings[tripId] ?? [:]
        let count = Double(ids.count)
        let all = try await candidates(tripId: tripId, dateOptionId: nil)
        var entries = ids.compactMap { id in all.first { $0.id == id } }.map { candidate -> Pitch.Finalist in
            var points = 0.0
            var first = 0
            for order in own.values {
                if let position = order.firstIndex(of: candidate.id) {
                    points += count - Double(position)
                    if position == 0 { first += 1 }
                }
            }
            let detail = details[candidate.id]
            return Pitch.Finalist(points: points, firstPlaces: first, candidate: candidate, summary: detail?.listing.profile.summary,
                                  highlights: detail?.listing.profile.highlights, warnings: detail?.listing.profile.warnings)
        }
        // Offers with a veto go behind those without, then by points, then by first places.
        entries.sort { a, b in
            let vetoA = a.candidate.votes.vetoes > 0, vetoB = b.candidate.votes.vetoes > 0
            if vetoA != vetoB { return !vetoA }
            if a.points != b.points { return (a.points ?? 0) > (b.points ?? 0) }
            return (a.firstPlaces ?? 0) > (b.firstPlaces ?? 0)
        }
        for index in entries.indices { entries[index].place = index + 1 }
        let people = [(user.id, user.name)] + others
        return Pitch(phase: trips.first { $0.id == tripId }?.currentPhase, decidedCandidateId: decided[tripId], maxPoints: count * Double(people.count),
                     finalists: entries,
                     rankings: people.compactMap { person in own[person.0].map { Pitch.Person(userId: person.0, name: person.1, order: $0) } },
                     myRanking: own[user.id] ?? [],
                     missing: ids.isEmpty ? [] : people.filter { own[$0.0] == nil }.map { Pitch.Person(userId: $0.0, name: $0.1) })
    }

    public func startPitch(tripId: String, candidateIds: [String]) async throws -> Pitch {
        guard (2...8).contains(candidateIds.count) else {
            throw APIError(status: 400, code: "invalid_request", message: "Für die Entscheidung braucht es zwei bis acht Angebote.")
        }
        finalists[tripId] = candidateIds
        // Anna has ranked already, in the order given; Jonas has not.
        rankings[tripId] = ["u-2": candidateIds]
        try await setPhase(tripId: tripId, phase: .decision)
        return try await pitch(tripId: tripId)
    }

    public func setRanking(tripId: String, order: [String]) async throws -> Pitch {
        let allowed = finalists[tripId] ?? []
        rankings[tripId, default: [:]][user.id] = order.filter(allowed.contains)
        return try await pitch(tripId: tripId)
    }

    public func decide(tripId: String, candidateId: String, dateOptionId: String?) async throws -> Pitch {
        let index = try tripIndex(tripId)
        decided[tripId] = candidateId
        trips[index].decidedCandidateId = candidateId
        trips[index].status = .decided
        try await setPhase(tripId: tripId, phase: .booking)
        return try await pitch(tripId: tripId)
    }

    public func undoDecision(tripId: String) async throws -> Pitch {
        let index = try tripIndex(tripId)
        decided[tripId] = nil
        trips[index].decidedCandidateId = nil
        trips[index].status = .planning
        try await setPhase(tripId: tripId, phase: .decision)
        return try await pitch(tripId: tripId)
    }

    // MARK: Criteria. The sample data measures a handful of things, enough to show the traffic light.

    private var criteriaByTrip: [String: [Criterion]] = [:]
    private var manualChecks: [String: [String: String]] = [:]

    private static let measurable = [
        Measurable(key: "bedrooms", label: "Schlafzimmer", group: "space", format: "number", rule: "min"),
        Measurable(key: "bathrooms", label: "Bäder", group: "space", format: "number", rule: "min"),
        Measurable(key: "maxGuests", label: "Gäste", group: "space", format: "number", rule: "min"),
        Measurable(key: "price.total", label: "Gesamtpreis", group: "price", format: "eur", rule: "max"),
        Measurable(key: "amenities.pool", label: "Pool", group: "amenities", format: "boolean", rule: "yes"),
        Measurable(key: "amenities.airConditioning", label: "Klimaanlage", group: "amenities", format: "boolean", rule: "yes"),
        Measurable(key: "amenities.petsAllowed", label: "Haustiere erlaubt", group: "amenities", format: "boolean", rule: "yes"),
    ]

    public func criteria(tripId: String) async throws -> CriteriaList {
        CriteriaList(criteria: criteriaByTrip[tripId] ?? [], measurable: Self.measurable)
    }

    public func setCriteria(tripId: String, criteria: [Criterion]) async throws -> CriteriaList {
        criteriaByTrip[tripId] = criteria.map { entry in
            var entry = entry
            if entry.id.isEmpty { entry.id = nextID("k") }
            return entry
        }
        return try await self.criteria(tripId: tripId)
    }

    public func setCriteriaChecks(candidateId: String, checks: [String: String]) async throws {
        _ = try detail(candidateId)
        manualChecks[candidateId] = checks
    }

    private func verdict(for detail: CandidateDetail, results wanted: Bool) -> CriteriaVerdict? {
        let list = criteriaByTrip[detail.candidate.tripId] ?? []
        guard !list.isEmpty else { return nil }
        let profile = detail.listing.profile
        var must = CriteriaVerdict.Count(), wish = CriteriaVerdict.Count()
        var results: [CriteriaVerdict.Result] = []
        for criterion in list {
            let known = Self.measurable.first { $0.key == criterion.key }
            var number: Double?
            var flag: Bool?
            switch criterion.key {
            case "bedrooms": number = profile.bedrooms
            case "bathrooms": number = profile.bathrooms
            case "maxGuests": number = profile.maxGuests
            case "price.total": number = detail.prices.first { $0.tripId == detail.candidate.tripId }?.totalCents.map { Double($0) / 100 }
            default: if criterion.key.hasPrefix("amenities.") { flag = profile.amenity(String(criterion.key.dropFirst(10))) }
            }
            var status = "unknown"
            if let number, let target = criterion.target {
                status = (known?.rule == "max" ? number <= target : number >= target) ? "met" : "missed"
            } else if let flag {
                status = flag ? "met" : "missed"
            }
            let manual = manualChecks[detail.candidate.id]?[criterion.id]
            if let manual { status = manual }
            if criterion.isMust {
                if status == "met" { must.met += 1 } else if status == "missed" { must.missed += 1 } else { must.unknown += 1 }
            } else {
                if status == "met" { wish.met += 1 } else if status == "missed" { wish.missed += 1 } else { wish.unknown += 1 }
            }
            results.append(.init(id: criterion.id, key: criterion.key, label: criterion.label ?? known?.label, level: criterion.level,
                                 rule: known?.rule, format: known?.format, target: criterion.target,
                                 value: number.map { ShownValue(Format.number($0)) } ?? flag.map { ShownValue($0 ? "Ja" : "Nein") },
                                 status: status, manual: manual != nil))
        }
        let light = must.missed > 0 ? "red" : (must.unknown > 0 || wish.missed > 0 || wish.unknown > 0) ? "yellow" : "green"
        return CriteriaVerdict(light: light, must: must, wish: wish, results: wanted ? results : nil)
    }

    public func candidate(_ id: String) async throws -> CandidateDetail {
        var found = try detail(id)
        found.criteria = verdict(for: found, results: true)
        return found
    }

    public func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult {
        if let existing = details.values.first(where: { $0.candidate.tripId == tripId && $0.sources.contains { $0.url == url } }) {
            return ImportResult(candidateId: existing.candidate.id, duplicate: true)
        }
        let id = nextID("c")
        let host = URL(string: url)?.host ?? ""
        let platform = ["airbnb", "novasol", "check24", "casamundo", "booking"].first { host.contains($0) } ?? (host.contains("fewo-direkt") || host.contains("vrbo") ? "vrbo" : "other")
        let blocked = platform == "vrbo" || platform == "casamundo"
        var profile = Profile()
        profile.title = "Neues Angebot (\(Format.platformName(platform)))"
        let listing = Listing(id: nextID("l"), title: profile.title, profile: profile, fillPercent: 4)
        let record = CandidateRecord(
            id: id, tripId: tripId, listingId: listing.id, importStatus: html == nil && blocked ? .partial : .failed,
            importNote: html == nil && blocked
                ? "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen."
                : "In der Demo wird nichts ausgelesen. Mit dem echten Server füllt sich der Steckbrief von selbst.")
        details[id] = CandidateDetail(candidate: record, role: .organizer, listing: listing,
                                      sources: [ListingSource(id: nextID("s"), platform: platform, url: url, canonicalUrl: url)])
        order.insert(id, at: 0)
        return ImportResult(candidateId: id, duplicate: false, platform: platform)
    }

    public func checkTrip(tripId: String, dateOptionId: String?) async throws -> TripCheck {
        let offers = order.compactMap { details[$0] }.filter { $0.candidate.tripId == tripId && $0.candidate.status != .rejected }
        for offer in offers { try await refresh(candidateId: offer.candidate.id) }
        return TripCheck(checks: offers.map { offer in
            let source = offer.sources.first
            let blocked = source?.platform == "vrbo" || source?.platform == "casamundo"
            return .init(candidateId: offer.candidate.id, platform: source?.platform, mode: blocked ? "device" : "server",
                         needsDevice: blocked, checkUrl: blocked ? source?.url : nil)
        })
    }

    public func capture(candidateId: String, html: String, sourceId: String?, forTrip: Bool, url: String?, dateOptionId: String?) async throws {
        var detail = try detail(candidateId)
        if forTrip {
            detail.candidate.importNote = "Für den Reisezeitraum auf dem Gerät geprüft (\(html.utf8.count / 1024) KB). In der Demo wird die Seite nicht ausgewertet."
            details[candidateId] = detail
            return
        }
        if let sourceId, let index = detail.sources.firstIndex(where: { $0.id == sourceId }) {
            detail.sources[index].read = true
            detail.sources[index].needsDevice = false
        } else {
            detail.candidate.importStatus = .failed
            detail.candidate.importNote = "Seite auf dem Gerät gelesen (\(html.utf8.count / 1024) KB). In der Demo wird sie nicht ausgewertet."
        }
        details[candidateId] = detail
    }

    public func searchOtherPlatforms(candidateId: String) async throws {
        var detail = try detail(candidateId)
        detail.otherPlatforms = OtherPlatforms(status: .done, searchedAt: .now, note: "Beispieltreffer. Mit dem echten Server sucht hier eine KI im Netz.", suggestions: [
            .init(id: nextID("v"), url: "https://www.fewo-direkt.de/", platform: "vrbo", title: detail.listing.title.map { "\($0) (FeWo-direkt)" },
                  reason: "Gleicher Ort, gleiche Zahl an Schlafzimmern, Pool.", confidence: .high),
            .init(id: nextID("v"), url: "https://www.casamundo.de/", platform: "casamundo", title: "Landhaus mit Pool",
                  reason: "Gleicher Ort, aber ein Schlafzimmer weniger.", confidence: .low),
        ])
        details[candidateId] = detail
    }

    public func decide(candidateId: String, suggestionId: String, accept: Bool) async throws {
        var detail = try detail(candidateId)
        guard var other = detail.otherPlatforms, let index = other.suggestions?.firstIndex(where: { $0.id == suggestionId }),
              let suggestion = other.suggestions?[index] else {
            throw APIError(status: 404, code: "not_found", message: "Diesen Vorschlag gibt es nicht mehr.")
        }
        other.suggestions?[index].status = accept ? .accepted : .rejected
        detail.otherPlatforms = other
        if accept {
            detail.sources.append(ListingSource(id: nextID("s"), platform: suggestion.platform, url: suggestion.url, canonicalUrl: suggestion.url,
                                                primary: false, read: false, needsDevice: true, title: suggestion.title))
        }
        details[candidateId] = detail
    }

    public func addSource(candidateId: String, url: String) async throws {
        var detail = try detail(candidateId)
        guard !detail.sources.contains(where: { $0.url == url }) else { return }
        detail.sources.append(ListingSource(id: nextID("s"), platform: "other", url: url, canonicalUrl: url, primary: false, read: false, needsDevice: true))
        details[candidateId] = detail
    }

    public func removeSource(candidateId: String, sourceId: String) async throws {
        var detail = try detail(candidateId)
        guard let index = detail.sources.firstIndex(where: { $0.id == sourceId }) else { return }
        guard index > 0 else { throw APIError(status: 409, code: "primary_source", message: "Die erste Quelle lässt sich nicht entfernen.") }
        detail.sources.remove(at: index)
        details[candidateId] = detail
    }

    /// In the sample data a check finds one offer booked out, to show what that looks like.
    public func refresh(candidateId: String) async throws {
        var detail = try detail(candidateId)
        guard candidateId == "c-2", !detail.prices.isEmpty else { return }
        detail.prices[0].available = false
        detail.prices[0].capturedAt = .now
        details[candidateId] = detail
    }

    public func setHiddenWarnings(candidateId: String, hidden: [String]) async throws {
        var detail = try detail(candidateId)
        detail.warnings = (detail.listing.profile.warnings ?? []).map { Hint(text: $0, hidden: hidden.contains($0)) }
        details[candidateId] = detail
    }

    public func move(candidateId: String, toTrip tripId: String) async throws -> String {
        var detail = try detail(candidateId)
        guard trips.contains(where: { $0.id == tripId }) else { throw APIError(status: 404, code: "not_found", message: "Diese Reise gibt es nicht.") }
        let url = detail.sources.first?.url
        if details.values.contains(where: { $0.candidate.tripId == tripId && $0.candidate.id != candidateId && $0.sources.first?.url == url }) {
            throw APIError(status: 409, code: "already_in_trip", message: "Dieses Angebot ist in der Zielreise schon vorhanden.")
        }
        detail.candidate.tripId = tripId
        detail.candidate.status = .new
        detail.votes = VoteOverview()
        // Prices asked for the old trip say nothing about the new one.
        detail.prices = detail.prices.map { var price = $0; price.tripId = nil; price.available = nil; return price }
        details[candidateId] = detail
        return candidateId
    }

    public func delete(candidateId: String) async throws {
        _ = try detail(candidateId)
        details[candidateId] = nil
        order.removeAll { $0 == candidateId }
    }

    public func setStatus(candidateId: String, status: CandidateStatus) async throws {
        var detail = try detail(candidateId)
        detail.candidate.status = status
        details[candidateId] = detail
    }

    public func vote(candidateId: String, verdict: Verdict, veto: Bool) async throws {
        var detail = try detail(candidateId)
        var entries = detail.votes.entries.filter { $0.userId != user.id }
        entries.append(VoteEntry(userId: user.id, name: user.name, verdict: verdict, veto: veto))
        detail.votes = VoteOverview(yes: entries.filter { $0.verdict == .yes }.count, maybe: entries.filter { $0.verdict == .maybe }.count,
                                    no: entries.filter { $0.verdict == .no }.count, vetoes: entries.filter(\.veto).count, entries: entries)
        details[candidateId] = detail
    }

    public func comment(candidateId: String, body: String) async throws {
        var detail = try detail(candidateId)
        detail.comments.append(Comment(id: nextID("k"), body: body, userId: user.id, name: user.name))
        details[candidateId] = detail
    }

    // MARK: Sample offers

    private static func samples() -> [CandidateDetail] {
        func home(_ id: String, trip: String, title: String, place: String, country: String, lat: Double, lon: Double, platform: String,
                  guests: Double, bedrooms: Double, baths: Double, sqm: Double?, total: Int, start: String, end: String, nights: Int, persons: Int,
                  status: CandidateStatus, amenities: [String: Bool?], uncertain: [String] = [], warnings: [String] = [],
                  votes: [VoteEntry] = [], comments: [Comment] = [], fill: Int) -> CandidateDetail {
            var profile = Profile()
            profile.kind = .vacationHome
            profile.title = title; profile.objectType = "Ferienhaus"; profile.place = place; profile.country = country
            profile.region = country == "Italien" ? "Toskana" : (country == "Dänemark" ? "Jütland" : nil)
            profile.lat = lat; profile.lon = lon
            profile.maxGuests = guests; profile.bedrooms = bedrooms; profile.bathrooms = baths; profile.livingAreaSqm = sqm
            profile.sleepingPlaces = guests; profile.amenities = amenities
            profile.rating = Rating(value: 4.7, scale: 5, count: 38)
            var distances = Profile.Distances(); distances.beachM = 450; distances.shopM = 1200; distances.townM = 2500; distances.airportKm = 85
            profile.distances = distances
            var rules = Profile.Rules(); rules.checkInFrom = "16:00"; rules.checkOutUntil = "10:00"; rules.arrivalDays = "Samstag"
            profile.rules = rules
            profile.cancellation = "Kostenlose Stornierung bis 60 Tage vor Anreise"
            profile.summary = "Freistehendes Haus mit großem Garten, ruhig gelegen, gut geeignet für zwei Familien."
            profile.highlights = ["Großer Garten", "Zwei Wohnbereiche"]
            profile.warnings = warnings
            profile.uncertain = uncertain
            let number = Int(id.dropFirst(2)) ?? 1
            let photos = (0..<(number == 3 ? 0 : 6 + number * 3)).map { index in
                Photo(id: "\(id)-\(index)", url: "demo://photo/\(number * 100 + index)?full=1", thumbUrl: "demo://photo/\(number * 100 + index)",
                      width: index % 4 == 3 ? 3000 : 4000, height: index % 4 == 3 ? 4000 : 3000)
            }
            let listing = Listing(id: "l-\(id)", title: title, place: place, country: country, lat: lat, lon: lon,
                                  coverImageUrl: photos.first?.thumbUrl, profile: profile, fillPercent: fill)
            let record = CandidateRecord(id: id, tripId: trip, listingId: listing.id, status: status)
            let price = PriceSnapshot(id: "p-\(id)", tripId: trip, startDate: start, endDate: end, nights: nights, persons: persons, totalCents: total,
                                      breakdown: [.init(item: "Miete", amountCents: total - 18_000), .init(item: "Endreinigung", amountCents: 18_000)])
            let older = PriceSnapshot(id: "p0-\(id)", tripId: trip, startDate: start, endDate: end, nights: nights, persons: persons,
                                      totalCents: total + 24_000, capturedAt: .now.addingTimeInterval(-9 * 86_400))
            return CandidateDetail(
                candidate: record, role: .organizer, listing: listing,
                sources: [ListingSource(id: "s-\(id)", platform: platform, url: "https://example.com/\(id)", canonicalUrl: "https://example.com/\(id)")],
                prices: [price, older],
                votes: VoteOverview(yes: votes.filter { $0.verdict == .yes }.count, maybe: votes.filter { $0.verdict == .maybe }.count,
                                    no: votes.filter { $0.verdict == .no }.count, vetoes: votes.filter(\.veto).count, entries: votes),
                comments: comments, photos: photos, otherPlatforms: OtherPlatforms(),
                reviews: number == 3 ? nil : Reviews(
                    summary: "Gäste loben vor allem die ruhige Lage, den großen Garten und die hilfsbereiten Vermieter. Die Küche gilt als gut ausgestattet. Mehrfach erwähnt werden die schmale Zufahrt und dass es im Obergeschoss im Hochsommer warm wird.",
                    positives: ["Ruhige Lage mit Weitblick", "Großer Garten, Pool gepflegt", "Vermieter schnell erreichbar", "Küche gut ausgestattet"],
                    negatives: ["Schmale, steile Zufahrt", "Obergeschoss im Sommer warm", "WLAN im Garten schwach"],
                    basedOn: 38, generatedAt: .now,
                    items: [
                        .init(id: "r-\(id)-1", author: "Familie M.", date: "2026-08-22", rating: 5, scale: 5, title: "Perfekt für zwei Familien",
                              text: "Wir waren mit acht Personen dort und hatten reichlich Platz. Der Pool war jeden Tag sauber, die Kinder wollten gar nicht mehr raus. Die Vermieterin hat uns frisches Gemüse vorbeigebracht.",
                              stayType: "Familie mit Kindern", platform: platform),
                        .init(id: "r-\(id)-2", author: "Thomas", date: "2026-07-05", rating: 4, scale: 5,
                              text: "Sehr schönes Haus, nur die Zufahrt ist mit einem großen Auto abenteuerlich. Oben wird es nachts warm, Ventilatoren sind vorhanden.",
                              ownerReply: "Danke für den Hinweis, wir haben inzwischen im Obergeschoss eine Klimaanlage nachgerüstet.", platform: platform),
                        .init(id: "r-\(id)-3", author: "Giulia", date: "2026-05-30", rating: 5, scale: 5, text: "Posto meraviglioso, casa pulitissima e proprietari gentilissimi.",
                              language: "it", translatedText: "Wunderschöner Ort, sehr sauberes Haus und überaus freundliche Eigentümer.", platform: platform),
                    ]))
        }

        var blocked = home("c-3", trip: "t-1", title: "Podere mit Blick auf San Gimignano", place: "San Gimignano", country: "Italien",
                           lat: 43.4677, lon: 11.0432, platform: "vrbo", guests: 10, bedrooms: 5, baths: 3, sqm: nil, total: 512_000,
                           start: "2027-05-15", end: "2027-05-29", nights: 14, persons: 8, status: .new, amenities: [:], fill: 18)
        blocked.candidate.importStatus = .partial
        blocked.candidate.importNote = "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen."
        blocked.sources = [ListingSource(id: "s-c-3", platform: "vrbo", url: "https://www.fewo-direkt.de/", canonicalUrl: "https://www.fewo-direkt.de/")]
        blocked.prices = []

        return [
            home("c-1", trip: "t-1", title: "Casa Olivia mit Pool", place: "Castellina in Chianti", country: "Italien", lat: 43.4701, lon: 11.2893,
                 platform: "airbnb", guests: 9, bedrooms: 4, baths: 3, sqm: 210, total: 486_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .favorite,
                 amenities: ["pool": true, "poolHeated": false, "airConditioning": true, "wifi": true, "dishwasher": true, "washingMachine": true, "grill": true, "parking": true, "cot": true, "highChair": true, "petsAllowed": false],
                 uncertain: ["livingAreaSqm", "amenities.grill"],
                 votes: [VoteEntry(userId: "u-2", name: "Anna", verdict: .yes), VoteEntry(userId: "u-3", name: "Jonas", verdict: .maybe)],
                 comments: [Comment(id: "k-1", body: "Der Pool ist nicht eingezäunt, das müssten wir mit den Kleinen klären.", createdAt: .now.addingTimeInterval(-86_400), userId: "u-2", name: "Anna")],
                 fill: 86),
            home("c-2", trip: "t-1", title: "Villa Il Poggio", place: "Greve in Chianti", country: "Italien", lat: 43.5846, lon: 11.3166,
                 platform: "novasol", guests: 8, bedrooms: 4, baths: 2, sqm: 180, total: 539_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .shortlist,
                 amenities: ["pool": true, "airConditioning": false, "wifi": true, "dishwasher": true, "washingMachine": true, "fireplace": true, "parking": true, "petsAllowed": true],
                 warnings: ["Das Inserat nennt 8 Gäste, die Reise hat 8 Personen: kein Spielraum.", "Die Endreinigung ist im Preis nicht enthalten."],
                 votes: [VoteEntry(userId: "u-2", name: "Anna", verdict: .no, veto: false)], fill: 78),
            blocked,
            home("c-5", trip: "t-1", title: "Villa Gradina am Strand", place: "Vela Luka", country: "Kroatien", lat: 42.9614, lon: 16.7189,
                 platform: "airbnb", guests: 10, bedrooms: 5, baths: 4, sqm: 230, total: 574_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .new,
                 amenities: ["pool": true, "airConditioning": true, "wifi": true, "dishwasher": true, "grill": true, "seaView": true, "parking": true],
                 fill: 74),
            home("c-4", trip: "t-2", title: "Reetdachhaus hinter der Düne", place: "Henne Strand", country: "Dänemark", lat: 55.7372, lon: 8.1832,
                 platform: "novasol", guests: 12, bedrooms: 6, baths: 3, sqm: 240, total: 398_000, start: "2027-07-31", end: "2027-08-14", nights: 14,
                 persons: 11, status: .new,
                 amenities: ["pool": true, "poolHeated": true, "wifi": true, "dishwasher": true, "washingMachine": true, "sauna": true, "hotTub": true, "fireplace": true, "parking": true, "evCharger": true, "petsAllowed": true],
                 fill: 91),
        ]
    }
}
