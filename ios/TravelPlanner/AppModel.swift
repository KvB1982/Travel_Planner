import SwiftUI
import TravelPlannerKit

/// Sign-in state and the connection every view talks to.
@MainActor
@Observable
final class AppModel {
    private let store = SessionStore()

    private(set) var backend: (any TravelBackend)?
    private(set) var isDemo = false
    private(set) var user: User?
    /// Counts up whenever something changed that lists should pick up.
    private(set) var revision = 0

    var serverURL: URL? { store.serverURL }

    init() {
        if store.demoMode {
            backend = DemoBackend()
            isDemo = true
        } else if let client = store.client {
            backend = client
        }
        Task { await loadUser() }
    }

    func dataChanged() { revision += 1 }

    private func loadUser() async {
        user = try? await backend?.me()
    }

    func startDemo() {
        store.token = nil
        store.demoMode = true
        isDemo = true
        backend = DemoBackend()
        Task { await loadUser() }
    }

    /// Joins with an invite link such as `https://server/einladung/<token>`.
    func join(inviteText: String, name: String) async throws {
        guard let link = InviteLink(inviteText) else {
            throw APIError(status: 0, code: "bad_invite", message: "Das ist kein Einladungslink. Er sieht so aus: https://…/einladung/…")
        }
        let client = APIClient(baseURL: link.serverURL)
        let result = try await client.acceptInvite(token: link.token, name: name, deviceName: UIDevice.current.name)
        try signIn(server: link.serverURL, result: result)
    }

    /// Creates the very first account on a fresh server.
    func bootstrap(server: String, secret: String, name: String) async throws {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else {
            throw APIError(status: 0, code: "bad_url", message: "Die Serveradresse ist ungültig.")
        }
        let result = try await APIClient(baseURL: url).bootstrap(secret: secret, name: name, deviceName: UIDevice.current.name)
        try signIn(server: url, result: result)
    }

    private func signIn(server: URL, result: AuthResult) throws {
        guard let token = result.token else {
            throw APIError(status: 0, code: "no_token", message: "Der Server hat keine Anmeldung zurückgegeben.")
        }
        store.demoMode = false
        store.serverURL = server
        store.token = token
        isDemo = false
        user = result.user
        backend = APIClient(baseURL: server, token: token)
    }

    func signOut() async {
        if !isDemo { try? await backend?.logout() }
        store.clear()
        backend = nil
        isDemo = false
        user = nil
    }

    /// Text for an error banner. A rejected token ends the session, because nothing else will work either.
    func message(for error: Error) -> String {
        if let api = error as? APIError, api.isUnauthorized {
            store.clear()
            backend = nil
            user = nil
            return "Deine Anmeldung ist abgelaufen."
        }
        return error.localizedDescription
    }
}
