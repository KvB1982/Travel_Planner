import SwiftUI
import TravelPlannerKit

/// Picks where an offer goes: another trip, or the watchlist.
struct MoveOfferView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidateID: String
    let title: String
    /// The trip the offer is in now; it is not offered as a destination.
    let currentTripID: String
    /// Called with the destination after the move went through.
    var onMoved: (Trip) -> Void

    @State private var trips: [Trip] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    private var destinations: [Trip] {
        trips.filter { $0.id != currentTripID && $0.status != .archived && $0.role != .guest }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                let lists = destinations.filter(\.isWatchlist)
                if !lists.isEmpty {
                    Section {
                        ForEach(lists) { trip in row(trip, symbol: "bookmark") }
                    } footer: {
                        Text("Auf der Merkliste bleibt das Angebot für später erhalten, ohne zu einer Reise zu gehören.")
                    }
                }
                Section("Reisen") {
                    ForEach(destinations.filter { !$0.isWatchlist }) { trip in row(trip, symbol: "suitcase") }
                    if loaded && destinations.filter({ !$0.isWatchlist }).isEmpty {
                        Text("Es gibt keine andere Reise, in die du Angebote legen kannst.").foregroundStyle(.secondary)
                    }
                }
                Section {
                } footer: {
                    Text("Kommentare, Notizen, Bilder und Bewertungen ziehen mit um. Stimmen und der für diese Reise abgefragte Preis bleiben zurück, weil sie für die neue Reise nicht gelten.")
                }
            }
            .overlay { if !loaded || busy { ProgressView() } }
            .navigationTitle("„\(title)“ verschieben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { trips = try await model.backend?.trips() ?? [] } catch { self.error = model.message(for: error) }
            loaded = true
        }
    }

    private func row(_ trip: Trip, symbol: String) -> some View {
        Button {
            move(to: trip)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.title).foregroundStyle(.primary)
                    if let region = trip.region, !region.isEmpty { Text(region).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .disabled(busy)
    }

    private func move(to trip: Trip) {
        guard let backend = model.backend else { return }
        busy = true
        error = nil
        Task {
            do {
                _ = try await backend.move(candidateId: candidateID, toTrip: trip.id)
                model.dataChanged()
                onMoved(trip)
                dismiss()
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}
