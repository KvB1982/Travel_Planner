import SwiftUI
import TravelPlannerKit

/// The colour of the traffic light as a dot, with words for those who cannot tell the colours apart.
struct CriteriaLight: View {
    let verdict: CriteriaVerdict
    var showsText = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            if showsText { Text(words) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kriterien: \(words)")
    }

    private var color: Color { verdict.light == "green" ? .green : verdict.light == "yellow" ? .yellow : .red }
    // Different shapes as well as colours.
    private var symbol: String {
        verdict.light == "green" ? "checkmark.circle.fill" : verdict.light == "yellow" ? "exclamationmark.circle.fill" : "xmark.octagon.fill"
    }
    private var words: String {
        verdict.light == "green" ? "alles erfüllt" : verdict.light == "yellow" ? "noch offen" : "Muss verfehlt"
    }
}

/// The musts and wishes of a trip.
struct CriteriaEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tripID: String

    @State private var criteria: [Criterion] = []
    @State private var measurable: [Measurable] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var customLabel = ""

    private var unused: [Measurable] { measurable.filter { known in !criteria.contains { $0.key == known.key } } }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                Section {
                    ForEach($criteria) { $criterion in row($criterion) }
                        .onDelete { criteria.remove(atOffsets: $0) }
                        .onMove { criteria.move(fromOffsets: $0, toOffset: $1) }
                    if loaded && criteria.isEmpty {
                        Text("Noch keine Kriterien. Füge unten hinzu, was das Haus haben muss oder soll.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Muss: Fehlt es, steht die Ampel auf Rot. Wunsch: Fehlt es, steht sie auf Gelb. Was das Inserat nicht verrät, gilt als offen.")
                }
                if !unused.isEmpty {
                    Section("Hinzufügen") {
                        ForEach(grouped, id: \.0) { group, entries in
                            Menu(group) {
                                ForEach(entries) { entry in
                                    Button(entry.label) {
                                        criteria.append(Criterion(id: "", key: entry.key, level: "must", target: entry.rule == "yes" ? nil : defaultTarget(entry)))
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Eigenes Kriterium, zum Beispiel „Ruhige Lage“", text: $customLabel)
                        Button("Hinzufügen") {
                            criteria.append(Criterion(id: "", key: "custom", label: customLabel.trimmingCharacters(in: .whitespaces), level: "wish"))
                            customLabel = ""
                        }
                        .disabled(customLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Eigene Kriterien kann nur ein Mensch beurteilen. Das geht im Steckbrief jedes Angebots.")
                }
            }
            .overlay { if !loaded || busy { ProgressView() } }
            .navigationTitle("Kriterien")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern") { save() }.disabled(!loaded || busy) }
            }
        }
        .task {
            do {
                let list = try await model.backend?.criteria(tripId: tripID)
                criteria = list?.criteria ?? []
                measurable = list?.measurable ?? []
            } catch {
                self.error = model.message(for: error)
            }
            loaded = true
        }
    }

    private var grouped: [(String, [Measurable])] {
        let names = ["price": "Preis", "space": "Größe", "rating": "Bewertung", "location": "Lage", "amenities": "Ausstattung", "rules": "Regeln", "votes": "Stimmen"]
        var order: [String] = []
        var groups: [String: [Measurable]] = [:]
        for entry in unused {
            let name = names[entry.group ?? ""] ?? "Weitere"
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func defaultTarget(_ entry: Measurable) -> Double {
        switch entry.format {
        case "eur": 5000
        case "rating": 8
        case "meters": 500
        case "km": 50
        case "sqm": 100
        default: 3
        }
    }

    private func name(of criterion: Criterion) -> String {
        criterion.label ?? measurable.first { $0.key == criterion.key }?.label ?? criterion.key
    }

    @ViewBuilder
    private func row(_ criterion: Binding<Criterion>) -> some View {
        let known = measurable.first { $0.key == criterion.wrappedValue.key }
        VStack(alignment: .leading, spacing: 8) {
            Text(name(of: criterion.wrappedValue)).font(.headline)
            Picker("Gewicht", selection: criterion.level) {
                Text("Muss").tag("must")
                Text("Wunsch").tag("wish")
            }
            .pickerStyle(.segmented)
            if let known, known.rule == "min" || known.rule == "max" {
                HStack {
                    Text(known.rule == "min" ? "mindestens" : "höchstens").foregroundStyle(.secondary)
                    TextField("Wert", value: criterion.target, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text(unit(known.format)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func unit(_ format: String?) -> String {
        switch format {
        case "eur": "€"
        case "sqm": "m²"
        case "meters": "m"
        case "km": "km"
        case "rating": "von 10"
        default: ""
        }
    }

    private func save() {
        guard let backend = model.backend else { return }
        busy = true
        error = nil
        Task {
            do {
                _ = try await backend.setCriteria(tripId: tripID, criteria: criteria)
                model.dataChanged()
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}

/// Section of the profile: how this offer does against each criterion, with a way to judge by hand.
struct CriteriaSection: View {
    let verdict: CriteriaVerdict
    let canEdit: Bool
    /// Called with all verdicts given by hand, by criterion id.
    var setChecks: ([String: String]) -> Void

    var body: some View {
        let results = verdict.results ?? []
        Section {
            ForEach(results) { result in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: symbol(result.status)).foregroundStyle(color(result.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.label ?? result.key)
                        Text(explain(result)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canEdit {
                        Menu {
                            Button("Erfüllt", systemImage: "checkmark.circle") { judge(result, "met", in: results) }
                            Button("Nicht erfüllt", systemImage: "xmark.circle") { judge(result, "missed", in: results) }
                            if result.manual == true {
                                Button("Urteil zurücknehmen", systemImage: "arrow.uturn.backward") { judge(result, nil, in: results) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel("Selbst beurteilen: \(result.label ?? result.key)")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Kriterien")
                Spacer()
                CriteriaLight(verdict: verdict, showsText: true).textCase(nil)
            }
        }
    }

    /// The server replaces all manual verdicts of the offer at once, so the others are sent along.
    private func judge(_ result: CriteriaVerdict.Result, _ status: String?, in results: [CriteriaVerdict.Result]) {
        var checks: [String: String] = [:]
        for other in results where other.manual == true && other.id != result.id { checks[other.id] = other.status }
        if let status { checks[result.id] = status }
        setChecks(checks)
    }

    private func symbol(_ status: String) -> String {
        status == "met" ? "checkmark.circle.fill" : status == "missed" ? "xmark.circle.fill" : "questionmark.circle"
    }

    private func color(_ status: String) -> Color { status == "met" ? .green : status == "missed" ? .red : .secondary }

    private func explain(_ result: CriteriaVerdict.Result) -> String {
        var parts = [result.level == "must" ? "Muss" : "Wunsch"]
        if let target = result.target, let rule = result.rule, rule != "yes" {
            parts.append("\(rule == "min" ? "mindestens" : "höchstens") \(Format.number(target))")
        }
        if let value = result.value?.text, !value.isEmpty {
            parts.append("Inserat: \(value)")
        } else if result.status == "unknown" {
            parts.append(result.key == "custom" ? "bitte selbst beurteilen" : "im Inserat nicht genannt")
        }
        if result.manual == true { parts.append("von Hand beurteilt") }
        return parts.joined(separator: " · ")
    }
}
