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
    /// A change of where the trip belongs, waiting to be confirmed on the screen.
    @Binding var rehoming: TripHome?
    @State private var events: [ActivityEvent] = []
    @State private var groups: [TravelGroup] = []
    /// Invite links to the trip that can still be used. Only organisers get to see them.
    @State private var openInvites: [GroupInvite] = []
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
                if detail.role == .organizer, !groups.isEmpty {
                    // Where the trip belongs; changing it asks first, because people lose or gain access.
                    Menu {
                        ForEach(groups.filter { $0.id != trip.groupId }) { group in
                            Button("In „\(group.name)“ legen", systemImage: "person.3") { rehoming = TripHome(groupID: group.id, groupName: group.name) }
                        }
                        if trip.groupId != nil {
                            Button("Privat machen", systemImage: "lock") { rehoming = TripHome(groupID: nil, groupName: nil) }
                        }
                    } label: {
                        LabeledContent("Gehört zu", value: trip.groupName ?? "Privat")
                    }
                } else if let group = trip.groupName {
                    LabeledContent("Gehört zu", value: group)
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
                    // A tap opens the period to change or remove it, for those who may edit the trip.
                    Button {
                        if detail.role.canEdit { sheet = .change(option) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label ?? "Zeitraum").foregroundStyle(.primary)
                                Text([Format.dateRange(option.startDate, option.endDate), nights(option)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if detail.role.canEdit { Image(systemName: "pencil").font(.footnote).foregroundStyle(.tertiary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if detail.role.canEdit {
                            Button("Entfernen", systemImage: "trash") { removing = option }.tint(.red)
                        }
                    }
                }
                if detail.role.canEdit {
                    Button("Festen Zeitraum hinzufügen", systemImage: "calendar.badge.plus") { sheet = .period }
                    // The other way to say when: a window with a length of stay, for trips whose dates depend on the offer.
                    Button {
                        sheet = .window
                    } label: {
                        if let window = trip.flexWindow {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Flexibles Zeitfenster ändern")
                                    Text(window.summary).font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "calendar.badge.clock") }
                        } else {
                            Label("Flexibles Zeitfenster festlegen", systemImage: "calendar.badge.clock")
                        }
                    }
                }
            } header: {
                Text("Zeiträume")
            } footer: {
                if detail.role.canEdit {
                    Text(detail.dateOptions.isEmpty || trip.flexWindow == nil
                         ? "Fester Zeitraum: Anreise und Dauer stehen fest. Flexibles Zeitfenster: frühester Anreisetag, spätester Abreisetag und wie viele Nächte, dann zeigt jedes Angebot seine möglichen Reisedaten. Ein fester Zeitraum hat Vorrang. Tippe auf einen Zeitraum, um ihn zu ändern oder zu entfernen."
                         : "Solange ein fester Zeitraum eingetragen ist, hat er Vorrang, und das Zeitfenster wirkt nicht. Für mögliche Reisedaten entferne den festen Zeitraum: antippen, dann „Zeitraum entfernen“.")
                        .foregroundStyle(detail.dateOptions.isEmpty || trip.flexWindow == nil ? Color.secondary : Color.orange)
                }
            }
            Section {
                ForEach(detail.members) { member in
                    LabeledContent(member.name, value: member.role.label)
                }
                if detail.role == .organizer {
                    Button("Jemanden einladen", systemImage: "person.badge.plus", action: invite)
                }
                ForEach(openInvites) { open in
                    HStack {
                        Image(systemName: "envelope").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Offene Einladung")
                            Text(open.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zurückziehen", role: .destructive) { revoke(open) }.buttonStyle(.borderless).font(.footnote)
                    }
                }
                if !openInvites.isEmpty {
                    Text("Wer einen offenen Link hat, kann der Reise beitreten. Ziehe Links zurück, die du nicht mehr brauchst.")
                        .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
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
            groups = (try? await model.backend?.groups()) ?? []
            if detail.role == .organizer { openInvites = (try? await model.backend?.tripInvites(tripId: trip.id)) ?? [] }
        }
    }

    private func revoke(_ open: GroupInvite) {
        guard let backend = model.backend else { return }
        Task {
            try? await backend.revokeTripInvite(tripId: trip.id, inviteId: open.id)
            openInvites = (try? await backend.tripInvites(tripId: trip.id)) ?? []
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

/// Where a trip is to go: a group, or private with nil.
struct TripHome: Identifiable {
    var groupID: String?
    var groupName: String?
    var id: String { groupID ?? "private" }
}

enum FramingSheet: Identifiable {
    case edit, period
    /// The flexible window on its own: earliest arrival, latest departure and how many nights.
    case window
    /// An existing period, to change or remove.
    case change(DateOption)

    var id: String {
        switch self {
        case .edit: "edit"
        case .period: "period"
        case .window: "window"
        case .change(let option): "change-\(option.id)"
        }
    }
}

/// Title, region, party and budget of a trip.
struct TripEditor: View {
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    /// Shows the flexible window alone, switched on, for the shortcut from the periods.
    var onlyWindow = false
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
    /// The length of stay liked best, when one is given.
    @State private var wish = false
    @State private var nightsWish = 10
    @State private var filled = false

    private var window: FlexWindow {
        FlexWindow(start: Format.isoDay(flexStart), end: Format.isoDay(flexEnd), nightsMin: nightsMin, nightsMax: max(nightsMin, nightsMax),
                   nightsPreferred: wish && nightsMax > nightsMin ? min(max(nightsWish, nightsMin), max(nightsMin, nightsMax)) : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !onlyWindow {
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
                }
                Section {
                    Toggle("Flexibler Zeitraum", isOn: $flexible)
                    if flexible {
                        DatePicker("Frühestens anreisen", selection: $flexStart, displayedComponents: .date)
                        DatePicker("Spätestens abreisen", selection: $flexEnd, in: flexStart..., displayedComponents: .date)
                        Stepper("Mindestens \(nightsMin) \(nightsMin == 1 ? "Nacht" : "Nächte")", value: $nightsMin, in: 1...60)
                        if nightsMax > nightsMin {
                            Toggle("Lieblingsdauer angeben", isOn: $wish)
                            if wish {
                                Stepper("Am liebsten \(nightsWish) \(nightsWish == 1 ? "Nacht" : "Nächte")", value: $nightsWish, in: nightsMin...nightsMax)
                            }
                        }
                        Stepper("Höchstens \(nightsMax) \(nightsMax == 1 ? "Nacht" : "Nächte")", value: $nightsMax, in: nightsMin...60)
                    }
                } footer: {
                    Text(!flexible ? "Für Reisen, deren genaue Daten vom Angebot abhängen: Statt eines festen Zeitraums gibst du ein Fenster und eine Dauer an."
                         : window.isValid ? (wish && nightsMax > nightsMin
                                            ? "Jeder Aufenthalt in diesem Fenster zählt. Vorn steht der günstigste Termin mit der Lieblingsdauer. Ein längerer nur, wenn er je Nacht deutlich günstiger ist, ein anderer, wenn es die Lieblingsdauer nicht gibt."
                                            : "Jeder Aufenthalt in diesem Fenster zählt als Preis der Reise, auch die Daten aus einem geteilten Link. Verglichen wird der Preis je Nacht.")
                         : "Das Fenster ist kürzer als der kürzeste Aufenthalt.")
                        .foregroundStyle(flexible && !window.isValid ? Color.red : Color.secondary)
                }
            }
            .navigationTitle(onlyWindow ? "Zeitfenster" : "Rahmen")
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
                    if let liked = known.nightsPreferred { wish = true; nightsWish = liked }
                    else { nightsWish = (known.nightsMin + known.nightsMax) / 2 }
                } else if onlyWindow {
                    // Opened to set a window: the fields are there at once.
                    flexible = true
                }
            }
            .onChange(of: nightsMin) {
                if nightsMax < nightsMin { nightsMax = nightsMin }
                nightsWish = min(max(nightsWish, nightsMin), nightsMax)
            }
            .onChange(of: nightsMax) { nightsWish = min(max(nightsWish, nightsMin), max(nightsMin, nightsMax)) }
        }
    }
}

/// A further period the trip could take place in.
struct PeriodEditor: View {
    @Environment(\.dismiss) private var dismiss
    /// The period being changed; nil adds a new one.
    var existing: DateOption?
    /// Asks to remove the period being changed.
    var remove: (() -> Void)?
    let save: (String?, String, String) -> Void

    @State private var label = ""
    @State private var start = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var nights = 14
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, zum Beispiel „Zweite Ferienhälfte“ (freiwillig)", text: $label)
                    DatePicker("Anreise", selection: $start, displayedComponents: .date)
                    Stepper("Nächte: \(nights)", value: $nights, in: 1...60)
                } footer: {
                    if existing != nil {
                        Text("Nach einer Änderung gelten die bisher geprüften Preise nicht mehr für diesen Zeitraum. Tippe danach in der Angebotsliste auf „Preise prüfen“.")
                    }
                }
                if existing != nil, let remove {
                    Section {
                        Button("Zeitraum entfernen", systemImage: "trash", role: .destructive) {
                            dismiss()
                            // The question "really remove?" can only come up once this sheet has gone.
                            Task { try? await Task.sleep(for: .milliseconds(600)); remove() }
                        }
                    }
                }
            }
            .onAppear {
                guard !filled, let existing else { return }
                filled = true
                label = existing.label ?? ""
                if let from = Format.day(existing.startDate) {
                    start = from
                    if let to = Format.day(existing.endDate) { nights = max(1, min(60, Calendar.current.dateComponents([.day], from: from, to: to).day ?? 14)) }
                }
            }
            .navigationTitle(existing == nil ? "Neuer Zeitraum" : "Zeitraum ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Hinzufügen" : "Sichern") {
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
    @Binding var rehoming: TripHome?
    let run: (@escaping (any TravelBackend) async throws -> Void) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .edit:
                    if let trip {
                        TripEditor(trip: trip) { changes in run { _ = try await $0.updateTrip(tripId: tripID, changes: changes) } }
                    }
                case .window:
                    if let trip {
                        TripEditor(trip: trip, onlyWindow: true) { changes in run { _ = try await $0.updateTrip(tripId: tripID, changes: changes) } }
                    }
                case .period:
                    PeriodEditor { label, start, end in
                        run { _ = try await $0.addDateOption(tripId: tripID, label: label, startDate: start, endDate: end) }
                    }
                case .change(let option):
                    PeriodEditor(existing: option, remove: { removing = option }) { label, start, end in
                        // The server knows adding and removing: the new period goes in first, then the old one out,
                        // so a failure in between never leaves the trip without the period.
                        run {
                            _ = try await $0.addDateOption(tripId: tripID, label: label, startDate: start, endDate: end)
                            try await $0.removeDateOption(tripId: tripID, optionId: option.id)
                        }
                    }
                }
            }
            .alert(rehoming?.groupID == nil ? "Reise privat machen?" : "Reise in die Gruppe legen?",
                   isPresented: Binding(get: { rehoming != nil }, set: { if !$0 { rehoming = nil } }), presenting: rehoming) { home in
                Button(home.groupID == nil ? "Privat machen" : "In die Gruppe legen", role: home.groupID == nil ? .destructive : nil) {
                    run { try await $0.setTripGroup(tripId: tripID, groupId: home.groupID) }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { home in
                Text(home.groupID == nil
                     ? "Die Mitglieder von „\(trip?.groupName ?? "der Gruppe")“ verlieren sofort den Zugriff auf diese Reise, auch wer zusätzlich einzeln eingeladen war. Es bleiben du und wer die Reise organisiert. Stimmen und Kommentare bleiben stehen."
                     : "Alle Mitglieder von „\(home.groupName ?? "der Gruppe")“ sehen die Reise dann und können mitmachen." + (trip?.groupId != nil ? " Die Mitglieder der bisherigen Gruppe verlieren den Zugriff." : ""))
            }
            .alert("Zeitraum entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { option in
                Button("Entfernen", role: .destructive) { run { try await $0.removeDateOption(tripId: tripID, optionId: option.id) } }
                Button("Abbrechen", role: .cancel) {}
            } message: { option in
                Text("„\(option.label ?? Format.dateRange(option.startDate, option.endDate) ?? "Zeitraum")“ wird entfernt. Die dafür erfassten Preise zählen dann nicht mehr für die Reise.")
            }
    }
}
