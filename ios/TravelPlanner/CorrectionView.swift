import SwiftUI
import TravelPlannerKit

/// Corrects what the automatic reading got wrong: the key facts of the offer and the price for the trip.
struct CorrectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let detail: CandidateDetail

    @State private var typed: [String: String] = [:]
    @State private var price = ""
    @State private var periodID = ""
    @State private var unavailable = false
    @State private var trip: TripDetail?
    @State private var filled = false
    @State private var busy = false
    @State private var error: String?

    private var profile: Profile { detail.listing.profile }
    private var changes: [String: PatchValue]? { Correction.changes(from: profile, typed: typed) }
    private var priceCents: Int? { Format.cents(from: price) }
    private var priceValid: Bool { price.trimmingCharacters(in: .whitespaces).isEmpty || priceCents != nil }
    private var canSave: Bool {
        guard let changes, priceValid else { return false }
        return !changes.isEmpty || priceCents != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                Section {
                    ForEach(Correction.fields) { field in
                        LabeledContent {
                            TextField("nicht bekannt", text: Binding(get: { typed[field.key] ?? "" }, set: { typed[field.key] = $0 }))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(field.isNumber ? .decimalPad : .default)
                        } label: {
                            HStack(spacing: 4) {
                                Text(field.label)
                                if profile.isUncertain(field.key) {
                                    Image(systemName: "questionmark.circle").foregroundStyle(.orange).accessibilityLabel("unsicher gelesen")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Eckdaten")
                } footer: {
                    Text(changes == nil ? "Eine Zahl ist nicht lesbar, oder der Titel ist leer."
                                        : "Ein leeres Feld heißt „nicht bekannt“. Was du korrigierst, gilt nicht mehr als unsicher gelesen.")
                        .foregroundStyle(changes == nil ? Color.red : Color.secondary)
                }
                Section {
                    TextField("Gesamtpreis in Euro", text: $price).keyboardType(.decimalPad)
                    if let trip, !trip.dateOptions.isEmpty {
                        Picker("Zeitraum", selection: $periodID) {
                            ForEach(trip.dateOptions) { option in
                                Text(option.label ?? Format.dateRange(option.startDate, option.endDate) ?? "Zeitraum").tag(option.id)
                            }
                        }
                    }
                    Toggle("In diesem Zeitraum nicht verfügbar", isOn: $unavailable)
                } header: {
                    Text("Preis für die Reise")
                } footer: {
                    Text(priceValid ? "Leer lassen, wenn der Preis stimmt. Ein Preis von Hand gilt für den gewählten Zeitraum und die Personenzahl der Reise, bis ein neuerer erfasst wird."
                                    : "Das ist kein Betrag.")
                        .foregroundStyle(priceValid ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern") { save() }.disabled(!canSave || busy) }
            }
            .task {
                guard !filled else { return }
                filled = true
                for field in Correction.fields { typed[field.key] = Correction.text(field, in: profile) }
                trip = try? await model.backend?.trip(detail.candidate.tripId)
                periodID = trip?.dateOptions.first?.id ?? ""
            }
        }
    }

    private func save() {
        guard let backend = model.backend, let changes else { return }
        let id = detail.candidate.id
        let period = trip?.dateOptions.first { $0.id == periodID }
        let manual = priceCents.map {
            ManualPrice(totalCents: $0, startDate: period?.startDate, endDate: period?.endDate, persons: trip.map { max(1, $0.trip.persons) },
                        available: unavailable ? false : nil)
        }
        busy = true
        Task {
            do {
                if !changes.isEmpty { try await backend.correctProfile(candidateId: id, changes: changes) }
                if let manual { try await backend.addPrice(candidateId: id, price: manual) }
                model.dataChanged()
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}
