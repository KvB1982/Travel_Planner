import SwiftUI
import TravelPlannerKit

/// The shared purse of a trip: who paid what, who owes whom, and the fewest payments to settle.
struct LedgerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tripID: String
    let role: MemberRole
    let members: [Member]

    @State private var ledger: Ledger?
    @State private var busy = false
    @State private var error: String?
    @State private var adding = false
    @State private var editing: Expense?
    @State private var editingParties = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if let ledger {
                    if ledger.parties.isEmpty {
                        setup
                    } else {
                        balances(ledger)
                        if !ledger.transfers.isEmpty || !ledger.payments.isEmpty { settling(ledger) }
                        expenses(ledger)
                        splitting(ledger)
                    }
                } else if error == nil {
                    Section { HStack { ProgressView(); Text("Lade die Kasse …").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle("Gemeinsame Kasse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if let ledger, !ledger.parties.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Ausgabe hinzufügen", systemImage: "plus") { adding = true }
                    }
                }
            }
            .disabled(busy)
            .task { run { try await $0.ledger(tripId: tripID) } }
            .sheet(isPresented: $adding) {
                if let ledger {
                    ExpenseEditor(ledger: ledger, expense: nil) { draft in run { try await $0.addExpense(tripId: tripID, expense: draft) } }
                }
            }
            .sheet(item: $editing) { expense in
                if let ledger {
                    ExpenseEditor(ledger: ledger, expense: expense) { draft in run { try await $0.updateExpense(expenseId: expense.id, expense: draft) } }
                }
            }
            .sheet(isPresented: $editingParties) {
                PartiesEditor(parties: ledger?.parties.map(PartyDraft.init) ?? [], members: members) { drafts in
                    run { try await $0.setParties(tripId: tripID, parties: drafts) }
                }
            }
        }
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> Ledger) {
        guard let backend = model.backend else { return }
        busy = true
        Task {
            do {
                ledger = try await action(backend)
                error = nil
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }

    // MARK: Parts

    private var setup: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Noch keine Haushalte").font(.headline)
                Text("Kosten werden zwischen Haushalten geteilt, zum Beispiel je Familie. Ein Haushalt kann auch Personen ohne App enthalten.")
                    .foregroundStyle(.secondary)
                if role.canEdit {
                    Button("Haushalte vorschlagen") { run { try await $0.suggestParties(tripId: tripID) } }
                        .buttonStyle(.borderedProminent)
                    Text("Legt je Mitglied einen Haushalt an. Namen und Personenzahl passt du danach an.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Ein Mitglied der Reise legt sie an.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func balances(_ ledger: Ledger) -> some View {
        Section {
            ForEach(ledger.parties) { party in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(party.id == ledger.myPartyId ? "\(party.name) (du)" : party.name).font(.headline)
                        Text("\(people(party)) · bezahlt \(Format.euroExact(cents: party.paidCents)) · Anteil \(Format.euroExact(cents: party.shareCents))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.euroExact(cents: abs(party.balanceCents))).font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(party.balanceCents == 0 ? Color.secondary : party.balanceCents > 0 ? .green : .red)
                        Text(party.balanceCents == 0 ? "ausgeglichen" : party.balanceCents > 0 ? "bekommt zurück" : "schuldet noch")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if role.canEdit {
                Button("Haushalte bearbeiten", systemImage: "person.2") { editingParties = true }
            }
        } header: {
            Text("Stand · Ausgaben gesamt \(Format.euroExact(cents: ledger.totalCents))").textCase(nil)
        }
    }

    private func people(_ party: LedgerParty) -> String {
        var parts = [party.adults == 1 ? "1 Erwachsener" : "\(party.adults) Erwachsene"]
        if party.children > 0 { parts.append(party.children == 1 ? "1 Kind" : "\(party.children) Kinder") }
        return parts.joined(separator: ", ")
    }

    private func settling(_ ledger: Ledger) -> some View {
        Section {
            ForEach(ledger.transfers) { transfer in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ledger.name(of: transfer.from)) zahlt an \(ledger.name(of: transfer.to))")
                        Text(Format.euroExact(cents: transfer.amountCents)).font(.body.weight(.semibold).monospacedDigit())
                    }
                    Spacer()
                    if role.canEdit {
                        Button("Erledigt", systemImage: "checkmark.circle") {
                            run { try await $0.addPayment(tripId: tripID, from: transfer.from, to: transfer.to, amountCents: transfer.amountCents) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            ForEach(ledger.payments) { payment in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(ledger.name(of: payment.fromParty)) hat \(Format.euroExact(cents: payment.amountCents)) an \(ledger.name(of: payment.toParty)) gezahlt")
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    if role.canEdit {
                        Button("Zurücknehmen", systemImage: "arrow.uturn.backward", role: .destructive) {
                            run { try await $0.deletePayment(tripId: tripID, paymentId: payment.id) }
                        }
                    }
                }
            }
            if ledger.transfers.isEmpty {
                Text("Alles ist ausgeglichen.").font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            } else {
                Text("Der Vorschlag kommt mit möglichst wenigen Zahlungen aus. Die App überweist nichts, sie hakt nur ab.")
                    .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
        } header: {
            Text("Ausgleich")
        }
    }

    private func expenses(_ ledger: Ledger) -> some View {
        Section {
            if ledger.expenses.isEmpty {
                Text("Noch keine Ausgaben. Mit dem Plus oben rechts trägst du die erste ein.").foregroundStyle(.secondary)
            }
            ForEach(ledger.expenses.sorted { ($0.spentOn ?? "") > ($1.spentOn ?? "") }) { expense in
                Button { editing = expense } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.title).foregroundStyle(.primary)
                            Text(details(expense, ledger)).font(.footnote).foregroundStyle(.secondary)
                            if expense.unsplit == true {
                                Label("Nicht eingerechnet: Der Haushalt fehlt.", systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(Format.euroExact(cents: expense.amountCents)).font(.body.monospacedDigit()).foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteExpense(expenseId: expense.id) } }
                }
            }
        } header: {
            Text("Ausgaben")
        }
    }

    private func details(_ expense: Expense, _ ledger: Ledger) -> String {
        var parts = [ledger.name(of: expense.paidBy)]
        if let day = expense.spentOn.flatMap(Format.day) { parts.append(day.formatted(.dateTime.day().month().locale(Locale(identifier: "de_DE")))) }
        if let category = expense.category, !category.isEmpty { parts.append(category) }
        switch expense.mode {
        case "heads": parts.append("nach Köpfen")
        case "custom": parts.append("eigene Aufteilung")
        case "equal": parts.append("je Haushalt gleich")
        default: break
        }
        if let among = expense.among, !among.isEmpty, among.count < ledger.parties.count { parts.append("nur \(among.count) Haushalte") }
        return parts.joined(separator: " · ")
    }

    private func splitting(_ ledger: Ledger) -> some View {
        Section {
            Picker("Aufteilung der Reise", selection: Binding(get: { ledger.splitMode }, set: { setSplit($0, ledger.childWeight) })) {
                Text("Je Haushalt gleich").tag("equal")
                Text("Nach Köpfen").tag("heads")
            }
            Picker("Ein Kind zählt", selection: Binding(get: { ledger.childWeight }, set: { setSplit(ledger.splitMode, $0) })) {
                Text("voll").tag(1.0)
                Text("halb").tag(0.5)
                Text("nicht").tag(0.0)
                if ![1.0, 0.5, 0.0].contains(ledger.childWeight) { Text(Format.number(ledger.childWeight)).tag(ledger.childWeight) }
            }
            Text("Gilt für alle Ausgaben, die keine eigene Aufteilung haben. Wie viel ein Kind zählt, wirkt nur bei der Aufteilung nach Köpfen.")
                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
        } header: {
            Text("Aufteilung")
        }
        .disabled(role != .organizer)
    }

    private func setSplit(_ mode: String, _ weight: Double) {
        run {
            try await $0.setSplit(tripId: tripID, splitMode: mode, childWeight: weight)
            return try await $0.ledger(tripId: tripID)
        }
    }
}

/// One expense: what, how much, who paid, and how it is shared.
struct ExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    let ledger: Ledger
    let expense: Expense?
    let save: (ExpenseDraft) -> Void

    @State private var title = ""
    @State private var amount = ""
    @State private var paidBy = ""
    @State private var day = Date.now
    @State private var category = ""
    /// "" stands for "as the trip splits".
    @State private var mode = ""
    @State private var sharing: Set<String> = []
    @State private var weights: [String: Int] = [:]
    @State private var note = ""
    @State private var filled = false

    private var cents: Int? { Format.cents(from: amount) }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && cents != nil && !paidBy.isEmpty && !sharing.isEmpty
            && (mode != "custom" || sharing.contains { (weights[$0] ?? 0) > 0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Wofür, zum Beispiel Einkauf", text: $title)
                    TextField("Betrag in Euro", text: $amount).keyboardType(.decimalPad)
                    Picker("Bezahlt von", selection: $paidBy) {
                        ForEach(ledger.parties) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Datum", selection: $day, displayedComponents: .date)
                    TextField("Kategorie (freiwillig)", text: $category)
                }
                Section {
                    Picker("Aufteilung", selection: $mode) {
                        Text("Wie die Reise").tag("")
                        Text("Je Haushalt gleich").tag("equal")
                        Text("Nach Köpfen").tag("heads")
                        Text("Eigene Anteile").tag("custom")
                    }
                    ForEach(ledger.parties) { party in
                        if mode == "custom" {
                            Stepper("\(party.name): \(weights[party.id] ?? 0) \((weights[party.id] ?? 0) == 1 ? "Anteil" : "Anteile")",
                                    value: Binding(get: { weights[party.id] ?? 0 }, set: { weights[party.id] = $0 }), in: 0...20)
                        } else {
                            Toggle(party.name, isOn: Binding(get: { sharing.contains(party.id) },
                                                             set: { if $0 { sharing.insert(party.id) } else { sharing.remove(party.id) } }))
                        }
                    }
                } header: {
                    Text("Wer teilt")
                } footer: {
                    Text(mode == "custom" ? "Zum Beispiel die Zahl der Teilnehmenden je Haushalt. Null heißt: zahlt nichts mit."
                                          : "Schalte Haushalte ab, die an dieser Ausgabe nicht beteiligt sind.")
                }
                Section { TextField("Notiz (freiwillig)", text: $note, axis: .vertical) }
            }
            .navigationTitle(expense == nil ? "Neue Ausgabe" : "Ausgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        guard let cents else { return }
                        let everyone = sharing.count == ledger.parties.count
                        save(ExpenseDraft(title: title.trimmingCharacters(in: .whitespaces), amountCents: cents, paidBy: paidBy,
                                          spentOn: Format.isoDay(day), category: category.isEmpty ? nil : category,
                                          mode: mode.isEmpty ? nil : mode,
                                          among: mode == "custom" || everyone ? [] : ledger.parties.map(\.id).filter(sharing.contains),
                                          weights: mode == "custom" ? weights.filter { $0.value > 0 }.mapValues(Double.init) : [:],
                                          note: note.isEmpty ? nil : note))
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        let all = Set(ledger.parties.map(\.id))
        guard let expense else {
            paidBy = ledger.myPartyId ?? ledger.parties.first?.id ?? ""
            sharing = all
            for id in all { weights[id] = 1 }
            return
        }
        title = expense.title
        amount = (Decimal(expense.amountCents) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "de_DE")))
        paidBy = expense.paidBy ?? ""
        day = expense.spentOn.flatMap(Format.day) ?? .now
        category = expense.category ?? ""
        mode = expense.mode ?? ""
        let among = Set(expense.among ?? []).intersection(all)
        sharing = among.isEmpty ? all : among
        for id in all { weights[id] = expense.mode == "custom" ? Int((expense.weights?[id] ?? 0).rounded()) : 1 }
        note = expense.note ?? ""
    }
}

/// The households of the trip: names, how many people, and which members belong to them.
struct PartiesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var parties: [PartyDraft]
    let members: [Member]
    let save: ([PartyDraft]) -> Void

    private var valid: Bool { !parties.isEmpty && parties.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.adults + $0.children > 0 } }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($parties) { $party in
                    Section {
                        TextField("Name, zum Beispiel Familie A", text: $party.name)
                        Stepper("Erwachsene: \(party.adults)", value: $party.adults, in: 0...12)
                        Stepper("Kinder: \(party.children)", value: $party.children, in: 0...12)
                        if !members.isEmpty {
                            Menu {
                                ForEach(members) { member in
                                    Toggle(member.name, isOn: Binding(get: { party.memberIds.contains(member.id) }, set: { assign(member.id, to: party.id, $0) }))
                                }
                            } label: {
                                LabeledContent("Mit App dabei", value: names(party))
                            }
                        }
                        Button("Haushalt entfernen", systemImage: "trash", role: .destructive) { parties.removeAll { $0.id == party.id } }
                    }
                }
                Section {
                    Button("Haushalt hinzufügen", systemImage: "plus") { parties.append(PartyDraft(name: "")) }
                } footer: {
                    Text("Ausgaben eines entfernten Haushalts bleiben stehen, werden aber nicht mehr eingerechnet, bis du sie einem anderen zuordnest.")
                }
            }
            .navigationTitle("Haushalte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save(parties); dismiss() }.disabled(!valid)
                }
            }
        }
    }

    private func names(_ party: PartyDraft) -> String {
        let names = members.filter { party.memberIds.contains($0.id) }.map(\.name)
        return names.isEmpty ? "niemand" : names.joined(separator: ", ")
    }

    /// A member belongs to one household only.
    private func assign(_ member: String, to party: UUID, _ on: Bool) {
        for index in parties.indices {
            parties[index].memberIds.removeAll { $0 == member }
            if on && parties[index].id == party { parties[index].memberIds.append(member) }
        }
    }
}
