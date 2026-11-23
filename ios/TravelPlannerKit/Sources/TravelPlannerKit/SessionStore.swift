import Foundation
import Security

/// Where the app and the share extension keep the server address and the sign-in token.
/// Both live in the shared app group so the extension can import links without its own sign-in.
public struct SessionStore: Sendable {
    public static let appGroup = "group.com.von-bleichert.travelplanner"

    private let group: String?
    private let service = "com.von-bleichert.travelplanner.session"
    private let account = "token"
    private let urlKey = "serverURL"
    private let demoKey = "demoMode"

    public init(group: String? = SessionStore.appGroup) {
        self.group = group
    }

    private var defaults: UserDefaults {
        group.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public var serverURL: URL? {
        get { defaults.string(forKey: urlKey).flatMap(URL.init(string:)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: urlKey) }
    }

    public var demoMode: Bool {
        get { defaults.bool(forKey: demoKey) }
        nonmutating set { defaults.set(newValue, forKey: demoKey) }
    }

    /// A ready client when both address and token are stored.
    public var client: APIClient? {
        guard let serverURL, let token else { return nil }
        return APIClient(baseURL: serverURL, token: token)
    }

    public func clear() {
        token = nil
        demoMode = false
    }

    // MARK: Keychain

    private func query(shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    public var token: String? {
        get {
            // Without the app-group entitlement (unsigned test builds) the shared item does not exist; fall back to the private one.
            for shared in [true, false] {
                var query = query(shared: shared)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
                    return String(data: data, encoding: .utf8)
                }
            }
            return nil
        }
        nonmutating set {
            for shared in [true, false] { SecItemDelete(query(shared: shared) as CFDictionary) }
            guard let newValue else { return }
            for shared in [true, false] {
                var item = query(shared: shared)
                item[kSecValueData as String] = Data(newValue.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
            }
        }
    }
}

/// An invite link as shown by the organizer: `https://server/einladung/<token>`.
public struct InviteLink: Equatable, Sendable {
    public var serverURL: URL
    public var token: String

    public static let appScheme = "reiseplaner"

    /// The link in the form the organizer shares it, whatever form it arrived in.
    public var webAddress: String {
        serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/einladung/" + token
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The app's own form, used by the button on the invitation's web page:
        // `reiseplaner://einladung/<token>?server=https://server`.
        if let own = URLComponents(string: trimmed), own.scheme == Self.appScheme {
            guard own.host == "einladung", let token = own.path.split(separator: "/").first.map(String.init), !token.isEmpty,
                  let address = own.queryItems?.first(where: { $0.name == "server" })?.value,
                  let server = URL(string: address), server.scheme == "https" || server.scheme == "http", server.host() != nil else { return nil }
            self.serverURL = server
            self.token = token
            return
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme, let host = components.host,
              scheme == "https" || scheme == "http" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "einladung"), parts.count > index + 1, !parts[index + 1].isEmpty else { return nil }
        var server = URLComponents()
        server.scheme = scheme
        server.host = host
        server.port = components.port
        // Anything in front of /einladung is the path the API is mounted under.
        if index > 0 { server.path = "/" + parts[..<index].joined(separator: "/") }
        guard let url = server.url else { return nil }
        self.serverURL = url
        self.token = parts[index + 1]
    }
}

public enum LinkFinder {
    /// Whether an address leads to a sign-in page instead of an advert, such as `accounts.check24.com/login`.
    /// Portals send there when a link needs an account; importing it would only store the sign-in form.
    public static func isSignInPage(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased()
        let first = host.split(separator: ".").first.map(String.init) ?? ""
        if ["accounts", "account", "login", "signin", "auth", "sso", "id", "anmelden"].contains(first) { return true }
        let parts = url.path().lowercased().split(separator: "/").map(String.init)
        return parts.contains { ["login", "signin", "sign-in", "anmelden", "anmeldung", "oauth", "authorize"].contains($0) }
    }


    /// The first web address in shared text; apps such as Airbnb share "Schau dir das an: https://…".
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, url.scheme == "https" || url.scheme == "http" { return url }
        }
        return nil
    }
}

/// Until the app is used with more than one server, the address of the family's server is built in,
/// so nobody has to type it when signing in.
public enum ServerDefaults {
    public static let url = URL(string: "https://reisen.tail39c0d8.ts.net")!
}
