import SwiftUI
import TravelPlannerKit

/// The trip while it happens: what is on today, and the house book.
struct TravellingSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let detail: TripDetail
    /// The house book to edit; the sheet belongs to the whole screen.
    @Binding var editing: HouseBook?
    let showLedger: () -> Void

    @State private var day = Date.now
    @State private var today: TripDay?
    @State private var book: HouseBook?
    @State private var error: String?
    @State private var copied: String?
    @State private var showPassword = false

    private var tripID: String { detail.trip.id }
    private var german: Locale { Locale(identifier: "de_DE") }

    var body: some View {
        Group {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            dayPart
            housePart
            Section {
                Button("Gemeinsame Kasse", systemImage: "eurosign.circle", action: showLedger)
            }
        }
        .task(id: "\(model.revision)|\(Format.isoDay(day))") { await load() }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            async let one = backend.today(tripId: tripID, date: Format.isoDay(day))
            async let two = backend.house(tripId: tripID)
            (today, book) = try await (one, two)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
    }

    // MARK: Today

    @ViewBuilder private var dayPart: some View {
        Section {
            HStack {
                Button("Tag zurück", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                Spacer()
                VStack(spacing: 1) {
                    Text(Calendar.current.isDateInToday(day) ? "Heute" : day.formatted(.dateTime.weekday(.wide).locale(german))).font(.headline)
                    Text(day.formatted(.dateTime.day().month(.wide).year().locale(german))).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Tag vor", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let today {
                if today.arrivalDay { Label("Anreisetag", systemImage: "arrow.down.to.line").foregroundStyle(.tint) }
                if today.departureDay { Label("Abreisetag", systemImage: "arrow.up.to.line").foregroundStyle(.tint) }
                ForEach(today.bookings) { mark in
                    row(mark.kind.symbol, mark.title,
                        [mark.begins == true ? "beginnt\(clock(mark.startsAt))" : nil, mark.ends == true ? "endet\(clock(mark.endsAt))" : nil,
                         mark.place, mark.reference.map { "Nr. \($0)" }].compactMap { $0 })
                }
                ForEach(today.legs) { leg in
                    row(leg.modeSymbol, [leg.fromPlace, leg.toPlace].compactMap { $0 }.joined(separator: " nach "),
                        [leg.directionLabel, time(leg.departAt).map { "ab \($0)" }, time(leg.arriveAt).map { "an \($0)" }].compactMap { $0 })
                }
                ForEach(today.activities) { activity in
                    row("figure.hiking", activity.title,
                        [time(activity.startsAt), activity.place, "\(activity.tally.yes ?? 0) dabei"].compactMap { $0 })
                }
                if today.isEmpty {
                    Text("Für diesen Tag ist nichts eingetragen.").foregroundStyle(.secondary)
                }
                if today.ideas > 0 {
                    Text(today.ideas == 1 ? "1 Idee ohne Termin wartet unter Vorbereitung, Aktivitäten." : "\(today.ideas) Ideen ohne Termin warten unter Vorbereitung, Aktivitäten.")
                        .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            } else if error == nil {
                HStack { ProgressView(); Text("Lade den Tag …").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Tagesplan")
        }
    }

    private func step(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }

    private func row(_ symbol: String, _ title: String, _ facts: [String]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func time(_ text: String?) -> String? {
        guard let text, text.count > 10 else { return nil }
        return "\(text.suffix(5)) Uhr"
    }

    private func clock(_ text: String?) -> String { time(text).map { " um \($0)" } ?? "" }

    // MARK: House book

    @ViewBuilder private var housePart: some View {
        if let book {
            Section {
                ForEach(House.fields) { field in
                    if let value = book.house.text(field.key) {
                        filled(field, value)
                    } else if let offer = book.suggestions.text(field.key), !offer.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: field.symbol).foregroundStyle(.secondary).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label).font(.footnote).foregroundStyle(.secondary)
                                Text(offer).foregroundStyle(.secondary)
                                Text("aus Steckbrief oder Buchung").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if detail.role.canEdit {
                                Button("Übernehmen") { change([field.key: .text(offer)]) }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if House.fields.allSatisfy({ book.house.text($0.key) == nil && (book.suggestions.text($0.key) ?? "").isEmpty }) {
                    Text("Noch leer. Trag ein, was vor Ort jeder wissen muss: Schlüssel, WLAN, Ansprechperson, Müll.").foregroundStyle(.secondary)
                }
                if detail.role.canEdit {
                    Button("Hausmappe bearbeiten", systemImage: "pencil") { editing = book }
                }
                if let copied {
                    Text("\(copied) kopiert").font(.footnote).foregroundStyle(.green).listRowSeparator(.hidden)
                }
            } header: {
                Text("Hausmappe")
            }
        }
    }

    @ViewBuilder private func filled(_ field: House.Field, _ value: String) -> some View {
        let secret = field.key == "wifiPassword"
        Button {
            switch field.key {
            case "contactPhone":
                if let url = URL(string: "tel:" + value.filter { $0.isNumber || $0 == "+" }) { openURL(url) }
            case "address":
                var parts = URLComponents(string: "https://maps.apple.com/")
                parts?.queryItems = [URLQueryItem(name: "q", value: value)]
                if let url = parts?.url { openURL(url) }
            default:
                UIPasteboard.general.string = value
                copied = field.label
                if secret { showPassword = true }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: field.symbol).foregroundStyle(.tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.footnote).foregroundStyle(.secondary)
                    Text(secret && !showPassword ? String(repeating: "•", count: 8) : value).foregroundStyle(.primary)
                        .font(secret || field.key == "wifiName" ? .body.monospaced() : .body)
                }
                Spacer()
                Image(systemName: field.key == "contactPhone" ? "phone.arrow.up.right" : field.key == "address" ? "arrow.up.right.square" : "doc.on.doc")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(field.label): \(secret ? "verborgen, tippen zum Kopieren" : value)")
    }

    private func change(_ changes: [String: PatchValue]) {
        guard let backend = model.backend else { return }
        Task {
            do {
                book = try await backend.updateHouse(tripId: tripID, changes: changes)
                error = nil
            } catch {
                self.error = model.message(for: error)
            }
        }
    }
}

extension HouseBook: @retroactive Identifiable {
    public var id: String { "house" }
}

/// All fields of the house book in one form.
struct HouseEditor: View {
    @Environment(\.dismiss) private var dismiss
    let book: HouseBook
    let save: ([String: PatchValue]) -> Void

    @State private var typed: [String: String] = [:]
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(House.fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(field.label, systemImage: field.symbol).font(.footnote).foregroundStyle(.secondary)
                            TextField(book.suggestions.text(field.key) ?? field.label, text: Binding(get: { typed[field.key] ?? "" }, set: { typed[field.key] = $0 }),
                                      axis: field.long ? .vertical : .horizontal)
                                .textInputAutocapitalization(field.key.hasPrefix("wifi") ? .never : .sentences)
                                .autocorrectionDisabled(field.key.hasPrefix("wifi"))
                                .keyboardType(field.key == "contactPhone" ? .phonePad : .default)
                        }
                    }
                } footer: {
                    Text("Alle Mitglieder der Reise können die Hausmappe lesen, auch Gäste. Schlüsselcode und WLAN-Passwort liegen hinter der Anmeldung auf eurem Server.")
                }
            }
            .navigationTitle("Hausmappe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save(book.changes(typed: typed)); dismiss() }.disabled(book.changes(typed: typed).isEmpty)
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                for field in House.fields { typed[field.key] = book.house.text(field.key) ?? "" }
            }
        }
    }
}
