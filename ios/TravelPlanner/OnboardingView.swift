import SwiftUI
import TravelPlannerKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var invite = ""
    @State private var name = ""
    @State private var server = ""
    @State private var secret = ""
    @State private var appleServer = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Dein Name", text: $name)
                        .textContentType(.givenName)
                } footer: {
                    Text("So sehen dich die anderen bei Stimmen und Kommentaren.")
                }

                Section {
                    TextField("https://…/einladung/…", text: $invite, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Beitreten") {
                        run { try await model.join(inviteText: invite, name: trimmedName) }
                    }
                    .disabled(busy || trimmedName.isEmpty || invite.isEmpty)
                } header: {
                    Text("Mit Einladung beitreten")
                } footer: {
                    Text("Den Link bekommst du von der Person, die die Reise organisiert.")
                }

                Section {
                    TextField("Serveradresse", text: $appleServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    AppleButton { token, nonce in
                        run { try await model.signInWithApple(server: appleServer, identityToken: token, nonce: nonce) }
                    } failed: { error = $0 }
                    .disabled(busy || appleServer.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(appleServer.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                } header: {
                    Text("Schon ein Konto?")
                } footer: {
                    Text("Wenn du deine Apple-ID auf einem anderen Gerät in den Einstellungen verknüpft hast, öffnet sie hier dasselbe Konto. Ein neues Konto entsteht so nicht.")
                }

                Section {
                    DisclosureGroup("Neuen Server einrichten") {
                        TextField("Serveradresse", text: $server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Einrichtungsschlüssel", text: $secret)
                        Button("Erstes Konto anlegen") {
                            run { try await model.bootstrap(server: server, secret: secret, name: trimmedName) }
                        }
                        .disabled(busy || trimmedName.isEmpty || server.isEmpty || secret.isEmpty)
                    }
                } footer: {
                    Text("Nur einmal nötig, für das allererste Konto. Der Schlüssel steht in der Konfiguration des Servers.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Erst einmal mit Beispieldaten ansehen") { model.startDemo() }
                }
            }
            .navigationTitle("Travel Planner")
            .onAppear { if appleServer.isEmpty, let known = model.serverURL { appleServer = known.absoluteString } }
            .overlay {
                if busy { ProgressView().controlSize(.large) }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
