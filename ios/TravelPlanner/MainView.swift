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
    @State private var groups: [TravelGroup] = []
    /// The group a new trip was asked for from its section; nil when asked for from the plus.
    @State private var newTripGroup: String?
    /// The group of the trip opened last, as the likely home of the next new trip.
    @AppStorage("lastGroup") private var lastGroup = ""
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
            let shelf = TripShelf(trips: trips, groups: groups)
            ForEach(shelf.sections) { section in
                Section {
                    ForEach(section.trips) { trip in TripRow(trip: trip).tag(trip.id) }
                    if let list = section.watchlist {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.group == nil && section.id == "private" ? "Meine Merkliste" : "Merkliste der Gruppe").font(.headline)
                                Text((list.candidateCount ?? 0) == 1 ? "1 Angebot" : "\(list.candidateCount ?? 0) Angebote")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bookmark")
                        }
                        .tag(list.id)
                    }
                    if section.trips.isEmpty && section.watchlist == nil {
                        Text("Noch keine Reise.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Label(section.title, systemImage: section.id == "private" ? "person" : "person.3")
                        Spacer()
                        if section.id != "private" {
                            Menu {
                                Button("Mitglieder und Einladungen", systemImage: "person.2") { showGroups = true }
                                Button("Neue Reise in dieser Gruppe", systemImage: "suitcase") { newTripGroup = section.id; showNewTrip = true }
                            } label: {
                                Image(systemName: "ellipsis.circle").accessibilityLabel("\(section.title) verwalten")
                            }
                        }
                    }
                    .textCase(nil)
                }
            }
            if !shelf.archived.isEmpty {
                Section("Archiv") {
                    DisclosureGroup(shelf.archived.count == 1 ? "1 abgeschlossene Reise" : "\(shelf.archived.count) abgeschlossene Reisen") {
                        ForEach(shelf.archived) { trip in TripRow(trip: trip).tag(trip.id) }
                    }
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
                    Button("Reise anlegen", systemImage: "suitcase") { newTripGroup = nil; showNewTrip = true }
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
            NewTripView(groups: groups, preselected: newTripGroup ?? lastGroup) { trip in
                model.dataChanged()
                selection = trip.id
            }
        }
        .refreshable { await load() }
        .task(id: model.revision) { await load() }
        .onChange(of: selection) {
            if let trip = trips.first(where: { $0.id == selection }) { lastGroup = trip.groupId ?? "private" }
        }
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
            // Groups are an extra: a server without them still shows the trips.
            groups = (try? await backend.groups()) ?? []
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
        return parts.joined(separator: " · ")
    }
}
