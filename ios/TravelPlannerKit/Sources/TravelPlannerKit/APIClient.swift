import Foundation

/// An error answered by the backend, or a transport problem. `message` is German and can be shown as is.
public struct APIError: LocalizedError, Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status; self.code = code; self.message = message
    }

    public var errorDescription: String? { message }
    public var isUnauthorized: Bool { status == 401 }
}

/// Everything the app needs from a signed-in backend. `APIClient` talks to the server, `DemoBackend` to sample data.
public protocol TravelBackend: Sendable {
    func me() async throws -> User
    func trips() async throws -> [Trip]
    func trip(_ id: String) async throws -> TripDetail
    func createTrip(_ trip: NewTrip) async throws -> Trip
    func createInvite(tripId: String, role: MemberRole) async throws -> Invite
    /// The own groups with their members and trips.
    func groups() async throws -> [TravelGroup]
    func createGroup(name: String) async throws -> [TravelGroup]
    func renameGroup(groupId: String, name: String) async throws -> [TravelGroup]
    /// Invite links into the group that are still open. Admins only.
    func groupInvites(groupId: String) async throws -> [GroupInvite]
    func revokeGroupInvite(groupId: String, inviteId: String) async throws
    /// Changes the own name, as the others see it.
    func rename(name: String) async throws -> User
    /// A link that leads into the group. Admins only; shown once.
    func createGroupInvite(groupId: String) async throws -> Invite
    /// Removes someone, or leaves the group when it is the own id.
    func removeGroupMember(groupId: String, userId: String) async throws -> [TravelGroup]
    func setGroupRole(groupId: String, userId: String, admin: Bool) async throws -> [TravelGroup]
    /// Puts a trip into a group, or makes it private with nil.
    func setTripGroup(tripId: String, groupId: String?) async throws
    /// Adverts on any of the own trips that still wait for a device to read them.
    func pendingReadings() async throws -> [PendingReading]
    /// Asks for one stay of one advert: tells where its page is, or that the server reads it itself.
    func checkStay(tripId: String, candidateId: String, startDate: String, endDate: String) async throws -> TripCheck
    /// Hands over a page read for one stay inside the trip's flexible window.
    func captureStay(candidateId: String, html: String, url: String?, startDate: String, endDate: String) async throws
    /// Changes the frame of the trip: title, region, party and budget. Organiser only.
    func updateTrip(tripId: String, changes: TripChanges) async throws -> Trip
    func addDateOption(tripId: String, label: String?, startDate: String, endDate: String) async throws -> DateOption
    func removeDateOption(tripId: String, optionId: String) async throws
    /// The chronicle: the last hundred events of the trip, newest first.
    func activity(tripId: String) async throws -> [ActivityEvent]
    /// Packing, shopping, tasks and lists of the group's own.
    func checklists(tripId: String) async throws -> Checklists
    func addChecklistItem(tripId: String, list: String, title: String, quantity: String?, isPrivate: Bool) async throws -> Checklists
    func updateChecklistItem(itemId: String, change: ChecklistChange) async throws -> Checklists
    func deleteChecklistItem(itemId: String) async throws -> Checklists
    /// Adds the lines of a template; lines of the same name stay as they are.
    func applyChecklistTemplate(tripId: String, template: String) async throws -> Checklists
    /// What was booked, with payment plan, deadlines and papers. The app does not book anything itself.
    func bookings(tripId: String) async throws -> BookingOverview
    func addBooking(tripId: String, booking: BookingDraft) async throws -> BookingOverview
    func updateBooking(bookingId: String, booking: BookingDraft) async throws -> BookingOverview
    func deleteBooking(bookingId: String) async throws -> BookingOverview
    func addBookingPayment(bookingId: String, label: String, amountCents: Int, dueOn: String?, refundable: Bool) async throws -> BookingOverview
    /// Ticks a payment off as paid, or back to open with nil.
    func setBookingPaymentPaid(paymentId: String, paidOn: String?, paidByParty: String?) async throws -> BookingOverview
    func deleteBookingPayment(paymentId: String) async throws -> BookingOverview
    /// Stores a paper of the trip, optionally with a booking.
    func uploadDocument(tripId: String, title: String, bookingId: String?, contentType: String, data: Data) async throws
    func documentFile(documentId: String) async throws -> Data
    func deleteDocument(documentId: String) async throws
    /// The preparation: how everyone gets there, who sleeps where, and what the group wants to do.
    func plan(tripId: String) async throws -> TripPlan
    /// Adds a leg, or changes the one with this id.
    func saveLeg(tripId: String, legId: String?, leg: LegDraft) async throws -> TripPlan
    func deleteLeg(legId: String) async throws -> TripPlan
    func saveRoom(tripId: String, roomId: String?, room: RoomDraft) async throws -> TripPlan
    func deleteRoom(roomId: String) async throws -> TripPlan
    /// Sets the rooms up as the fact sheet of the decided offer names them.
    func suggestRooms(tripId: String) async throws -> TripPlan
    func saveActivity(tripId: String, activityId: String?, activity: ActivityDraft) async throws -> TripPlan
    func deleteActivity(activityId: String) async throws -> TripPlan
    /// "yes", "maybe" or "no"; nil takes the answer back.
    func respond(activityId: String, answer: String?) async throws -> TripPlan
    /// The house book of the trip with what fact sheet and booking suggest for empty fields.
    func house(tripId: String) async throws -> HouseBook
    /// Changes only the given fields; `.null` empties one.
    func updateHouse(tripId: String, changes: [String: PatchValue]) async throws -> HouseBook
    /// What happens on this day at the destination, as `JJJJ-MM-TT`.
    func today(tripId: String, date: String) async throws -> TripDay
    /// `dateOptionId` picks the period that price and availability refer to; nil means the earliest.
    func candidates(tripId: String, dateOptionId: String?) async throws -> [CandidateSummary]
    /// Moves the trip to a phase by hand, forwards or back. Nothing is deleted.
    func setPhase(tripId: String, phase: TripPhase) async throws
    func pitch(tripId: String) async throws -> Pitch
    /// Names the finalists (two to eight) and opens the decision round.
    func startPitch(tripId: String, candidateIds: [String]) async throws -> Pitch
    /// The own order of the finalists, best first. May leave some out.
    func setRanking(tripId: String, order: [String]) async throws -> Pitch
    /// Records the winner. The trip moves on to booking.
    func decide(tripId: String, candidateId: String, dateOptionId: String?) async throws -> Pitch
    func undoDecision(tripId: String) async throws -> Pitch
    /// The shared purse: households, expenses, balances and the suggested settling payments.
    func ledger(tripId: String) async throws -> Ledger
    /// Sets up one household per member as a start. Fails when there are households already.
    func suggestParties(tripId: String) async throws -> Ledger
    /// Replaces the households. Entries that keep their id keep their expenses.
    func setParties(tripId: String, parties: [PartyDraft]) async throws -> Ledger
    func addExpense(tripId: String, expense: ExpenseDraft) async throws -> Ledger
    func updateExpense(expenseId: String, expense: ExpenseDraft) async throws -> Ledger
    func deleteExpense(expenseId: String) async throws -> Ledger
    /// Ticks off a settling payment as made.
    func addPayment(tripId: String, from: String, to: String, amountCents: Int) async throws -> Ledger
    func deletePayment(tripId: String, paymentId: String) async throws -> Ledger
    /// How the trip splits by default: "equal" or "heads", and how much a child counts.
    func setSplit(tripId: String, splitMode: String, childWeight: Double) async throws
    func criteria(tripId: String) async throws -> CriteriaList
    /// Replaces the criteria of the trip. Entries that keep their id keep the verdicts given by hand.
    func setCriteria(tripId: String, criteria: [Criterion]) async throws -> CriteriaList
    /// Sets the verdicts given by hand for one offer, by criterion id: "met" or "missed". Replaces all earlier ones.
    func setCriteriaChecks(candidateId: String, checks: [String: String]) async throws
    func candidate(_ id: String) async throws -> CandidateDetail
    func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult
    /// Hands a page read on the device to the server. `sourceId` names the source it belongs to; nil means the leading one.
    /// `forTrip` says the page was opened for the dates and party of the trip, so its price and availability count for it.
    /// `url` is the address the page was read from, so the server can tell which dates it was opened for.
    func capture(candidateId: String, html: String, sourceId: String?, forTrip: Bool, url: String?, dateOptionId: String?) async throws
    /// Checks every offer of the trip for its dates and party. Tells which offers a device has to read.
    func checkTrip(tripId: String, dateOptionId: String?) async throws -> TripCheck
    /// Starts the search for the same house on other platforms. Costs money on the server, so only on request.
    func searchOtherPlatforms(candidateId: String) async throws
    /// Confirms or dismisses a page the search suggested.
    func decide(candidateId: String, suggestionId: String, accept: Bool) async throws
    /// Adds a link to the same house on another platform by hand.
    func addSource(candidateId: String, url: String) async throws
    /// Removes a further source with its prices and reviews. The leading source cannot be removed.
    func removeSource(candidateId: String, sourceId: String) async throws
    /// Asks the server to read the advert again. Progress shows in `importStatus`, as after an import.
    func refresh(candidateId: String) async throws
    /// Corrects the fact sheet by hand. Only the changed fields, by their name in the profile.
    func correctProfile(candidateId: String, changes: [String: PatchValue]) async throws
    /// Notes a price by hand. It counts for the trip the offer belongs to.
    func addPrice(candidateId: String, price: ManualPrice) async throws
    func setStatus(candidateId: String, status: CandidateStatus) async throws
    /// Sets which hints of an offer are hidden for the whole trip, by their exact wording. An empty list shows all again.
    func setHiddenWarnings(candidateId: String, hidden: [String]) async throws
    /// Moves the offer to another trip or to the watchlist. Votes and prices for the old trip stay behind.
    /// Returns the offer's id in its new place.
    func move(candidateId: String, toTrip tripId: String) async throws -> String
    /// Removes the offer from its trip, with its votes and comments. Cannot be undone.
    func delete(candidateId: String) async throws
    func vote(candidateId: String, verdict: Verdict, veto: Bool) async throws
    func comment(candidateId: String, body: String) async throws
    func logout() async throws
    /// The request that loads a picture, or nil when the address is unusable.
    func imageRequest(for address: String) -> URLRequest?
}

public struct APIClient: TravelBackend {
    public var baseURL: URL
    public var token: String?
    private let session: URLSession

    /// The server refuses request bodies above 6 MB; pages beyond this are sent without their content.
    public static let maxPageBytes = 5_500_000

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Coding

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Kein Zeitpunkt: \(text)"))
        }
        return decoder
    }()

    /// Timestamps arrive as ISO 8601, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private static let encoder = JSONEncoder()

    // MARK: Transport

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    private struct Empty: Decodable {}

    func request(_ method: String, _ path: String, body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString.trimmingSuffix("/") + path) else {
            throw APIError(status: 0, code: "bad_url", message: "Die Serveradresse ist ungültig.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func data(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Data {
        try await perform(try request(method, path, body: body))
    }

    /// Pauses before the second, third, ... try, in seconds. Together they bridge a restart of the server,
    /// which answers with 502 for a quarter of a minute.
    static let retryPauses: [Double] = [1, 2, 4, 6, 8]

    /// Whether a failed try is worth another one without telling the person.
    /// Reading, replacing and deleting (GET, PUT, DELETE) can go again after a gateway answer or a lost connection:
    /// doing them twice changes nothing. Creating and changing (POST, PATCH) go again only when the request never
    /// left the device, so nothing is ever entered twice.
    static func worthRetrying(status: Int?, failure: URLError.Code?, method: String) -> Bool {
        let repeatable = method == "GET" || method == "PUT" || method == "DELETE"
        if let status { return repeatable && (status == 502 || status == 503 || status == 504) }
        guard let failure else { return false }
        switch failure {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        case .networkConnectionLost, .timedOut: return repeatable
        default: return false
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        var tries = 0
        while true {
            do {
                return try await once(request)
            } catch let error as Failure {
                guard tries < Self.retryPauses.count, Self.worthRetrying(status: error.status, failure: error.code, method: method) else { throw error.shown }
                try await Task.sleep(for: .seconds(Self.retryPauses[tries]))
                tries += 1
            }
        }
    }

    /// One failed try, with what is needed to decide about another one.
    private struct Failure: Error {
        var status: Int?
        var code: URLError.Code?
        var shown: APIError
    }

    private func once(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Failure(status: nil, code: error.code, shown: APIError(status: 0, code: "offline", message: "Der Server ist nicht erreichbar. (\(error.localizedDescription))"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let body = try? Self.decoder.decode(ErrorBody.self, from: data) {
                throw Failure(status: status, code: nil, shown: APIError(status: status, code: body.error.code, message: body.error.message))
            }
            let message = (502...504).contains(status) ? "Der Server startet gerade neu oder ist kurz nicht erreichbar. Bitte versuche es gleich noch einmal."
                                                       : "Der Server hat mit Status \(status) geantwortet."
            throw Failure(status: status, code: nil, shown: APIError(status: status, code: "http_\(status)", message: message))
        }
        return data
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await data(method, path, body: body)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 200, code: "decoding", message: "Die Antwort des Servers konnte nicht gelesen werden. (\(error))")
        }
    }

    // MARK: Pictures

    /// Pictures stored on our own server need the sign-in; a platform's image host must never see the token.
    public func imageRequest(for address: String) -> URLRequest? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if text.hasPrefix("/") && !text.hasPrefix("//") {
            url = URL(string: baseURL.absoluteString.trimmingSuffix("/") + text)
        } else {
            url = URL(string: text)
        }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host() else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let sameServer = host.lowercased() == baseURL.host()?.lowercased() && url.port == baseURL.port && scheme == baseURL.scheme?.lowercased()
        if sameServer, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: Sign-in (no token needed)

    public func bootstrap(secret: String, name: String, deviceName: String?) async throws -> AuthResult {
        struct Body: Encodable { var secret: String; var name: String; var deviceName: String? }
        return try await send("POST", "/auth/bootstrap", body: Body(secret: secret, name: name, deviceName: deviceName))
    }

    public func inviteInfo(token: String) async throws -> InviteInfo {
        try await send("GET", "/auth/invites/\(token.pathEscaped)")
    }

    public func acceptInvite(token: String, name: String?, deviceName: String?) async throws -> AuthResult {
        struct Body: Encodable { var name: String?; var deviceName: String? }
        return try await send("POST", "/auth/invites/\(token.pathEscaped)/accept", body: Body(name: name, deviceName: deviceName))
    }

    // MARK: Sign in with Apple

    /// Opens the account an Apple ID is linked to. Fails with `apple_not_linked` when there is none: the Apple ID never creates an account.
    public func signInWithApple(identityToken: String, nonce: String?, deviceName: String?) async throws -> AuthResult {
        struct Body: Encodable { var identityToken: String; var nonce: String?; var deviceName: String? }
        return try await send("POST", "/auth/apple", body: Body(identityToken: identityToken, nonce: nonce, deviceName: deviceName))
    }

    /// Links the Apple ID to the signed-in account.
    public func linkApple(identityToken: String, nonce: String?) async throws -> User {
        struct Body: Encodable { var identityToken: String; var nonce: String? }
        struct Response: Decodable { var user: User }
        return try await (send("PUT", "/me/apple", body: Body(identityToken: identityToken, nonce: nonce)) as Response).user
    }

    public func unlinkApple() async throws {
        _ = try await data("DELETE", "/me/apple")
    }

    // MARK: TravelBackend

    public func me() async throws -> User {
        struct Response: Decodable { var user: User }
        return try await (send("GET", "/me") as Response).user
    }

    public func logout() async throws {
        _ = try await data("POST", "/auth/logout")
    }

    public func trips() async throws -> [Trip] {
        struct Response: Decodable { var trips: [Trip] }
        return try await (send("GET", "/trips") as Response).trips
    }

    public func trip(_ id: String) async throws -> TripDetail {
        try await send("GET", "/trips/\(id.pathEscaped)")
    }

    public func createTrip(_ trip: NewTrip) async throws -> Trip {
        struct Response: Decodable { var trip: Trip }
        return try await (send("POST", "/trips", body: trip) as Response).trip
    }

    public func createInvite(tripId: String, role: MemberRole) async throws -> Invite {
        struct Body: Encodable { var role: MemberRole; var maxUses: Int; var expiresInDays: Int }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/invites", body: Body(role: role, maxUses: 1, expiresInDays: 14))
    }

    public func candidates(tripId: String, dateOptionId: String?) async throws -> [CandidateSummary] {
        struct Response: Decodable { var candidates: [CandidateSummary] }
        let query = dateOptionId.map { "?dateOptionId=\($0.pathEscaped)" } ?? ""
        return try await (send("GET", "/trips/\(tripId.pathEscaped)/candidates\(query)") as Response).candidates
    }

    public func setPhase(tripId: String, phase: TripPhase) async throws {
        struct Body: Encodable { var phase: String }
        _ = try await data("PATCH", "/trips/\(tripId.pathEscaped)", body: Body(phase: phase.rawValue))
    }

    public func pitch(tripId: String) async throws -> Pitch {
        try await send("GET", "/trips/\(tripId.pathEscaped)/pitch")
    }

    public func startPitch(tripId: String, candidateIds: [String]) async throws -> Pitch {
        struct Body: Encodable { var candidateIds: [String] }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/pitch", body: Body(candidateIds: candidateIds))
    }

    public func setRanking(tripId: String, order: [String]) async throws -> Pitch {
        struct Body: Encodable { var order: [String] }
        return try await send("PUT", "/trips/\(tripId.pathEscaped)/ranking", body: Body(order: order))
    }

    public func decide(tripId: String, candidateId: String, dateOptionId: String?) async throws -> Pitch {
        struct Body: Encodable { var candidateId: String; var dateOptionId: String? }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/decision", body: Body(candidateId: candidateId, dateOptionId: dateOptionId))
    }

    public func undoDecision(tripId: String) async throws -> Pitch {
        try await send("DELETE", "/trips/\(tripId.pathEscaped)/decision")
    }

    public func correctProfile(candidateId: String, changes: [String: PatchValue]) async throws {
        _ = try await data("PATCH", "/candidates/\(candidateId.pathEscaped)/profile", body: changes)
    }

    public func addPrice(candidateId: String, price: ManualPrice) async throws {
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/prices", body: price)
    }

    // MARK: Lists and bookings

    private struct ChecklistAnswer: Decodable { var checklists: Checklists }
    private struct BookingAnswer: Decodable { var overview: BookingOverview }

    public func checklists(tripId: String) async throws -> Checklists {
        try await send("GET", "/trips/\(tripId.pathEscaped)/checklists")
    }

    public func addChecklistItem(tripId: String, list: String, title: String, quantity: String?, isPrivate: Bool) async throws -> Checklists {
        struct Body: Encodable {
            var list: String; var title: String; var quantity: String?; var isPrivate: Bool
            enum CodingKeys: String, CodingKey { case list, title, quantity, isPrivate = "private" }
        }
        return try await (send("POST", "/trips/\(tripId.pathEscaped)/checklist-items", body: Body(list: list, title: title, quantity: quantity, isPrivate: isPrivate)) as ChecklistAnswer).checklists
    }

    public func updateChecklistItem(itemId: String, change: ChecklistChange) async throws -> Checklists {
        try await (send("PATCH", "/checklist-items/\(itemId.pathEscaped)", body: change) as ChecklistAnswer).checklists
    }

    public func deleteChecklistItem(itemId: String) async throws -> Checklists {
        try await (send("DELETE", "/checklist-items/\(itemId.pathEscaped)") as ChecklistAnswer).checklists
    }

    public func applyChecklistTemplate(tripId: String, template: String) async throws -> Checklists {
        struct Body: Encodable { var template: String }
        return try await (send("POST", "/trips/\(tripId.pathEscaped)/checklists/template", body: Body(template: template)) as ChecklistAnswer).checklists
    }

    public func bookings(tripId: String) async throws -> BookingOverview {
        try await send("GET", "/trips/\(tripId.pathEscaped)/bookings")
    }

    public func addBooking(tripId: String, booking: BookingDraft) async throws -> BookingOverview {
        try await (send("POST", "/trips/\(tripId.pathEscaped)/bookings", body: booking) as BookingAnswer).overview
    }

    public func updateBooking(bookingId: String, booking: BookingDraft) async throws -> BookingOverview {
        try await (send("PATCH", "/bookings/\(bookingId.pathEscaped)", body: booking) as BookingAnswer).overview
    }

    public func deleteBooking(bookingId: String) async throws -> BookingOverview {
        try await (send("DELETE", "/bookings/\(bookingId.pathEscaped)") as BookingAnswer).overview
    }

    public func addBookingPayment(bookingId: String, label: String, amountCents: Int, dueOn: String?, refundable: Bool) async throws -> BookingOverview {
        struct Body: Encodable { var label: String; var amountCents: Int; var dueOn: String?; var refundable: Bool }
        return try await (send("POST", "/bookings/\(bookingId.pathEscaped)/payments", body: Body(label: label, amountCents: amountCents, dueOn: dueOn, refundable: refundable)) as BookingAnswer).overview
    }

    public func setBookingPaymentPaid(paymentId: String, paidOn: String?, paidByParty: String?) async throws -> BookingOverview {
        struct Body: Encodable {
            var paidOn: String?; var paidByParty: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(paidOn, forKey: .paidOn); try c.encode(paidByParty, forKey: .paidByParty)
            }
            enum CodingKeys: String, CodingKey { case paidOn, paidByParty }
        }
        return try await (send("PATCH", "/booking-payments/\(paymentId.pathEscaped)", body: Body(paidOn: paidOn, paidByParty: paidByParty)) as BookingAnswer).overview
    }

    public func deleteBookingPayment(paymentId: String) async throws -> BookingOverview {
        try await (send("DELETE", "/booking-payments/\(paymentId.pathEscaped)") as BookingAnswer).overview
    }

    public func uploadDocument(tripId: String, title: String, bookingId: String?, contentType: String, data: Data) async throws {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "title", value: title)] + (bookingId.map { [URLQueryItem(name: "bookingId", value: $0)] } ?? [])
        var request = try request("POST", "/trips/\(tripId.pathEscaped)/documents?\(query.percentEncodedQuery ?? "")")
        request.httpBody = data
        request.timeoutInterval = 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    public func documentFile(documentId: String) async throws -> Data {
        var request = try request("GET", "/documents/\(documentId.pathEscaped)/file")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return try await perform(request)
    }

    public func deleteDocument(documentId: String) async throws {
        _ = try await data("DELETE", "/documents/\(documentId.pathEscaped)")
    }

    // MARK: Preparation

    private struct PlanAnswer: Decodable { var plan: TripPlan }

    public func plan(tripId: String) async throws -> TripPlan {
        try await send("GET", "/trips/\(tripId.pathEscaped)/plan")
    }

    private func savePlanEntry(_ kind: String, tripId: String, id: String?, body: any Encodable) async throws -> TripPlan {
        if let id { return try await (send("PATCH", "/\(kind)/\(id.pathEscaped)", body: body) as PlanAnswer).plan }
        return try await (send("POST", "/trips/\(tripId.pathEscaped)/\(kind)", body: body) as PlanAnswer).plan
    }

    public func saveLeg(tripId: String, legId: String?, leg: LegDraft) async throws -> TripPlan {
        try await savePlanEntry("legs", tripId: tripId, id: legId, body: leg)
    }

    public func deleteLeg(legId: String) async throws -> TripPlan {
        try await (send("DELETE", "/legs/\(legId.pathEscaped)") as PlanAnswer).plan
    }

    public func saveRoom(tripId: String, roomId: String?, room: RoomDraft) async throws -> TripPlan {
        try await savePlanEntry("rooms", tripId: tripId, id: roomId, body: room)
    }

    public func deleteRoom(roomId: String) async throws -> TripPlan {
        try await (send("DELETE", "/rooms/\(roomId.pathEscaped)") as PlanAnswer).plan
    }

    public func suggestRooms(tripId: String) async throws -> TripPlan {
        try await (send("POST", "/trips/\(tripId.pathEscaped)/rooms/suggest") as PlanAnswer).plan
    }

    public func saveActivity(tripId: String, activityId: String?, activity: ActivityDraft) async throws -> TripPlan {
        try await savePlanEntry("activities", tripId: tripId, id: activityId, body: activity)
    }

    public func deleteActivity(activityId: String) async throws -> TripPlan {
        try await (send("DELETE", "/activities/\(activityId.pathEscaped)") as PlanAnswer).plan
    }

    public func respond(activityId: String, answer: String?) async throws -> TripPlan {
        struct Body: Encodable {
            var answer: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(answer, forKey: .answer)
            }
            enum CodingKeys: String, CodingKey { case answer }
        }
        return try await (send("PUT", "/activities/\(activityId.pathEscaped)/response", body: Body(answer: answer)) as PlanAnswer).plan
    }

    // MARK: On the road

    public func house(tripId: String) async throws -> HouseBook {
        try await send("GET", "/trips/\(tripId.pathEscaped)/house")
    }

    public func updateHouse(tripId: String, changes: [String: PatchValue]) async throws -> HouseBook {
        try await send("PUT", "/trips/\(tripId.pathEscaped)/house", body: changes)
    }

    public func today(tripId: String, date: String) async throws -> TripDay {
        try await send("GET", "/trips/\(tripId.pathEscaped)/today?date=\(date.pathEscaped)")
    }

    // MARK: Groups, invites, pending readings, stays

    private struct GroupsAnswer: Decodable { var groups: [TravelGroup] }

    public func groups() async throws -> [TravelGroup] {
        try await (send("GET", "/groups") as GroupsAnswer).groups
    }

    public func createGroup(name: String) async throws -> [TravelGroup] {
        struct Body: Encodable { var name: String }
        return try await (send("POST", "/groups", body: Body(name: name)) as GroupsAnswer).groups
    }

    public func groupInvites(groupId: String) async throws -> [GroupInvite] {
        struct Answer: Decodable { var invites: [GroupInvite] }
        return try await (send("GET", "/groups/\(groupId.pathEscaped)/invites") as Answer).invites
    }

    public func revokeGroupInvite(groupId: String, inviteId: String) async throws {
        _ = try await data("DELETE", "/groups/\(groupId.pathEscaped)/invites/\(inviteId.pathEscaped)")
    }

    public func rename(name: String) async throws -> User {
        struct Body: Encodable { var name: String }
        struct Answer: Decodable { var user: User }
        return try await (send("PATCH", "/me", body: Body(name: name)) as Answer).user
    }

    public func renameGroup(groupId: String, name: String) async throws -> [TravelGroup] {
        struct Body: Encodable { var name: String }
        return try await (send("PATCH", "/groups/\(groupId.pathEscaped)", body: Body(name: name)) as GroupsAnswer).groups
    }

    public func createGroupInvite(groupId: String) async throws -> Invite {
        struct Body: Encodable { var maxUses: Int; var expiresInDays: Int }
        struct Answer: Decodable { var token: String; var url: String; var expiresAt: Date?; var maxUses: Int? }
        let answer: Answer = try await send("POST", "/groups/\(groupId.pathEscaped)/invites", body: Body(maxUses: 1, expiresInDays: 14))
        return Invite(token: answer.token, url: answer.url, role: .member, expiresAt: answer.expiresAt, maxUses: answer.maxUses)
    }

    public func removeGroupMember(groupId: String, userId: String) async throws -> [TravelGroup] {
        try await (send("DELETE", "/groups/\(groupId.pathEscaped)/members/\(userId.pathEscaped)") as GroupsAnswer).groups
    }

    public func setGroupRole(groupId: String, userId: String, admin: Bool) async throws -> [TravelGroup] {
        struct Body: Encodable { var role: String }
        return try await (send("PATCH", "/groups/\(groupId.pathEscaped)/members/\(userId.pathEscaped)", body: Body(role: admin ? "admin" : "member")) as GroupsAnswer).groups
    }

    public func setTripGroup(tripId: String, groupId: String?) async throws {
        struct Body: Encodable {
            var groupId: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(groupId, forKey: .groupId)
            }
            enum CodingKeys: String, CodingKey { case groupId }
        }
        _ = try await data("PATCH", "/trips/\(tripId.pathEscaped)", body: Body(groupId: groupId))
    }

    /// Redeems an invite link while signed in: the whole link or only its last part.
    public func redeemInvite(link: String) async throws -> AuthResult {
        struct Body: Encodable { var link: String }
        return try await send("POST", "/invites/redeem", body: Body(link: link))
    }

    public func pendingReadings() async throws -> [PendingReading] {
        struct Answer: Decodable { var pending: [PendingReading] }
        return try await (send("GET", "/me/pending-readings") as Answer).pending
    }

    public func checkStay(tripId: String, candidateId: String, startDate: String, endDate: String) async throws -> TripCheck {
        struct Body: Encodable { var startDate: String; var endDate: String; var candidateId: String }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/check", body: Body(startDate: startDate, endDate: endDate, candidateId: candidateId))
    }

    public func captureStay(candidateId: String, html: String, url: String?, startDate: String, endDate: String) async throws {
        struct Body: Encodable { var html: String; var forTrip: Bool; var url: String?; var startDate: String; var endDate: String }
        guard html.utf8.count <= Self.maxPageBytes else {
            throw APIError(status: 0, code: "too_large", message: "Die Seite ist zu groß, um sie zu übertragen.")
        }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/capture", body: Body(html: html, forTrip: true, url: url, startDate: startDate, endDate: endDate))
    }

    // MARK: Frame of the trip

    public func updateTrip(tripId: String, changes: TripChanges) async throws -> Trip {
        struct Answer: Decodable { var trip: Trip }
        return try await (send("PATCH", "/trips/\(tripId.pathEscaped)", body: changes) as Answer).trip
    }

    public func addDateOption(tripId: String, label: String?, startDate: String, endDate: String) async throws -> DateOption {
        struct Body: Encodable { var label: String?; var startDate: String; var endDate: String }
        struct Answer: Decodable { var dateOption: DateOption }
        return try await (send("POST", "/trips/\(tripId.pathEscaped)/date-options", body: Body(label: label, startDate: startDate, endDate: endDate)) as Answer).dateOption
    }

    public func removeDateOption(tripId: String, optionId: String) async throws {
        _ = try await data("DELETE", "/trips/\(tripId.pathEscaped)/date-options/\(optionId.pathEscaped)")
    }

    public func activity(tripId: String) async throws -> [ActivityEvent] {
        struct Answer: Decodable { var events: [ActivityEvent] }
        return try await (send("GET", "/trips/\(tripId.pathEscaped)/activity") as Answer).events
    }

    // MARK: Shared purse

    private struct LedgerAnswer: Decodable { var ledger: Ledger }

    public func ledger(tripId: String) async throws -> Ledger {
        try await send("GET", "/trips/\(tripId.pathEscaped)/ledger")
    }

    public func suggestParties(tripId: String) async throws -> Ledger {
        try await (send("POST", "/trips/\(tripId.pathEscaped)/parties/suggest") as LedgerAnswer).ledger
    }

    public func setParties(tripId: String, parties: [PartyDraft]) async throws -> Ledger {
        struct Body: Encodable { var parties: [PartyDraft] }
        return try await (send("PUT", "/trips/\(tripId.pathEscaped)/parties", body: Body(parties: parties)) as LedgerAnswer).ledger
    }

    public func addExpense(tripId: String, expense: ExpenseDraft) async throws -> Ledger {
        try await (send("POST", "/trips/\(tripId.pathEscaped)/expenses", body: expense) as LedgerAnswer).ledger
    }

    public func updateExpense(expenseId: String, expense: ExpenseDraft) async throws -> Ledger {
        try await (send("PATCH", "/expenses/\(expenseId.pathEscaped)", body: expense) as LedgerAnswer).ledger
    }

    public func deleteExpense(expenseId: String) async throws -> Ledger {
        try await (send("DELETE", "/expenses/\(expenseId.pathEscaped)") as LedgerAnswer).ledger
    }

    public func addPayment(tripId: String, from: String, to: String, amountCents: Int) async throws -> Ledger {
        struct Body: Encodable { var fromParty: String; var toParty: String; var amountCents: Int }
        return try await (send("POST", "/trips/\(tripId.pathEscaped)/payments", body: Body(fromParty: from, toParty: to, amountCents: amountCents)) as LedgerAnswer).ledger
    }

    public func deletePayment(tripId: String, paymentId: String) async throws -> Ledger {
        try await (send("DELETE", "/trips/\(tripId.pathEscaped)/payments/\(paymentId.pathEscaped)") as LedgerAnswer).ledger
    }

    public func setSplit(tripId: String, splitMode: String, childWeight: Double) async throws {
        struct Body: Encodable { var splitMode: String; var childWeight: Double }
        _ = try await data("PATCH", "/trips/\(tripId.pathEscaped)", body: Body(splitMode: splitMode, childWeight: childWeight))
    }

    public func criteria(tripId: String) async throws -> CriteriaList {
        try await send("GET", "/trips/\(tripId.pathEscaped)/criteria")
    }

    public func setCriteria(tripId: String, criteria: [Criterion]) async throws -> CriteriaList {
        struct Entry: Encodable { var id: String?; var key: String; var label: String?; var level: String; var target: Double? }
        struct Body: Encodable { var criteria: [Entry] }
        let entries = criteria.map { Entry(id: $0.id.isEmpty ? nil : $0.id, key: $0.key, label: $0.label, level: $0.level, target: $0.target) }
        return try await send("PUT", "/trips/\(tripId.pathEscaped)/criteria", body: Body(criteria: entries))
    }

    public func setCriteriaChecks(candidateId: String, checks: [String: String]) async throws {
        struct Body: Encodable { var criteriaChecks: [String: String] }
        _ = try await data("PATCH", "/candidates/\(candidateId.pathEscaped)", body: Body(criteriaChecks: checks))
    }

    public func candidate(_ id: String) async throws -> CandidateDetail {
        try await send("GET", "/candidates/\(id.pathEscaped)")
    }

    public func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult {
        struct Body: Encodable { var url: String; var html: String? }
        let page = html.flatMap { $0.utf8.count <= Self.maxPageBytes ? $0 : nil }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/imports", body: Body(url: url, html: page))
    }

    public func checkTrip(tripId: String, dateOptionId: String?) async throws -> TripCheck {
        struct Body: Encodable { var dateOptionId: String? }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/refresh", body: dateOptionId.map { Body(dateOptionId: $0) })
    }

    public func capture(candidateId: String, html: String, sourceId: String?, forTrip: Bool, url: String?, dateOptionId: String?) async throws {
        struct Body: Encodable { var html: String; var sourceId: String?; var forTrip: Bool?; var url: String?; var dateOptionId: String? }
        guard html.utf8.count <= Self.maxPageBytes else {
            throw APIError(status: 0, code: "too_large", message: "Die Seite ist zu groß, um sie zu übertragen.")
        }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/capture", body: Body(html: html, sourceId: sourceId, forTrip: forTrip ? true : nil, url: url, dateOptionId: forTrip ? dateOptionId : nil))
    }

    public func searchOtherPlatforms(candidateId: String) async throws {
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/sources/search")
    }

    public func decide(candidateId: String, suggestionId: String, accept: Bool) async throws {
        struct Body: Encodable { var decision: String }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/suggestions/\(suggestionId.pathEscaped)",
                           body: Body(decision: accept ? "accept" : "reject"))
    }

    public func addSource(candidateId: String, url: String) async throws {
        struct Body: Encodable { var url: String }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/sources", body: Body(url: url))
    }

    public func removeSource(candidateId: String, sourceId: String) async throws {
        _ = try await data("DELETE", "/candidates/\(candidateId.pathEscaped)/sources/\(sourceId.pathEscaped)")
    }

    public func refresh(candidateId: String) async throws {
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/refresh")
    }

    public func setHiddenWarnings(candidateId: String, hidden: [String]) async throws {
        struct Body: Encodable { var hiddenWarnings: [String] }
        _ = try await data("PATCH", "/candidates/\(candidateId.pathEscaped)", body: Body(hiddenWarnings: hidden))
    }

    public func move(candidateId: String, toTrip tripId: String) async throws -> String {
        struct Body: Encodable { var tripId: String }
        struct Response: Decodable { var candidateId: String? }
        let response: Response = try await send("POST", "/candidates/\(candidateId.pathEscaped)/move", body: Body(tripId: tripId))
        return response.candidateId ?? candidateId
    }

    public func delete(candidateId: String) async throws {
        _ = try await data("DELETE", "/candidates/\(candidateId.pathEscaped)")
    }

    public func setStatus(candidateId: String, status: CandidateStatus) async throws {
        struct Body: Encodable { var status: CandidateStatus }
        _ = try await data("PATCH", "/candidates/\(candidateId.pathEscaped)", body: Body(status: status))
    }

    public func vote(candidateId: String, verdict: Verdict, veto: Bool) async throws {
        struct Body: Encodable { var verdict: Verdict; var veto: Bool }
        _ = try await data("PUT", "/candidates/\(candidateId.pathEscaped)/vote", body: Body(verdict: verdict, veto: veto))
    }

    public func comment(candidateId: String, body: String) async throws {
        struct Body: Encodable { var body: String }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/comments", body: Body(body: body))
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }

    var pathEscaped: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

public extension TravelBackend {
    func capture(candidateId: String, html: String, sourceId: String?) async throws {
        try await capture(candidateId: candidateId, html: html, sourceId: sourceId, forTrip: false, url: nil, dateOptionId: nil)
    }

    func capture(candidateId: String, html: String, sourceId: String?, forTrip: Bool, url: String?) async throws {
        try await capture(candidateId: candidateId, html: html, sourceId: sourceId, forTrip: forTrip, url: url, dateOptionId: nil)
    }

    func candidates(tripId: String) async throws -> [CandidateSummary] {
        try await candidates(tripId: tripId, dateOptionId: nil)
    }

    func checkTrip(tripId: String) async throws -> TripCheck {
        try await checkTrip(tripId: tripId, dateOptionId: nil)
    }
}
