import SwiftUI
import TravelPlannerKit

struct NewTripView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The own groups, to choose where the trip belongs.
    var groups: [TravelGroup] = []
    /// A group's id, or "private"; empty lets the form decide.
    var preselected = ""
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
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, zum Beispiel „Sommerurlaub 2027“", text: $title)
                    TextField("Region (optional)", text: $region)
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
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
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
        let trip = NewTrip(title: title.trimmingCharacters(in: .whitespaces), region: region.isEmpty ? nil : region, adults: adults,
                           children: children, pets: pets, budgetTotalCents: euros.map { $0 * 100 }, dateOptions: dates)
        busy = true
        Task {
            do {
                var created = try await backend.createTrip(trip)
                // The server puts a new trip into the group when there is exactly one; anything else is set here.
                let wanted = groups.isEmpty ? created.groupId : (home == "private" ? nil : home)
                if wanted != created.groupId {
                    try await backend.setTripGroup(tripId: created.id, groupId: wanted)
                    created.groupId = wanted
                }
                onCreated(created)
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}
