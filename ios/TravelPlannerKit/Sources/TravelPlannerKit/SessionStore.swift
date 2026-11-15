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

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
