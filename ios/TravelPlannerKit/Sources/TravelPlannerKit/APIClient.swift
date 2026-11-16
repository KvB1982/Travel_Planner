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
    /// Changes the frame of the trip: title, region, party and budget. Organiser only.
    func updateTrip(tripId: String, changes: TripChanges) async throws -> Trip
    func addDateOption(tripId: String, label: String?, startDate: String, endDate: String) async throws -> DateOption
    func removeDateOption(tripId: String, optionId: String) async throws
    /// The chronicle: the last hundred events of the trip, newest first.
    func activity(tripId: String) async throws -> [ActivityEvent]
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
        let request = try request(method, path, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError(status: 0, code: "offline", message: "Der Server ist nicht erreichbar. (\(error.localizedDescription))")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let body = try? Self.decoder.decode(ErrorBody.self, from: data) {
                throw APIError(status: status, code: body.error.code, message: body.error.message)
            }
            throw APIError(status: status, code: "http_\(status)", message: "Der Server hat mit Status \(status) geantwortet.")
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
