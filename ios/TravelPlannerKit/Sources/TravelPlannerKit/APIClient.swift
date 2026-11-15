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
    func candidates(tripId: String) async throws -> [CandidateSummary]
    func candidate(_ id: String) async throws -> CandidateDetail
    func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult
    func capture(candidateId: String, html: String) async throws
    func setStatus(candidateId: String, status: CandidateStatus) async throws
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

    public func candidates(tripId: String) async throws -> [CandidateSummary] {
        struct Response: Decodable { var candidates: [CandidateSummary] }
        return try await (send("GET", "/trips/\(tripId.pathEscaped)/candidates") as Response).candidates
    }

    public func candidate(_ id: String) async throws -> CandidateDetail {
        try await send("GET", "/candidates/\(id.pathEscaped)")
    }

    public func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult {
        struct Body: Encodable { var url: String; var html: String? }
        let page = html.flatMap { $0.utf8.count <= Self.maxPageBytes ? $0 : nil }
        return try await send("POST", "/trips/\(tripId.pathEscaped)/imports", body: Body(url: url, html: page))
    }

    public func capture(candidateId: String, html: String) async throws {
        struct Body: Encodable { var html: String }
        guard html.utf8.count <= Self.maxPageBytes else {
            throw APIError(status: 0, code: "too_large", message: "Die Seite ist zu groß, um sie zu übertragen.")
        }
        _ = try await data("POST", "/candidates/\(candidateId.pathEscaped)/capture", body: Body(html: html))
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
