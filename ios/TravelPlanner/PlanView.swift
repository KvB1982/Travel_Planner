import SwiftUI
import TravelPlannerKit

enum PlanSheet: Identifiable {
    case leg(TravelLeg?), room(Room?), activity(Activity?)
    var id: String {
        switch self {
        case .leg(let leg): "leg-\(leg?.id ?? "new")"
        case .room(let room): "room-\(room?.id ?? "new")"
        case .activity(let activity): "activity-\(activity?.id ?? "new")"
        }
    }
}

enum PreparationPart: String, CaseIterable, Identifiable {
    case lists, travel, rooms, activities
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lists: "Listen"
        case .travel: "Anreise"
        case .rooms: "Zimmer"
        case .activities: "Aktivitäten"
        }
    }
}

/// The preparation of a trip: lists, how everyone gets there, who sleeps where, and what to do.
struct PreparationSections: View {
    let detail: TripDetail
    @Binding var sheet: PlanSheet?
    @AppStorage("preparationPart") private var partRaw = PreparationPart.lists.rawValue

    private var part: PreparationPart { PreparationPart(rawValue: partRaw) ?? .lists }

    var body: some View {
        Section {
            Picker("Bereich", selection: $partRaw) {
                ForEach(PreparationPart.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
        }
        .listSectionSpacing(.compact)
        if part == .lists {
            ChecklistSections(tripID: detail.trip.id, role: detail.role)
        } else {
            PlanSections(detail: detail, part: part, sheet: $sheet)
        }
    }
}

struct PlanSections: View {
    @Environment(AppModel.self) private var model
    let detail: TripDetail
    let part: PreparationPart
    @Binding var sheet: PlanSheet?

    @State private var plan: TripPlan?
    @State private var parties: [LedgerParty] = []
    @State private var error: String?

    private var tripID: String { detail.trip.id }
    private var canEdit: Bool { detail.role.canEdit }
    private var german: Locale { Locale(identifier: "de_DE") }

    var body: some View {
        Group {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let plan {
                switch part {
                case .travel: travel(plan)
                case .rooms: rooms(plan)
                default: activities(plan)
                }
            } else if error == nil {
                Section { HStack { ProgressView(); Text("Lade die Vorbereitung …").foregroundStyle(.secondary) } }
            }
        }
        .task(id: model.revision) {
            run { try await $0.plan(tripId: tripID) }
            // Households come from the purse; without them legs and rooms simply carry no household.
            parties = (try? await model.backend?.ledger(tripId: tripID).parties) ?? []
        }
    }

    private func party(_ id: String?) -> String? { parties.first { $0.id == id }?.name }

    // MARK: Travel

    @ViewBuilder private func travel(_ plan: TripPlan) -> some View {
        ForEach(TravelLeg.directions, id: \.0) { direction, label in
            let legs = plan.legs.filter { $0.direction == direction }
            if !legs.isEmpty {
                Section {
                    ForEach(legs) { leg in
                        Button { if canEdit { sheet = .leg(leg) } } label: { legRow(leg) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                if canEdit {
                                    Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteLeg(legId: leg.id) } }
                                }
                            }
                    }
                } header: {
                    Text(label)
                }
            }
        }
        Section {
            if plan.legs.isEmpty {
                Text("Noch keine Strecke. Trag ein, wer wie und wann anreist, damit sich die Gruppe abstimmen kann.").foregroundStyle(.secondary)
            }
            if canEdit { Button("Strecke hinzufügen", systemImage: "plus") { sheet = .leg(nil) } }
        }
    }

    private func legRow(_ leg: TravelLeg) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: leg.modeSymbol).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text([leg.fromPlace, leg.toPlace].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " nach ").ifEmpty(leg.modeLabel)).foregroundStyle(.primary)
                let facts = [party(leg.partyId), moment(leg.departAt).map { "ab \($0)" }, moment(leg.arriveAt).map { "an \($0)" }].compactMap { $0 }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                if !leg.stops.isEmpty {
                    Text("über " + leg.stops.map { stop in stop.note.map { "\(stop.place) (\($0))" } ?? stop.place }.joined(separator: ", "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let notes = leg.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: Rooms

    @ViewBuilder private func rooms(_ plan: TripPlan) -> some View {
        Section {
            if plan.rooms.isEmpty {
                Text("Noch keine Zimmer. Du kannst sie aus dem Steckbrief des entschiedenen Angebots übernehmen oder von Hand anlegen.").foregroundStyle(.secondary)
                if canEdit {
                    Button("Zimmer aus dem Steckbrief übernehmen", systemImage: "wand.and.stars") { run { try await $0.suggestRooms(tripId: tripID) } }
                }
            }
            ForEach(plan.rooms) { room in
                Button { if canEdit { sheet = .room(room) } } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "bed.double").foregroundStyle(.tint).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name).foregroundStyle(.primary)
                            let facts = [room.beds, party(room.partyId)].compactMap { $0 }.filter { !$0.isEmpty }
                            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                            Text(room.occupants.isEmpty ? "noch frei" : room.occupants.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(room.occupants.isEmpty ? Color.orange : Color.secondary)
                            if let notes = room.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if canEdit {
                        Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteRoom(roomId: room.id) } }
                    }
                }
            }
            if canEdit { Button("Zimmer hinzufügen", systemImage: "plus") { sheet = .room(nil) } }
        } header: {
            Text("Zimmerverteilung")
        }
    }

    // MARK: Activities

    @ViewBuilder private func activities(_ plan: TripPlan) -> some View {
        Section {
            if plan.activities.isEmpty {
                Text("Noch keine Ideen. Sammelt hier, was ihr unternehmen wollt, und sagt zu oder ab.").foregroundStyle(.secondary)
            }
            ForEach(plan.activities) { activity in
                VStack(alignment: .leading, spacing: 6) {
                    Button { sheet = .activity(activity) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.title).font(.headline).foregroundStyle(.primary).strikethrough(activity.status == "cancelled")
                            let facts = [activity.statusLabel, moment(activity.startsAt), activity.place, cost(activity)].compactMap { $0 }.filter { !$0.isEmpty }
                            Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                            if let notes = activity.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        answer(activity, "yes", "Dabei", "hand.thumbsup", activity.tally.yes)
                        answer(activity, "maybe", "Vielleicht", "questionmark.circle", activity.tally.maybe)
                        answer(activity, "no", "Nicht dabei", "hand.thumbsdown", activity.tally.no)
                    }
                    let named = activity.responses.compactMap { response in response.name.map { "\($0): \(word(response.answer))" } }
                    if !named.isEmpty { Text(named.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
                .swipeActions {
                    if canEdit {
                        Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteActivity(activityId: activity.id) } }
                    }
                }
            }
            Button("Aktivität vorschlagen", systemImage: "plus") { sheet = .activity(nil) }
        } header: {
            Text("Aktivitäten")
        }
    }

    private func answer(_ activity: Activity, _ value: String, _ label: String, _ symbol: String, _ count: Int?) -> some View {
        let mine = activity.myAnswer == value
        return Button {
            run { try await $0.respond(activityId: activity.id, answer: mine ? nil : value) }
        } label: {
            Label("\(count ?? 0)", systemImage: mine ? symbol + ".fill" : symbol)
                .font(.subheadline.weight(mine ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count ?? 0) Stimmen\(mine ? ", deine Antwort" : "")")
    }

    private func word(_ answer: String?) -> String {
        switch answer {
        case "yes": "dabei"
        case "maybe": "vielleicht"
        case "no": "nicht dabei"
        default: "offen"
        }
    }

    private func cost(_ activity: Activity) -> String? {
        guard let cents = activity.costCents else { return activity.costNote }
        return [Format.euroExact(cents: cents), activity.costNote].compactMap { $0 }.joined(separator: " ")
    }

    private func moment(_ text: String?) -> String? {
        guard let text, let day = Format.day(String(text.prefix(10))) else { return nil }
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month().locale(german))
        return text.count > 10 ? "\(date), \(text.suffix(5)) Uhr" : date
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> TripPlan) {
        guard let backend = model.backend else { return }
        Task {
            do {
                plan = try await action(backend)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = model.message(for: error)
            }
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

/// The sheets of the preparation, attached to the whole screen.
struct PlanPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let tripID: String
    @Binding var sheet: PlanSheet?
    let run: (@escaping (any TravelBackend) async throws -> Void) -> Void

    @State private var parties: [LedgerParty] = []

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { sheet in
                Group {
                    switch sheet {
                    case .leg(let leg):
                        LegEditor(leg: leg, parties: parties) { draft in run { _ = try await $0.saveLeg(tripId: tripID, legId: leg?.id, leg: draft) } }
                    case .room(let room):
                        RoomEditor(room: room, parties: parties) { draft in run { _ = try await $0.saveRoom(tripId: tripID, roomId: room?.id, room: draft) } }
                    case .activity(let activity):
                        ActivityEditor(activity: activity) { draft in run { _ = try await $0.saveActivity(tripId: tripID, activityId: activity?.id, activity: draft) } }
                    }
                }
                .task { parties = (try? await model.backend?.ledger(tripId: tripID).parties) ?? [] }
            }
    }
}

private let planStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return formatter
}()

private func planDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    return planStamp.date(from: text.count > 10 ? String(text.prefix(16)) : "\(text)T12:00")
}

private func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

struct LegEditor: View {
    @Environment(\.dismiss) private var dismiss
    let leg: TravelLeg?
    let parties: [LedgerParty]
    let save: (LegDraft) -> Void

    @State private var direction = "outbound"
    @State private var mode = "car"
    @State private var partyID = ""
    @State private var from = ""
    @State private var to = ""
    @State private var hasDeparture = false
    @State private var departure = Date.now
    @State private var hasArrival = false
    @State private var arrival = Date.now
    @State private var stops = ""
    @State private var notes = ""
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Richtung", selection: $direction) { ForEach(TravelLeg.directions, id: \.0) { Text($0.1).tag($0.0) } }
                    Picker("Verkehrsmittel", selection: $mode) { ForEach(TravelLeg.modes, id: \.0) { Label($0.1, systemImage: $0.2).tag($0.0) } }
                    if !parties.isEmpty {
                        Picker("Wer", selection: $partyID) {
                            Text("alle oder offen").tag("")
                            ForEach(parties) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    TextField("Von", text: $from)
                    TextField("Nach", text: $to)
                    Toggle("Abfahrt bekannt", isOn: $hasDeparture)
                    if hasDeparture { DatePicker("Abfahrt", selection: $departure) }
                    Toggle("Ankunft bekannt", isOn: $hasArrival)
                    if hasArrival { DatePicker("Ankunft", selection: $arrival) }
                } footer: {
                    Text("Zeiten in der jeweiligen Ortszeit.")
                }
                Section {
                    TextField("Zwischenstopps, mit Komma getrennt", text: $stops, axis: .vertical)
                    TextField("Notizen (freiwillig)", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(leg == nil ? "Neue Strecke" : "Strecke")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        // Notes of existing stops survive as long as the place keeps its name.
                        let known = Dictionary((leg?.stops ?? []).map { ($0.place, $0.note) }, uniquingKeysWith: { first, _ in first })
                        save(LegDraft(partyId: partyID.isEmpty ? nil : partyID, direction: direction, mode: mode, fromPlace: trimmed(from), toPlace: trimmed(to),
                                      departAt: hasDeparture ? planStamp.string(from: departure) : nil, arriveAt: hasArrival ? planStamp.string(from: arrival) : nil,
                                      stops: RoomDraft.names(from: stops).map { TravelLeg.Stop(place: $0, note: known[$0] ?? nil) }, notes: trimmed(notes)))
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                guard let leg else { return }
                direction = leg.direction; mode = leg.mode; partyID = leg.partyId ?? ""; from = leg.fromPlace ?? ""; to = leg.toPlace ?? ""
                if let date = planDate(leg.departAt) { hasDeparture = true; departure = date }
                if let date = planDate(leg.arriveAt) { hasArrival = true; arrival = date }
                stops = leg.stops.map(\.place).joined(separator: ", "); notes = leg.notes ?? ""
            }
        }
    }
}

struct RoomEditor: View {
    @Environment(\.dismiss) private var dismiss
    let room: Room?
    let parties: [LedgerParty]
    let save: (RoomDraft) -> Void

    @State private var name = ""
    @State private var beds = ""
    @State private var partyID = ""
    @State private var occupants = ""
    @State private var notes = ""
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, zum Beispiel Schlafzimmer 1", text: $name)
                    TextField("Betten, zum Beispiel 1 Doppelbett", text: $beds)
                    if !parties.isEmpty {
                        Picker("Haushalt", selection: $partyID) {
                            Text("keiner").tag("")
                            ForEach(parties) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    TextField("Wer schläft hier, mit Komma getrennt", text: $occupants, axis: .vertical)
                    TextField("Notizen (freiwillig)", text: $notes, axis: .vertical)
                } footer: {
                    Text("Namen frei eintragen, auch von Personen ohne App.")
                }
            }
            .navigationTitle(room == nil ? "Neues Zimmer" : "Zimmer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        save(RoomDraft(name: name.trimmingCharacters(in: .whitespaces), beds: trimmed(beds), partyId: partyID.isEmpty ? nil : partyID,
                                       occupants: RoomDraft.names(from: occupants), notes: trimmed(notes)))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                guard let room else { return }
                name = room.name; beds = room.beds ?? ""; partyID = room.partyId ?? ""; occupants = room.occupants.joined(separator: ", "); notes = room.notes ?? ""
            }
        }
    }
}

struct ActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    let activity: Activity?
    let save: (ActivityDraft) -> Void

    @State private var title = ""
    @State private var status = "idea"
    @State private var place = ""
    @State private var link = ""
    @State private var hasDate = false
    @State private var start = Date.now
    @State private var cost = ""
    @State private var costNote = ""
    @State private var notes = ""
    @State private var filled = false

    private var costValid: Bool { trimmed(cost) == nil || Format.cents(from: cost) != nil }
    private var linkValid: Bool {
        guard let text = trimmed(link) else { return true }
        return URL(string: text)?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was, zum Beispiel Bootstour", text: $title)
                    Picker("Stand", selection: $status) { ForEach(Activity.statuses, id: \.0) { Text($0.1).tag($0.0) } }
                    TextField("Ort (freiwillig)", text: $place)
                    TextField("Link (freiwillig)", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    if !linkValid { Text("Der Link muss mit https:// beginnen.").foregroundStyle(.red) }
                }
                Section {
                    Toggle("Mit Termin", isOn: $hasDate)
                    if hasDate { DatePicker("Beginn", selection: $start) }
                }
                Section {
                    TextField("Kosten in Euro (freiwillig)", text: $cost).keyboardType(.decimalPad)
                    TextField("Dazu, zum Beispiel pro Person", text: $costNote)
                    TextField("Notizen (freiwillig)", text: $notes, axis: .vertical)
                } footer: {
                    if !costValid { Text("Das ist kein Betrag.").foregroundStyle(.red) }
                }
            }
            .navigationTitle(activity == nil ? "Neue Aktivität" : "Aktivität")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        save(ActivityDraft(title: title.trimmingCharacters(in: .whitespaces), place: trimmed(place), url: trimmed(link), status: status,
                                           startsAt: hasDate ? planStamp.string(from: start) : nil, endsAt: hasDate ? activity?.endsAt : nil,
                                           costCents: Format.cents(from: cost), costNote: trimmed(costNote), notes: trimmed(notes)))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !costValid || !linkValid)
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                guard let activity else { return }
                title = activity.title; status = activity.status; place = activity.place ?? ""; link = activity.url ?? ""
                if let date = planDate(activity.startsAt) { hasDate = true; start = date }
                cost = activity.costCents.map { (Decimal($0) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "de_DE"))) } ?? ""
                costNote = activity.costNote ?? ""; notes = activity.notes ?? ""
            }
        }
    }
}
