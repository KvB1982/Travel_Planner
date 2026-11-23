import SwiftUI
import TravelPlannerKit

struct NewTripView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The own groups, to choose where the trip belongs.
    var groups: [TravelGroup] = []
    /// A group's id, or "private"; empty lets the form decide.
    var preselected = ""
    /// The trips there are already, so no second one gets the same name.
    var existing: [Trip] = []
    var onCreated: (Trip) -> Void

    @State private var title = ""
    @State private var region = ""
    @State private var adults = 2
    @State private var children = 0
    @State private var pets = 0
    @State private var hasDates = true
    @State private var start = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var nights = 14
    @State private var budget = ""
    @State private var home = ""

    /// Names are unique within a group, and among the private trips.
    private var nameTaken: Bool {
        Trip.nameTaken(title, inGroup: groups.isEmpty || home == "private" ? nil : home, among: existing)
    }
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, zum Beispiel „Sommerurlaub 2027“", text: $title)
                    TextField("Region (optional)", text: $region)
                    if nameTaken {
                        Label(home == "private" || groups.isEmpty ? "Eine private Reise mit diesem Namen gibt es schon. Bitte wähle einen anderen." : "In dieser Gruppe gibt es schon eine Reise mit diesem Namen. Bitte wähle einen anderen.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                if !groups.isEmpty {
                    Section {
                        Picker("Gehört zu", selection: $home) {
                            ForEach(groups) { Text($0.name).tag($0.id) }
                            Text("Privat, nur für mich").tag("private")
                        }
                    } footer: {
                        Text(home == "private" ? "Nur du siehst die Reise, bis du jemanden einlädst."
                                               : "Alle Mitglieder der Gruppe sehen die Reise und können mitmachen.")
                    }
                }
                Section("Wer fährt mit?") {
                    Stepper("Erwachsene: \(adults)", value: $adults, in: 1...40)
                    Stepper("Kinder: \(children)", value: $children, in: 0...40)
                    Stepper("Haustiere: \(pets)", value: $pets, in: 0...10)
                }
                Section {
                    Toggle("Zeitraum steht schon fest", isOn: $hasDates)
                    if hasDates {
                        DatePicker("Anreise", selection: $start, displayedComponents: .date)
                        Stepper("Nächte: \(nights)", value: $nights, in: 1...60)
                    }
                } footer: {
                    Text("Preise werden für diesen Zeitraum und diese Personenzahl abgefragt. Weitere Zeiträume kannst du später ergänzen.")
                }
                Section("Budget gesamt (optional)") {
                    TextField("Euro", text: $budget).keyboardType(.numberPad)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .navigationTitle("Neue Reise")
            .onAppear {
                guard home.isEmpty else { return }
                home = groups.contains { $0.id == preselected } || preselected == "private" ? preselected : (groups.first?.id ?? "private")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") { create() }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || nameTaken)
                }
            }
        }
    }

    private func create() {
        guard let backend = model.backend else { return }
        var dates: [NewTrip.Dates] = []
        if hasDates, let end = Calendar.current.date(byAdding: .day, value: nights, to: start) {
            dates = [.init(startDate: Format.isoDay(start), endDate: Format.isoDay(end))]
        }
        let euros = Int(budget.filter(\.isNumber))
        var trip = NewTrip(title: title.trimmingCharacters(in: .whitespaces), region: region.isEmpty ? nil : region, adults: adults,
                           children: children, pets: pets, budgetTotalCents: euros.map { $0 * 100 }, dateOptions: dates)
        // Group or private goes with the request itself: a trip made private afterwards would keep the group's members.
        if !groups.isEmpty { trip.home = home == "private" ? .personal : .group(home) }
        busy = true
        Task {
            do {
                let created = try await backend.createTrip(trip)
                onCreated(created)
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}
