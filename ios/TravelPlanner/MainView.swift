import SwiftUI
import TravelPlannerKit

/// Three columns on the iPad (trips, offers, profile), a navigation stack on the iPhone.
struct MainView: View {
    @State private var tripID: String?
    @State private var candidateID: String?

    var body: some View {
        NavigationSplitView {
            TripListView(selection: $tripID)
        } content: {
            if let tripID {
                CandidateListView(tripID: tripID, selection: $candidateID)
                    .id(tripID)
            } else {
                ContentUnavailableView("Wähle eine Reise", systemImage: "suitcase")
            }
        } detail: {
            if let candidateID {
                CandidateDetailView(candidateID: candidateID) { self.candidateID = nil }
                    .id(candidateID)
            } else {
                ContentUnavailableView("Wähle ein Angebot", systemImage: "house")
            }
        }
        .onChange(of: tripID) { candidateID = nil }
        .modifier(BackgroundReader())
    }
}

struct TripListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    @State private var trips: [Trip] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showNewTrip = false
    @State private var showSettings = false
    @State private var showRedeem = false
    @State private var showGroups = false
    @State private var inviteText = ""
    @State private var redeemNote: String?

    var body: some View {
        List(selection: $selection) {
            if model.isDemo {
                Section {
                    Label("Beispieldaten. Nichts davon wird gespeichert.", systemImage: "theatermasks")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                }
            }
            Section {
                ForEach(trips.filter { $0.status != .archived && !$0.isWatchlist }) { trip in
                    TripRow(trip: trip).tag(trip.id)
                }
            }
            let watchlists = trips.filter(\.isWatchlist)
            if !watchlists.isEmpty {
                Section {
                    ForEach(watchlists) { trip in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trip.title).font(.headline)
                                Text((trip.candidateCount ?? 0) == 1 ? "1 Angebot" : "\(trip.candidateCount ?? 0) Angebote")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bookmark")
                        }
                        .tag(trip.id)
                    }
                }
            }
            let archived = trips.filter { $0.status == .archived && !$0.isWatchlist }
            if !archived.isEmpty {
                Section("Archiv") {
                    ForEach(archived) { trip in TripRow(trip: trip).tag(trip.id) }
                }
            }
        }
        .overlay {
            if loaded && trips.filter({ !$0.isWatchlist }).isEmpty && error == nil && trips.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Reise", systemImage: "suitcase")
                } description: {
                    Text("Lege eine Reise an und sammle Angebote über das Teilen-Menü.")
                } actions: {
                    Button("Reise anlegen") { showNewTrip = true }
                }
            }
        }
        .navigationTitle("Reisen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reise anlegen", systemImage: "suitcase") { showNewTrip = true }
                    Button("Einladung einlösen", systemImage: "envelope.open") { showRedeem = true }
                    Button("Gruppen", systemImage: "person.3") { showGroups = true }
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showGroups) { GroupsView() }
        .alert("Einladung einlösen", isPresented: $showRedeem) {
            TextField("https://…/einladung/…", text: $inviteText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Abbrechen", role: .cancel) { inviteText = "" }
            Button("Einlösen") { redeem() }
        } message: {
            Text("Füge den Einladungslink ein, den du für eine weitere Reise bekommen hast. Du bleibst mit deinem Konto angemeldet.")
        }
        .alert("Einladung", isPresented: Binding(get: { redeemNote != nil }, set: { if !$0 { redeemNote = nil } })) {
            Button("OK") {}
        } message: {
            Text(redeemNote ?? "")
        }
        .sheet(isPresented: $showNewTrip) {
            NewTripView { trip in
                model.dataChanged()
                selection = trip.id
            }
        }
        .refreshable { await load() }
        .task(id: model.revision) { await load() }
    }

    private func redeem() {
        let text = inviteText
        inviteText = ""
        Task {
            do {
                let result = try await model.redeem(inviteText: text)
                await load()
                if let trip = result.tripID { selection = trip }
                else { redeemNote = result.joinedGroup ? "Du bist der Gruppe beigetreten. Ihre Reisen stehen jetzt in deiner Liste." : "Die Einladung ist eingelöst." }
            } catch {
                redeemNote = model.message(for: error)
            }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            trips = try await backend.trips()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
        loaded = true
    }
}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title).font(.headline)
            if let region = trip.region, !region.isEmpty {
                Text(region).font(.subheadline).foregroundStyle(.secondary)
            }
            if let window = trip.flexWindow {
                Text(window.summary).font(.footnote).foregroundStyle(.secondary)
            }
            Text(progress).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var progress: String {
        let count = trip.candidateCount ?? 0
        let favorites = trip.favoriteCount ?? 0
        var parts = [count == 1 ? "1 Angebot" : "\(count) Angebote"]
        if favorites > 0 { parts.append(favorites == 1 ? "1 Favorit" : "\(favorites) Favoriten") }
        parts.append("\(trip.persons) Personen")
        if let group = trip.groupName, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " · ")
    }
}
