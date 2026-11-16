import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import TravelPlannerKit

enum BookingSheet: Identifiable {
    case new, edit(Booking), payment(Booking)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let booking): "edit-\(booking.id)"
        case .payment(let booking): "pay-\(booking.id)"
        }
    }
}

/// What the booking screens ask the surrounding screen to present.
struct BookingRequests {
    var sheet: BookingSheet?
    /// The booking a file is being picked for.
    var uploadFor: Booking?
    var preview: URL?
    var removing: Booking?
}

/// What was booked for the trip: payment plan, deadlines and papers. The app records, it does not book.
struct BookingSections: View {
    @Environment(AppModel.self) private var model
    let detail: TripDetail
    let candidates: [CandidateSummary]
    @Binding var requests: BookingRequests

    @State private var overview: BookingOverview?
    @State private var myParty: String?
    @State private var error: String?
    @State private var opening: String?

    private var tripID: String { detail.trip.id }
    private var canEdit: Bool { detail.role.canEdit }
    private var german: Locale { Locale(identifier: "de_DE") }

    var body: some View {
        Group {
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let overview {
                if overview.bookings.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Noch keine Buchung").font(.headline)
                            Text("Halte hier fest, was gebucht wurde: Unterkunft, Flüge, Mietwagen. Die App bucht nichts selbst.").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    totals(overview.totals)
                    if !overview.deadlines.isEmpty { deadlines(overview) }
                    ForEach(overview.bookings) { booking(_: $0) }
                }
                if canEdit {
                    Section {
                        if let decided = decidedOffer(overview) {
                            Button("„\(decided.listing.title ?? "Entschiedenes Angebot")“ als Buchung anlegen", systemImage: "checkmark.seal") {
                                run { try await $0.addBooking(tripId: tripID, booking: BookingDraft(candidateId: decided.id)) }
                            }
                        }
                        Button("Buchung hinzufügen", systemImage: "plus") { requests.sheet = .new }
                    }
                }
            } else if error == nil {
                Section { HStack { ProgressView(); Text("Lade die Buchungen …").foregroundStyle(.secondary) } }
            }
        }
        .task(id: model.revision) {
            run { try await $0.bookings(tripId: tripID) }
            // Who paid is noted with the own household, when the purse has one.
            myParty = try? await model.backend?.ledger(tripId: tripID).myPartyId
        }
    }

    /// The offer the group decided on, as long as no booking refers to it yet.
    private func decidedOffer(_ overview: BookingOverview) -> CandidateSummary? {
        guard let id = detail.trip.decidedCandidateId, !overview.bookings.contains(where: { $0.candidateId == id }) else { return nil }
        return candidates.first { $0.id == id }
    }

    private func totals(_ totals: BookingOverview.Totals) -> some View {
        Section {
            LabeledContent("Geplant und gebucht", value: Format.euroExact(cents: totals.plannedCents ?? 0))
            LabeledContent("Davon bezahlt", value: Format.euroExact(cents: totals.paidCents ?? 0))
            LabeledContent("Noch offen", value: Format.euroExact(cents: totals.openCents ?? 0))
            if let deposits = totals.depositsOutCents, deposits > 0 {
                LabeledContent("Hinterlegte Kautionen", value: Format.euroExact(cents: deposits))
            }
        } header: {
            Text("Überblick")
        }
    }

    private func deadlines(_ overview: BookingOverview) -> some View {
        Section {
            ForEach(overview.deadlines) { deadline in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: deadline.type == "payment" ? "eurosign.circle" : deadline.type == "cancellation" ? "arrow.uturn.backward.circle" : "calendar")
                        .foregroundStyle(deadline.overdue == true ? Color.red : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deadline.label)
                        Text([day(deadline.on), deadline.overdue == true ? "überfällig" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(deadline.overdue == true ? Color.red : Color.secondary)
                    }
                    Spacer()
                    if let amount = deadline.amountCents { Text(Format.euroExact(cents: amount)).monospacedDigit() }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Fristen")
        }
    }

    private func booking(_ booking: Booking) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(booking.title).font(.headline)
                let facts = [booking.provider, booking.reference.map { "Nr. \($0)" }, booking.place].compactMap { $0 }.filter { !$0.isEmpty }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
                if let span = span(booking) { Text(span).font(.subheadline).foregroundStyle(.secondary) }
                if let total = booking.totalCents { Text(Format.euroExact(cents: total)).font(.body.weight(.semibold).monospacedDigit()) }
                if let until = booking.freeCancellationUntil { Text("Kostenlos stornierbar bis \(day(until))").font(.footnote).foregroundStyle(.secondary) }
                if let notes = booking.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(booking.payments) { payment in paymentRow(payment) }
            ForEach(booking.documents) { document in documentRow(document) }
            if canEdit {
                Menu {
                    Button("Zahlung hinzufügen", systemImage: "eurosign.circle") { requests.sheet = .payment(booking) }
                    Button("Dokument hinzufügen", systemImage: "doc.badge.plus") { requests.uploadFor = booking }
                    Button("Buchung bearbeiten", systemImage: "pencil") { requests.sheet = .edit(booking) }
                    Button("Buchung löschen", systemImage: "trash", role: .destructive) { requests.removing = booking }
                } label: {
                    Label("Bearbeiten und ergänzen", systemImage: "ellipsis.circle")
                }
            }
        } header: {
            Label("\(booking.kind.label) · \(booking.statusLabel)", systemImage: booking.kind.symbol)
        }
    }

    private func paymentRow(_ payment: BookingPayment) -> some View {
        Button {
            guard canEdit else { return }
            let party = myParty
            run {
                try await $0.setBookingPaymentPaid(paymentId: payment.id, paidOn: payment.isPaid ? nil : Format.isoDay(.now), paidByParty: payment.isPaid ? nil : party)
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: payment.isPaid ? "checkmark.circle.fill" : "circle").foregroundStyle(payment.isPaid ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payment.refundable == true ? "\(payment.label) (kommt zurück)" : payment.label).foregroundStyle(.primary)
                    Text(payment.paidOn.map { "bezahlt am \(day($0))" } ?? payment.dueOn.map { "fällig am \(day($0))" } ?? "ohne Termin")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.euroExact(cents: payment.amountCents)).monospacedDigit().foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(payment.label), \(Format.euroExact(cents: payment.amountCents)), \(payment.isPaid ? "bezahlt" : "offen")")
        .swipeActions {
            if canEdit {
                Button("Löschen", systemImage: "trash", role: .destructive) { run { try await $0.deleteBookingPayment(paymentId: payment.id) } }
            }
        }
    }

    private func documentRow(_ document: TripDocument) -> some View {
        Button { open(document) } label: {
            HStack {
                Image(systemName: document.contentType == "application/pdf" ? "doc.richtext" : document.contentType?.hasPrefix("image/") == true ? "photo" : "doc.text")
                    .foregroundStyle(.tint)
                Text(document.title).foregroundStyle(.primary)
                Spacer()
                if opening == document.id { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            if canEdit {
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    run {
                        try await $0.deleteDocument(documentId: document.id)
                        return try await $0.bookings(tripId: tripID)
                    }
                }
            }
        }
    }

    /// Fetches the file and hands it to the preview. It lies in the temporary folder only as long as the system keeps it.
    private func open(_ document: TripDocument) {
        guard let backend = model.backend, opening == nil else { return }
        opening = document.id
        Task {
            do {
                let data = try await backend.documentFile(documentId: document.id)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Unterlagen", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = document.title.replacingOccurrences(of: "/", with: "-")
                let url = folder.appendingPathComponent("\(name).\(document.fileExtension)")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                requests.preview = url
            } catch {
                self.error = model.message(for: error)
            }
            opening = nil
        }
    }

    private func day(_ iso: String) -> String {
        Format.day(String(iso.prefix(10)))?.formatted(.dateTime.day().month().year().locale(german)) ?? iso
    }

    private func span(_ booking: Booking) -> String? {
        func moment(_ text: String?) -> String? {
            guard let text else { return nil }
            let time = text.count > 10 ? ", \(text.suffix(5)) Uhr" : ""
            return day(text) + time
        }
        let parts = [moment(booking.startsAt), moment(booking.endsAt)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " bis ")
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> BookingOverview) {
        guard let backend = model.backend else { return }
        Task {
            do {
                overview = try await action(backend)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = model.message(for: error)
            }
        }
    }
}

/// Sheets, file picker, preview and the delete question of the bookings, attached to the whole screen.
struct BookingPresenter: ViewModifier {
    let tripID: String
    @Binding var requests: BookingRequests
    let run: (@escaping (any TravelBackend) async throws -> Void) -> Void

    private static let types: [UTType] = [.pdf, .jpeg, .png, .heic, .webP, .plainText]

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.sheet) { sheet in
                switch sheet {
                case .new:
                    BookingEditor(booking: nil) { draft in run { _ = try await $0.addBooking(tripId: tripID, booking: draft) } }
                case .edit(let booking):
                    BookingEditor(booking: booking) { draft in run { _ = try await $0.updateBooking(bookingId: booking.id, booking: draft) } }
                case .payment(let booking):
                    BookingPaymentEditor { label, cents, due, refundable in
                        run { _ = try await $0.addBookingPayment(bookingId: booking.id, label: label, amountCents: cents, dueOn: due, refundable: refundable) }
                    }
                }
            }
            .fileImporter(isPresented: Binding(get: { requests.uploadFor != nil }, set: { if !$0 { requests.uploadFor = nil } }), allowedContentTypes: Self.types) { result in
                guard let booking = requests.uploadFor, case .success(let url) = result else { return }
                upload(url, to: booking)
            }
            .quickLookPreview($requests.preview)
            .alert("Buchung löschen?", isPresented: Binding(get: { requests.removing != nil }, set: { if !$0 { requests.removing = nil } }), presenting: requests.removing) { booking in
                Button("Löschen", role: .destructive) { run { _ = try await $0.deleteBooking(bookingId: booking.id) } }
                Button("Abbrechen", role: .cancel) {}
            } message: { booking in
                Text("„\(booking.title)“ wird mit Zahlungsplan und Dokumenten entfernt.")
            }
    }

    private func upload(_ url: URL, to booking: Booking) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let type = TripDocument.contentType(forExtension: url.pathExtension), let data = try? Data(contentsOf: url) else {
            run { _ in throw APIError(status: 0, code: "unsupported_file", message: "Diese Datei lässt sich nicht lesen. Möglich sind PDF, Bilder und Text.") }
            return
        }
        guard data.count <= 20_000_000 else {
            run { _ in throw APIError(status: 0, code: "too_large", message: "Die Datei ist größer als 20 MB.") }
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        run { try await $0.uploadDocument(tripId: tripID, title: title, bookingId: booking.id, contentType: type, data: data) }
    }
}

/// One booking: what, with whom, when, and what it costs.
struct BookingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let booking: Booking?
    let save: (BookingDraft) -> Void

    @State private var kind = BookingKind.accommodation
    @State private var title = ""
    @State private var provider = ""
    @State private var reference = ""
    @State private var status = "planned"
    @State private var hasTimes = false
    @State private var start = Date.now
    @State private var end = Date.now.addingTimeInterval(7 * 86_400)
    @State private var place = ""
    @State private var total = ""
    @State private var canCancel = false
    @State private var cancelUntil = Date.now
    @State private var notes = ""
    @State private var filled = false

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()

    private var totalValid: Bool { total.trimmingCharacters(in: .whitespaces).isEmpty || Format.cents(from: total) != nil }
    private var valid: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && totalValid && (!hasTimes || end >= start) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Art", selection: $kind) { ForEach(BookingKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } }
                    TextField("Bezeichnung", text: $title)
                    TextField("Anbieter (freiwillig)", text: $provider)
                    TextField("Buchungsnummer (freiwillig)", text: $reference)
                    Picker("Stand", selection: $status) {
                        Text("geplant").tag("planned")
                        Text("gebucht").tag("booked")
                        Text("storniert").tag("cancelled")
                    }
                } footer: {
                    if kind == .accommodation && status == "booked" {
                        Text("Mit einer gebuchten Unterkunft geht die Reise in die Phase Vorbereitung.")
                    }
                }
                Section {
                    Toggle("Mit Beginn und Ende", isOn: $hasTimes)
                    if hasTimes {
                        DatePicker("Beginn", selection: $start)
                        DatePicker("Ende", selection: $end)
                    }
                    TextField("Ort (freiwillig)", text: $place)
                } footer: {
                    Text("Zeiten wie auf der Bestätigung, also in der Ortszeit des Reiseziels.")
                }
                Section {
                    TextField("Gesamtpreis in Euro (freiwillig)", text: $total).keyboardType(.decimalPad)
                    Toggle("Kostenlos stornierbar", isOn: $canCancel)
                    if canCancel { DatePicker("Bis", selection: $cancelUntil, displayedComponents: .date) }
                } footer: {
                    if !totalValid { Text("Das ist kein Betrag.").foregroundStyle(.red) }
                }
                Section { TextField("Notizen (freiwillig)", text: $notes, axis: .vertical) }
            }
            .navigationTitle(booking == nil ? "Neue Buchung" : "Buchung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        func text(_ value: String) -> String? {
                            let trimmed = value.trimmingCharacters(in: .whitespaces)
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        save(BookingDraft(kind: kind, title: text(title), provider: text(provider), reference: text(reference), status: status,
                                          startsAt: hasTimes ? Self.stamp.string(from: start) : nil, endsAt: hasTimes ? Self.stamp.string(from: end) : nil,
                                          place: text(place), totalCents: Format.cents(from: total), depositCents: booking?.depositCents,
                                          freeCancellationUntil: canCancel ? Format.isoDay(cancelUntil) : nil, notes: text(notes)))
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        guard !filled, let booking else { filled = true; return }
        filled = true
        kind = booking.kind; title = booking.title; provider = booking.provider ?? ""; reference = booking.reference ?? ""; status = booking.status
        place = booking.place ?? ""; notes = booking.notes ?? ""
        total = booking.totalCents.map { (Decimal($0) / 100).formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "de_DE"))) } ?? ""
        func moment(_ text: String?) -> Date? {
            guard let text else { return nil }
            return Self.stamp.date(from: text.count > 10 ? String(text.prefix(16)) : "\(text)T12:00")
        }
        if let from = moment(booking.startsAt) { hasTimes = true; start = from; end = moment(booking.endsAt) ?? from }
        if let until = booking.freeCancellationUntil.flatMap(Format.day) { canCancel = true; cancelUntil = until }
    }
}

/// One instalment of the payment plan.
struct BookingPaymentEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String, Int, String?, Bool) -> Void

    @State private var label = "Anzahlung"
    @State private var amount = ""
    @State private var hasDue = true
    @State private var due = Date.now
    @State private var refundable = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Vorschlag", selection: $label) {
                        ForEach(["Anzahlung", "Restzahlung", "Kaution", "Endreinigung", "Kurtaxe"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Bezeichnung", text: $label)
                    TextField("Betrag in Euro", text: $amount).keyboardType(.decimalPad)
                    Toggle("Mit Fälligkeit", isOn: $hasDue)
                    if hasDue { DatePicker("Fällig am", selection: $due, displayedComponents: .date) }
                    Toggle("Kommt zurück (Kaution)", isOn: $refundable)
                } footer: {
                    Text("Eine Kaution zählt nicht als Kosten und erscheint nicht in der gemeinsamen Kasse.")
                }
            }
            .navigationTitle("Zahlung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        guard let cents = Format.cents(from: amount) else { return }
                        save(label.trimmingCharacters(in: .whitespaces), cents, hasDue ? Format.isoDay(due) : nil, refundable)
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || Format.cents(from: amount) == nil)
                }
            }
            .onChange(of: label) { if label == "Kaution" { refundable = true } }
        }
    }
}
