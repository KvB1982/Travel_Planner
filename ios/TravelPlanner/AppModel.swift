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
        #if DEBUG
        // For trying the on-device reading against a real advert without typing in the simulator:
        // launch with `-demoLink <address>` while the sample data is active.
        if isDemo, let link = UserDefaults.standard.string(forKey: "demoLink"), let backend {
            Task {
                _ = try? await backend.importLink(tripId: "t-1", url: link, html: nil)
                dataChanged()
            }
        }
        #endif
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

    /// Redeems an invite to a trip or a group while signed in: the whole link or only its last part.
    /// Tells where it led: a trip to open, or a group joined.
    func redeem(inviteText: String) async throws -> (tripID: String?, joinedGroup: Bool) {
        let text = inviteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw APIError(status: 0, code: "bad_invite", message: "Füge den Einladungslink ein, den du bekommen hast.")
        }
        guard let client = backend as? APIClient else {
            throw APIError(status: 0, code: "demo", message: "Mit den Beispieldaten lässt sich keine Einladung einlösen.")
        }
        if let link = InviteLink(text), link.serverURL.host() != client.baseURL.host() {
            throw APIError(status: 0, code: "other_server", message: "Diese Einladung gehört zu einem anderen Server (\(link.serverURL.host() ?? "?")). Du bist bei \(client.baseURL.host() ?? "?") angemeldet.")
        }
        let result: AuthResult
        do {
            result = try await client.redeemInvite(link: text)
        } catch let error as APIError where error.status == 404 && error.code != "invite_invalid" {
            // A server from before the groups: it only knows the older way.
            guard let link = InviteLink(text) else { throw error }
            result = try await client.acceptInvite(token: link.token, name: nil, deviceName: nil)
        }
        dataChanged()
        return (result.tripId, result.groupId != nil)
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

    /// Opens the account this Apple ID is linked to. The server is the one used last, else the built-in one.
    func signInWithApple(identityToken: String, nonce: String) async throws {
        let url = store.serverURL ?? ServerDefaults.url
        do {
            let result = try await APIClient(baseURL: url).signInWithApple(identityToken: identityToken, nonce: nonce, deviceName: UIDevice.current.name)
            try signIn(server: url, result: result)
        } catch let error as APIError where error.code == "apple_not_linked" {
            throw APIError(status: error.status, code: error.code,
                           message: "Diese Apple-ID gehört noch zu keinem Konto. Tritt zuerst mit einer Einladung bei und verknüpfe die Apple-ID dann in den Einstellungen.")
        }
    }

    /// Links the Apple ID to the account signed in here, so other devices can open it without an invite.
    func linkApple(identityToken: String, nonce: String) async throws {
        guard let client = backend as? APIClient else {
            throw APIError(status: 0, code: "demo", message: "Mit den Beispieldaten lässt sich keine Apple-ID verknüpfen.")
        }
        user = try await client.linkApple(identityToken: identityToken, nonce: nonce)
    }

    /// Changes the own name, as the others see it.
    func rename(_ name: String) async throws {
        guard let backend else { return }
        user = try await backend.rename(name: name)
        dataChanged()
    }

    func unlinkApple() async throws {
        guard let client = backend as? APIClient else { return }
        try await client.unlinkApple()
        user = try await client.me()
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
