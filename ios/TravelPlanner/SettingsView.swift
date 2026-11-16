import SwiftUI
import TravelPlannerKit

/// Names of the settings kept on the device.
enum Settings {
    /// Shows every advert while offers are checked, instead of reading them out of sight.
    static let showCheckRun = "showCheckRun"
    /// Opens the hints of an offer by default.
    static let showWarnings = "showWarnings"
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.showCheckRun) private var showCheckRun = false
    @AppStorage(Settings.showWarnings) private var showWarnings = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Prüflauf anzeigen", isOn: $showCheckRun)
                } header: {
                    Text("Verfügbarkeit und Preise")
                } footer: {
                    Text(showCheckRun
                         ? "Beim Prüfen öffnet die App jedes Inserat sichtbar und liest es vor deinen Augen. Gut, um nachzuvollziehen, was passiert."
                         : "Beim Prüfen liest die App die Inserate unsichtbar im Hintergrund, du kannst währenddessen weiterarbeiten. Nur wenn eine Seite eine Sicherheitsabfrage zeigt, blendet sie sich ein. Der Lauf braucht die geöffnete App.")
                }

                Section {
                    Toggle("Hinweise aufgeklappt zeigen", isOn: $showWarnings)
                } header: {
                    Text("Steckbrief")
                }

                Section("Konto") {
                    if model.isDemo {
                        LabeledContent("Modus", value: "Beispieldaten")
                    } else {
                        if let user = model.user { LabeledContent("Angemeldet als", value: user.name) }
                        if let host = model.serverURL?.host() { LabeledContent("Server", value: host) }
                    }
                    Button(model.isDemo ? "Beispieldaten verlassen" : "Abmelden", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmSignOut = true
                    }
                }

                Section("App") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .alert(model.isDemo ? "Beispieldaten verlassen?" : "Wirklich abmelden?", isPresented: $confirmSignOut) {
                Button("Abbrechen", role: .cancel) {}
                Button(model.isDemo ? "Verlassen" : "Abmelden", role: .destructive) {
                    dismiss()
                    Task { await model.signOut() }
                }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
