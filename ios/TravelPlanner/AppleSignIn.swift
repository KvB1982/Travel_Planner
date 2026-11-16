import SwiftUI
import AuthenticationServices
import CryptoKit

/// The system button for an Apple ID. Hands on the identity token and the nonce it was requested with.
struct AppleButton: View {
    var label: SignInWithAppleButton.Label = .signIn
    /// Token and the unhashed nonce; the server compares its hash with the one inside the token.
    let done: (_ identityToken: String, _ nonce: String) -> Void
    let failed: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var nonce = ""

    var body: some View {
        SignInWithAppleButton(label) { request in
            // Neither name nor mail is asked for: the account exists already and has its name.
            request.requestedScopes = []
            nonce = Self.randomNonce()
            request.nonce = Self.sha256(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                    failed("Apple hat keine Anmeldung zurückgegeben.")
                    return
                }
                done(token, nonce)
            case .failure(let error):
                // Closing the sheet is no error worth a message.
                if (error as? ASAuthorizationError)?.code == .canceled { return }
                failed("Die Anmeldung mit Apple hat nicht geklappt. (\(error.localizedDescription))")
            }
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .frame(height: 46)
    }

    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
