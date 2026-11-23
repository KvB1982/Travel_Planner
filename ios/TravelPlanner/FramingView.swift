import SwiftUI
import TravelPlannerKit

/// Phase 0 of a trip: who travels when, where to, and what it may cost. Also the place for members and the chronicle.
struct FramingSections: View {
    @Environment(AppModel.self) private var model
    let detail: TripDetail
    let showCriteria: () -> Void
    let invite: () -> Void
    let showLedger: () -> Void

    /// Sheets and alerts live on the screen, not on the rows: attached to rows they open unreliably.
    @Binding var sheet: FramingSheet?
    @Binding var removing: DateOption?
    @State private var events: [ActivityEvent] = []
    @State private var allEvents = false

    private var trip: Trip { detail.trip }
    private var german: Locale { Locale(identifier: "de_DE") }

    var body: some View {
        Group {
            Section {
                LabeledContent("Titel", value: trip.title)
                LabeledContent("Region", value: trip.region ?? "noch offen")
                LabeledContent("Wer fährt mit", value: party)
                LabeledContent("Budget gesamt", value: trip.budgetTotalCents.map { Format.euro(cents: $0) } ?? "nicht festgelegt")
                if let window = trip.flexWindow {
                    LabeledContent("Flexibel", value: window.summary)
                }
                if detail.role == .organizer {
                    Button("Rahmen bearbeiten", systemImage: "pencil") { sheet = .edit }
                }
            } header: {
                Text("Rahmen")
            }
            Section {
                if detail.dateOptions.isEmpty {
                    Text("Noch kein Zeitraum. Ohne Zeitraum lassen sich Preise und Verfügbarkeit nicht prüfen.").foregroundStyle(.secondary)
                }
                ForEach(detail.dateOptions) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label ?? "Zeitraum")
                        Text([Format.dateRange(option.startDate, option.endDate), nights(option)].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if detail.role.canEdit {
                            Button("Entfernen", systemImage: "trash") { removing = option }.tint(.red)
                        }
                    }
                }
                if detail.role.canEdit {
                    Button("Zeitraum hinzufügen", systemImage: "calendar.badge.plus") { sheet = .period }
                }
            } header: {
                Text("Zeiträume")
            }
            Section {
                ForEach(detail.members) { member in
                    LabeledContent(member.name, value: member.role.label)
                }
                if detail.role == .organizer {
                    Button("Jemanden einladen", systemImage: "person.badge.plus", action: invite)
                }
            } header: {
                Text("Wer ist dabei")
            }
            Section {
                if detail.role.canEdit {
                    Button("Muss- und Wunsch-Kriterien", systemImage: "checklist", action: showCriteria)
                }
                Button("Gemeinsame Kasse", systemImage: "eurosign.circle", action: showLedger)
            } header: {
                Text("Dazu gehört")
            }
            if !events.isEmpty {
                Section {
                    ForEach(allEvents ? events : Array(events.prefix(5))) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.userName ?? "Jemand") \(event.sentence)")
                            if let date = event.createdAt {
                                Text(date.formatted(.relative(presentation: .named).locale(german))).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if events.count > 5 && !allEvents {
                        Button("Alle \(events.count) Einträge zeigen") { allEvents = true }
                    }
                } header: {
                    Text("Chronik")
                }
            }
        }
        .task(id: model.revision) {
            // The chronicle is an extra: when it cannot be read, the frame still shows.
            if let list = try? await model.backend?.activity(tripId: trip.id) { events = list }
        }
    }

    private var party: String {
        var parts = [trip.adults == 1 ? "1 Erwachsener" : "\(trip.adults) Erwachsene"]
        if trip.children > 0 { parts.append(trip.children == 1 ? "1 Kind" : "\(trip.children) Kinder") }
        if trip.pets > 0 { parts.append(trip.pets == 1 ? "1 Haustier" : "\(trip.pets) Haustiere") }
        return parts.joined(separator: ", ")
    }

    private func nights(_ option: DateOption) -> String? {
        guard let start = Format.day(option.startDate), let end = Format.day(option.endDate),
              let count = Calendar.current.dateComponents([.day], from: start, to: end).day, count > 0 else { return nil }
        return count == 1 ? "1 Nacht" : "\(count) Nächte"
    }
}

enum FramingSheet: String, Identifiable {
    case edit, period
    var id: String { rawValue }
}

/// Title, region, party and budget of a trip.
struct TripEditor: View {
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let save: (TripChanges) -> Void

    @State private var title = ""
    @State private var region = ""
    @State private var adults = 2
    @State private var children = 0
    @State private var pets = 0
    @State private var budget = ""
    @State private var flexible = false
    @State private var flexStart = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var flexEnd = Calendar.current.date(byAdding: .day, value: 196, to: .now) ?? .now
    @State private var nightsMin = 7
    @State private var nightsMax = 14
    @State private var filled = false

    private var window: FlexWindow {
        FlexWindow(start: Format.isoDay(flexStart), end: Format.isoDay(flexEnd), nightsMin: nightsMin, nightsMax: max(nightsMin, nightsMax))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $title)
                    TextField("Region (freiwillig)", text: $region)
                }
                Section {
                    Stepper("Erwachsene: \(adults)", value: $adults, in: 1...40)
                    Stepper("Kinder: \(children)", value: $children, in: 0...40)
                    Stepper("Haustiere: \(pets)", value: $pets, in: 0...10)
                } header: {
                    Text("Wer fährt mit?")
                } footer: {
                    Text("Preise und Verfügbarkeit werden für diese Personenzahl geprüft. Nach einer Änderung lohnt sich ein neuer Prüflauf.")
                }
                Section("Budget gesamt (freiwillig)") {
                    TextField("Euro", text: $budget).keyboardType(.numberPad)
                }
                Section {
                    Toggle("Flexibler Zeitraum", isOn: $flexible)
                    if flexible {
                        DatePicker("Frühestens anreisen", selection: $flexStart, displayedComponents: .date)
                        DatePicker("Spätestens abreisen", selection: $flexEnd, in: flexStart..., displayedComponents: .date)
                        Stepper("Mindestens \(nightsMin) \(nightsMin == 1 ? "Nacht" : "Nächte")", value: $nightsMin, in: 1...60)
                        Stepper("Höchstens \(nightsMax) \(nightsMax == 1 ? "Nacht" : "Nächte")", value: $nightsMax, in: nightsMin...60)
                    }
                } footer: {
                    Text(!flexible ? "Für Reisen, deren genaue Daten vom Angebot abhängen: Statt eines festen Zeitraums gibst du ein Fenster und eine Dauer an."
                         : window.isValid ? "Jeder Aufenthalt in diesem Fenster zählt als Preis der Reise, auch die Daten aus einem geteilten Link. Verglichen wird der Preis je Nacht."
                         : "Das Fenster ist kürzer als der kürzeste Aufenthalt.")
                        .foregroundStyle(flexible && !window.isValid ? Color.red : Color.secondary)
                }
            }
            .navigationTitle("Rahmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let place = region.trimmingCharacters(in: .whitespaces)
                        var changes = TripChanges(title: title.trimmingCharacters(in: .whitespaces), region: place.isEmpty ? nil : place, adults: adults,
                                                  children: children, pets: pets, budgetTotalCents: Int(budget.filter(\.isNumber)).map { $0 * 100 })
                        // The window is only touched when it changed, so servers and trips without one stay as they are.
                        let wanted = flexible ? window : nil
                        if wanted != trip.flexWindow { changes.flex = wanted; changes.sendsFlex = true }
                        save(changes)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || (flexible && !window.isValid))
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                title = trip.title; region = trip.region ?? ""; adults = max(1, trip.adults); children = trip.children; pets = trip.pets
                budget = trip.budgetTotalCents.map { String($0 / 100) } ?? ""
                if let known = trip.flexWindow {
                    flexible = true
                    flexStart = Format.day(known.start) ?? flexStart; flexEnd = Format.day(known.end) ?? flexEnd
                    nightsMin = known.nightsMin; nightsMax = known.nightsMax
                }
            }
            .onChange(of: nightsMin) { if nightsMax < nightsMin { nightsMax = nightsMin } }
        }
    }
}

/// A further period the trip could take place in.
struct PeriodEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String?, String, String) -> Void

    @State private var label = ""
    @State private var start = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var nights = 14

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, zum Beispiel „Zweite Ferienhälfte“ (freiwillig)", text: $label)
                DatePicker("Anreise", selection: $start, displayedComponents: .date)
                Stepper("Nächte: \(nights)", value: $nights, in: 1...60)
            }
            .navigationTitle("Neuer Zeitraum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        guard let end = Calendar.current.date(byAdding: .day, value: nights, to: start) else { return }
                        let name = label.trimmingCharacters(in: .whitespaces)
                        save(name.isEmpty ? nil : name, Format.isoDay(start), Format.isoDay(end))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The sheets and the alert of the frame, attached to the whole screen.
struct FramingPresenter: ViewModifier {
    let tripID: String
    let trip: Trip?
    @Binding var sheet: FramingSheet?
    @Binding var removing: DateOption?
    let run: (@escaping (any TravelBackend) async throws -> Void) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .edit:
                    if let trip {
                        TripEditor(trip: trip) { changes in run { _ = try await $0.updateTrip(tripId: tripID, changes: changes) } }
                    }
                case .period:
                    PeriodEditor { label, start, end in
                        run { _ = try await $0.addDateOption(tripId: tripID, label: label, startDate: start, endDate: end) }
                    }
                }
            }
            .alert("Zeitraum entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { option in
                Button("Entfernen", role: .destructive) { run { try await $0.removeDateOption(tripId: tripID, optionId: option.id) } }
                Button("Abbrechen", role: .cancel) {}
            } message: { option in
                Text("„\(option.label ?? Format.dateRange(option.startDate, option.endDate) ?? "Zeitraum")“ wird entfernt. Die dafür erfassten Preise zählen dann nicht mehr für die Reise.")
            }
    }
}
