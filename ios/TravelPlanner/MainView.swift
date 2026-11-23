import SwiftUI
import TravelPlannerKit

/// Three columns on the iPad (trips, offers, profile), a navigation stack on the iPhone.
struct MainView: View {
    @State private var tripID: String?
    @State var candidateID: String?
    /// Whether the last step between offers went on to the next one, for the direction the new offer comes in from.
    @State var stepForward = true
    @Environment(AppModel.self) var model

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
                CandidateDetailView(candidateID: candidateID, onStep: step) { self.candidateID = nil }
                    .id(candidateID)
                    .transition(.push(from: stepForward ? .trailing : .leading))
            } else {
                ContentUnavailableView("Wähle ein Angebot", systemImage: "house")
            }
        }
        .onChange(of: tripID) { candidateID = nil }
        .modifier(BackgroundReader())
    }
}

extension MainView {
    /// Moves to the next (+1) or previous (-1) offer in the order of the list. False at either end.
    func step(_ delta: Int) -> Bool {
        guard let current = candidateID, let index = model.offerOrder.firstIndex(of: current),
              model.offerOrder.indices.contains(index + delta) else { return false }
        stepForward = delta > 0
        withAnimation(.snappy(duration: 0.25)) { candidateID = model.offerOrder[index + delta] }
        return true
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
    /// The one group whose members and invites are open.
    @State private var managedGroup: ManagedGroup?
    @State private var groups: [TravelGroup] = []
    /// The group a new trip was asked for from its section; nil when asked for from the plus.
    @State private var newTripGroup: String?
    /// The group of the trip opened last, as the likely home of the next new trip.
    @AppStorage("lastGroup") private var lastGroup = ""
    @State private var inviteText = ""
    /// Sections folded shut, as a comma-separated list of their ids, remembered across launches.
    @AppStorage("collapsedGroups") private var collapsedRaw = ""
    @State private var archiveOpen = false
    @State private var deleting: Trip?

    /// One colour per group, so its header and its trips read as one block.
    private static let palette: [Color] = [.teal, .indigo, .orange, .pink, .green, .brown]
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    @ViewBuilder private func groupSection(_ section: TripShelf.Section, color: Color) -> some View {
        Section {
            GroupHeader(section: section, color: color, collapsed: collapsed.contains(section.id),
                        toggle: { toggle(section.id) },
                        manage: section.id == "private" ? nil : { managedGroup = ManagedGroup(id: section.id) },
                        newTrip: { newTripGroup = section.id; showNewTrip = true })
                .listRowSeparator(.hidden)
            if !collapsed.contains(section.id) {
                ForEach(section.trips) { trip in
                    TripRow(trip: trip, color: color).tag(trip.id)
                        .swipeActions { tripActions(trip) }
                        .contextMenu { tripActions(trip) }
                }
                if let list = section.watchlist {
                    HStack(spacing: 10) {
                        Capsule().fill(color.opacity(0.5)).frame(width: 4)
                        Image(systemName: "bookmark").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.id == "private" ? "Meine Merkliste" : "Merkliste der Gruppe").font(.headline)
                            Text((list.candidateCount ?? 0) == 1 ? "1 Angebot" : "\(list.candidateCount ?? 0) Angebote")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .tag(list.id)
                }
                if section.trips.isEmpty && section.watchlist == nil {
                    Text("Noch keine Reise.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .listSectionSpacing(18)
    }

    @ViewBuilder private func archiveSection(_ archived: [Trip]) -> some View {
        Section {
            GroupHeader(section: .init(id: "archive", title: "Archiv", group: nil, trips: archived, watchlist: nil), color: .gray,
                        symbol: "archivebox", collapsed: !archiveOpen, toggle: { archiveOpen.toggle() }, manage: nil, newTrip: nil)
                .listRowSeparator(.hidden)
            if archiveOpen {
                ForEach(archived) { trip in
                    TripRow(trip: trip, color: .gray).tag(trip.id)
                        .swipeActions { tripActions(trip) }
                        .contextMenu { tripActions(trip) }
                }
            }
        }
    }

    /// Archive, bring back and delete, for those who organise the trip.
    @ViewBuilder private func tripActions(_ trip: Trip) -> some View {
        if trip.role == .organizer, !trip.isWatchlist {
            Button("Löschen", systemImage: "trash", role: .destructive) { deleting = trip }
            if trip.status == .archived {
                Button("Zurückholen", systemImage: "tray.and.arrow.up") { upkeep { try await $0.archiveTrip(tripId: trip.id, archived: false) } }.tint(.teal)
            } else {
                Button("Archivieren", systemImage: "archivebox") { upkeep { try await $0.archiveTrip(tripId: trip.id, archived: true) } }.tint(.indigo)
            }
        }
    }

    /// Where the adverts of a trip can be kept when it is deleted: its group's watchlist, or the own one.
    private func watchlist(for trip: Trip) -> Trip? {
        trips.first { $0.isWatchlist && $0.groupId == trip.groupId }
    }

    private func remove(_ trip: Trip, movingTo target: String?) {
        if trip.id == selection { selection = nil }
        upkeep { try await $0.deleteTrip(tripId: trip.id, moveCandidatesTo: target) }
    }

    private func upkeep(_ action: @escaping (any TravelBackend) async throws -> Void) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await action(backend)
                model.dataChanged()
            } catch {
                redeemNote = model.message(for: error)
            }
        }
    }
    @State private var redeemNote: String?

    var body: some View {
        List(selection: $selection) {
            if let hint = model.consentHint {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(hint, systemImage: "hand.raised").font(.footnote)
                        Button("Verstanden") { model.dismissConsentHint() }.font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                    }
                }
            }
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
                    Button("Erneut versuchen", systemImage: "arrow.clockwise") {
                        Task {
                            await load()
                            // The other screens load again too once the server answers.
                            if error == nil { model.dataChanged() }
                        }
                    }
                }
            }
            let shelf = TripShelf(trips: trips, groups: groups)
            ForEach(Array(shelf.sections.enumerated()), id: \.element.id) { index, section in
                groupSection(section, color: Self.palette[index % Self.palette.count])
            }
            if !shelf.archived.isEmpty { archiveSection(shelf.archived) }
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
                    Button("Alle Gruppen", systemImage: "person.3") { showGroups = true }
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
        .sheet(item: $managedGroup) { GroupsView(only: $0.id) }
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
        .confirmationDialog("„\(deleting?.title ?? "Reise")“ löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { trip in
            let count = trip.candidateCount ?? 0
            if count > 0, let list = watchlist(for: trip) {
                Button(trip.groupId == nil ? "Löschen, Angebote auf meine Merkliste" : "Löschen, Angebote in die Merkliste der Gruppe", role: .destructive) {
                    remove(trip, movingTo: list.id)
                }
            }
            Button(count > 0 ? "Alles löschen, auch \(count == 1 ? "das Angebot" : "die \(count) Angebote")" : "Endgültig löschen", role: .destructive) {
                remove(trip, movingTo: nil)
            }
            if trip.status != .archived {
                Button("Stattdessen archivieren") { upkeep { try await $0.archiveTrip(tripId: trip.id, archived: true) } }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { trip in
            Text("Stimmen, Kommentare, Kasse, Buchungen, Listen und Dokumente der Reise werden für alle Mitglieder gelöscht. Das lässt sich nicht rückgängig machen. Auf die Merkliste verschobene Angebote kommen dort als neue an, ohne Stimmen. Im Archiv bliebe alles erhalten.")
        }
        .alert("Hinweis", isPresented: Binding(get: { redeemNote != nil }, set: { if !$0 { redeemNote = nil } })) {
            Button("OK") {}
        } message: {
            Text(redeemNote ?? "")
        }
        .sheet(isPresented: $showNewTrip) {
            NewTripView(groups: groups, preselected: newTripGroup ?? lastGroup, existing: trips) { trip in
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

/// The head of one group in the sidebar: clearly a heading, with what the group holds, and folding on a tap.
private struct GroupHeader: View {
    let section: TripShelf.Section
    let color: Color
    var symbol: String?
    let collapsed: Bool
    let toggle: () -> Void
    /// Opens members and invites; nil where there is nothing to manage.
    let manage: (() -> Void)?
    let newTrip: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: symbol ?? (section.id == "private" ? "person.fill" : "person.3.fill"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(summary), \(collapsed ? "zugeklappt" : "aufgeklappt")")
            if manage != nil || newTrip != nil {
                Menu {
                    if let manage { Button("Gruppe verwalten", systemImage: "person.2.badge.gearshape", action: manage) }
                    if let newTrip { Button(section.id == "private" ? "Neue private Reise" : "Neue Reise in dieser Gruppe", systemImage: "suitcase", action: newTrip) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).accessibilityLabel("\(section.title) verwalten")
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(color.opacity(0.12))
    }

    private var summary: String {
        var parts: [String] = []
        if let members = section.group?.members.count { parts.append(members == 1 ? "1 Mitglied" : "\(members) Mitglieder") }
        parts.append(section.trips.count == 1 ? "1 Reise" : "\(section.trips.count) Reisen")
        return parts.joined(separator: " · ")
    }
}

private struct TripRow: View {
    let trip: Trip
    var color: Color = .clear

    var body: some View {
        HStack(spacing: 10) {
            // The group's colour runs down its trips, so they read as belonging to the heading above.
            Capsule().fill(color.opacity(0.5)).frame(width: 4)
            rowText
        }
    }

    private var rowText: some View {
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

/// Names the group to manage, for the sheet.
struct ManagedGroup: Identifiable {
    var id: String
}
