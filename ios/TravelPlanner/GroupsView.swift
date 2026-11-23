import SwiftUI
import TravelPlannerKit

/// The groups of people who travel together: who is in, which trips they share, and how to add someone.
struct GroupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Shows this one group only, when it was opened from the group's own menu.
    var only: String?

    @State private var groups: [TravelGroup]?
    @State private var invite: Invite?
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var leaving: TravelGroup?
    @State private var removing: (group: TravelGroup, member: TravelGroup.Member)?
    @State private var renaming: TravelGroup?
    @State private var renameText = ""
    /// Open invite links by group, for those who manage it.
    @State private var invites: [String: [GroupInvite]] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if let groups {
                    if groups.isEmpty {
                        Section {
                            Text("Du bist in keiner Gruppe. In einer Gruppe sehen alle Mitglieder jede Reise der Gruppe, ohne einzeln eingeladen zu werden.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(groups.filter { only == nil || $0.id == only }) { group in section(group) }
                    if only == nil {
                    Section {
                        Button("Neue Gruppe anlegen", systemImage: "plus") { naming = true }
                    } footer: {
                        Text("Wer einer Gruppe beitritt, wird Mitglied aller ihrer Reisen. Eine neue Reise landet von selbst in deiner Gruppe, wenn du in genau einer bist.")
                    }
                    }
                } else if error == nil {
                    Section { HStack { ProgressView(); Text("Lade die Gruppen …").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle(only.flatMap { id in groups?.first { $0.id == id }?.name } ?? "Gruppen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { run { try await $0.groups() } }
            .sheet(item: $invite) { InviteSheet(invite: $0) }
            .alert("Neue Gruppe", isPresented: $naming) {
                TextField("Name der Gruppe", text: $newName)
                Button("Abbrechen", role: .cancel) { newName = "" }
                Button("Anlegen") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    if !name.isEmpty { run { try await $0.createGroup(name: name) } }
                }
            }
            .alert("Mitglied entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { pair in
                Button("Entfernen", role: .destructive) { run { try await $0.removeGroupMember(groupId: pair.group.id, userId: pair.member.id) } }
                Button("Abbrechen", role: .cancel) {}
            } message: { pair in
                Text("\(pair.member.name) verliert sofort den Zugang zu allen Reisen und zur Merkliste von „\(pair.group.name)“, außer zu selbst angelegten Reisen. Stimmen und Kommentare bleiben stehen.")
            }
            .alert("Gruppe umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { group in
                TextField("Name der Gruppe", text: $renameText)
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { run { try await $0.renameGroup(groupId: group.id, name: name) }; model.dataChanged() }
                }
            }
            .alert("Gruppe verlassen?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), presenting: leaving) { group in
                Button("Verlassen", role: .destructive) {
                    guard let me = model.user?.id else { return }
                    run { try await $0.removeGroupMember(groupId: group.id, userId: me) }
                    model.dataChanged()
                    if only != nil { dismiss() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { group in
                Text("Du verlierst den Zugang zu den Reisen von „\(group.name)“, außer zu denen, die du selbst angelegt hast.")
            }
        }
    }

    private func section(_ group: TravelGroup) -> some View {
        Section {
            if group.isAdmin {
                Button("Gruppe umbenennen", systemImage: "pencil") { renameText = group.name; renaming = group }
            }
            ForEach(group.members) { member in
                let me = member.id == model.user?.id
                if group.isAdmin, !me {
                    // Everything that can be done with a member, behind one tap on the row.
                    Menu {
                        Button(member.isAdmin ? "Verwaltung entziehen" : "Mitverwalten lassen", systemImage: "key") {
                            run { try await $0.setGroupRole(groupId: group.id, userId: member.id, admin: !member.isAdmin) }
                        }
                        Button("Aus der Gruppe entfernen", systemImage: "person.badge.minus", role: .destructive) { removing = (group, member) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name).foregroundStyle(.primary)
                                if let joined = member.joinedAt { Text("dabei seit \(joined.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_DE"))))").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(member.isAdmin ? "verwaltet" : "Mitglied").font(.footnote).foregroundStyle(.secondary)
                            Image(systemName: "ellipsis.circle").foregroundStyle(.tint)
                        }
                    }
                } else {
                    HStack {
                        Text(me ? "\(member.name) (du)" : member.name)
                        Spacer()
                        Text(member.isAdmin ? "verwaltet" : "Mitglied").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if group.isAdmin {
                Button("Mitglied hinzufügen", systemImage: "person.badge.plus") { makeInvite(group) }
                ForEach(invites[group.id] ?? []) { open in
                    HStack {
                        Image(systemName: "envelope").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Offene Einladung")
                            Text(open.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Zurückziehen", role: .destructive) { revoke(open, in: group) }.buttonStyle(.borderless).font(.footnote)
                    }
                }
            }
            if !group.trips.isEmpty {
                LabeledContent(group.trips.count == 1 ? "1 Reise" : "\(group.trips.count) Reisen", value: group.trips.map(\.title).joined(separator: ", "))
            }
            Button("Gruppe verlassen", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = group }
        } header: {
            Text(only == nil ? group.name : "Mitglieder")
        } footer: {
            if group.isAdmin {
                Text("„Mitglied hinzufügen“ erzeugt einen Einladungslink für eine Person. Tippe ein Mitglied an, um es mitverwalten zu lassen oder zu entfernen.")
            }
        }
    }

    private func makeInvite(_ group: TravelGroup) {
        guard let backend = model.backend else { return }
        Task {
            do { invite = try await backend.createGroupInvite(groupId: group.id); error = nil } catch { self.error = model.message(for: error) }
            await loadInvites()
        }
    }

    private func revoke(_ open: GroupInvite, in group: TravelGroup) {
        guard let backend = model.backend else { return }
        Task {
            do { try await backend.revokeGroupInvite(groupId: group.id, inviteId: open.id); error = nil } catch { self.error = model.message(for: error) }
            await loadInvites()
        }
    }

    private func loadInvites() async {
        guard let backend = model.backend else { return }
        for group in groups ?? [] where group.isAdmin {
            if let open = try? await backend.groupInvites(groupId: group.id) { invites[group.id] = open }
        }
    }

    private func run(_ action: @escaping (any TravelBackend) async throws -> [TravelGroup]) {
        guard let backend = model.backend else { return }
        Task {
            do {
                groups = try await action(backend)
                error = nil
                await loadInvites()
            } catch let error as APIError where error.status == 404 && groups == nil {
                self.error = "Der Server kennt noch keine Gruppen. Das kommt mit seinem nächsten Update."
            } catch {
                self.error = model.message(for: error)
            }
        }
    }
}

/// Reads adverts that only a device can read, out of sight and without being asked, wherever in the app the person is.
/// The full page with up to the usual number of photos and the reviews. A page that asks "bot or human?" is left
/// for the person: the advert stays marked "Details fehlen noch" and can be opened by hand.
struct BackgroundReader: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = WebPage()
    @State private var running = false
    /// Tried since the app started, so a page that cannot be read is not tried over and over.
    @State private var tried: Set<String> = []
    /// The pass for sharper photos has run since the app started.
    @State private var sharpened = false
    /// The adverts read again only for sharper photos.
    @State private var sharpening: Set<String> = []

    func body(content: Content) -> some View {
        content
            // The page has to be part of the screen to load like a real one; it sits behind everything, unseen.
            .background {
                WebViewContainer(webView: page.webView)
                    .frame(width: 390, height: 800)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear(perform: start)
            .onChange(of: model.revision) { start() }
            .onChange(of: scenePhase) { if scenePhase == .active { start() } }
    }

    /// Check24 offers this device has read again once since the reading learned to take the data from the desktop
    /// page and the pictures from the phone page. Earlier readings brought either small pictures or little data.
    private static let rereadKey = "check24RereadTwoPages"

    /// Check24 offers on any own trip that this device has not yet read again, with the page to read them from.
    /// At most twenty per start of the app.
    private func blurry(_ backend: any TravelBackend) async -> [PendingReading] {
        let done = Set(UserDefaults.standard.stringArray(forKey: Self.rereadKey) ?? [])
        var found: [PendingReading] = []
        for trip in ((try? await backend.trips()) ?? []) where trip.status != .archived {
            for offer in ((try? await backend.candidates(tripId: trip.id)) ?? []) where offer.listing.platforms.contains("check24") {
                guard found.count < 20 else { return found }
                guard !done.contains(offer.id), let address = try? await backend.candidate(offer.id).sources.first?.url else { continue }
                found.append(PendingReading(candidateId: offer.id, tripId: trip.id, platform: "check24", title: offer.listing.title, url: address))
                sharpening.insert(offer.id)
            }
        }
        return found
    }

    private func rereadDone(_ id: String) {
        var done = UserDefaults.standard.stringArray(forKey: Self.rereadKey) ?? []
        if !done.contains(id) { done.append(id); UserDefaults.standard.set(done, forKey: Self.rereadKey) }
    }

    private func start() {
        guard !running, !model.isDemo, let backend = model.backend else { return }
        running = true
        Task {
            defer { running = false }
            let pending = (try? await backend.pendingReadings()) ?? []
            var fresh = pending.filter { !tried.contains($0.candidateId) }
            // Then adverts whose photos are only previews, once per start of the app: their gallery is read again,
            // so the sharp versions arrive without anyone asking.
            if !sharpened {
                sharpened = true
                fresh += await blurry(backend).filter { advert in !tried.contains(advert.candidateId) && !fresh.contains { $0.candidateId == advert.candidateId } }
            }
            guard !fresh.isEmpty else { return }
            var sent = 0
            for advert in fresh {
                tried.insert(advert.candidateId)
                guard let url = URL(string: advert.url) else { continue }
                page.load(url)
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !page.isLoading { break }
                }
                try? await Task.sleep(for: .seconds(2))
                let platform = advert.platform ?? "?"
                if await page.isChallenge() {
                    WebPage.log.info("Neues Inserat \(platform, privacy: .public): Sicherheitsabfrage, bleibt für die Person")
                    continue
                }
                if await page.isConsentWall() {
                    WebPage.log.info("Hintergrund \(platform, privacy: .public): Cookie-Abfrage vor dem Inserat, nichts gesendet")
                    model.askForConsent(platform: advert.platform)
                    continue
                }
                guard let captured = try? await page.capture(maxPictures: WebPage.usualPictures), captured.html.count >= 500 else { continue }
                if await page.isChallenge() { continue }
                // A reading only for sharper photos is worth sending when it brought photos; a page behind a
                // consent or sign-in wall would bring none.
                if sharpening.contains(advert.candidateId), captured.pictures < 5 {
                    WebPage.log.info("Bilder neu einlesen \(platform, privacy: .public): nur \(captured.pictures) Bilder, nicht gesendet")
                    continue
                }
                do {
                    try await backend.capture(candidateId: advert.candidateId, html: captured.html, sourceId: nil, forTrip: false, url: page.advertURL ?? advert.url, dateOptionId: nil)
                    WebPage.log.info("Neues Inserat \(platform, privacy: .public): \(captured.pictures) Bilder, \(captured.reviews) Bewertungen gesendet")
                    sent += 1
                    if sharpening.contains(advert.candidateId) { rereadDone(advert.candidateId) }
                } catch {
                    if let api = error as? APIError, api.isUnauthorized || api.code == "daily_limit" { break }
                }
            }
            page.load(URL(string: "about:blank")!)
            // Only now: the change makes the lists reload, and that must not start this run again halfway.
            if sent > 0 { model.dataChanged() }
        }
    }
}

/// The stays known for one advert on a trip with a flexible window, and a way to ask for another one.
struct StaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidateID: String
    let tripID: String
    /// Opens the advert's page for the stay, when only a device can read it.
    let open: (_ url: String, _ start: String, _ end: String) -> Void

    @State private var trip: Trip?
    @State private var stays: [Stay] = []
    @State private var start = Date.now
    @State private var nights = 7
    @State private var note: String?
    @State private var error: String?
    @State private var busy = false
    @State private var loaded = false

    private var window: FlexWindow? { trip?.flexWindow }
    private var end: Date { Calendar.current.date(byAdding: .day, value: nights, to: start) ?? start }
    private var fits: Bool { window?.holds(start: Format.isoDay(start), end: Format.isoDay(end)) ?? true }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if let window {
                    Section {
                        Text(window.summary).foregroundStyle(.secondary)
                    } header: {
                        Text("Zeitfenster der Reise")
                    }
                }
                Section {
                    if stays.isEmpty { Text(loaded ? "Noch kein Aufenthalt geprüft." : "Lade …").foregroundStyle(.secondary) }
                    ForEach(stays) { stay in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.dateRange(stay.startDate, stay.endDate) ?? stay.startDate)
                                Text([stay.nights.map { $0 == 1 ? "1 Nacht" : "\($0) Nächte" },
                                      stay.available == false ? "belegt" : nil, stay.best == true ? "bester Preis je Nacht" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(stay.available == false ? Color.red : Color.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let total = stay.totalCents { Text(Format.euro(cents: total)).font(.body.weight(stay.best == true ? .semibold : .regular)) }
                                if let night = stay.perNightCents { Text("\(Format.euro(cents: night)) je Nacht").font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Geprüfte Aufenthalte")
                }
                let open = (trip?.stayVariants ?? []).filter { variant in !stays.contains { $0.id == variant.id } }
                if !open.isEmpty {
                    Section {
                        ForEach(open) { variant in
                            Button {
                                if let day = Format.day(variant.startDate) { start = day }
                                if let count = variant.nights { nights = count }
                            } label: {
                                LabeledContent(Format.dateRange(variant.startDate, variant.endDate) ?? variant.startDate,
                                               value: variant.nights.map { $0 == 1 ? "1 Nacht" : "\($0) Nächte" } ?? "")
                            }
                        }
                    } header: {
                        Text("Vorschläge im Zeitfenster")
                    } footer: {
                        Text("Tippe einen Vorschlag an, um ihn unten zu übernehmen, und prüfe ihn dann.")
                    }
                }
                Section {
                    DatePicker("Anreise", selection: $start, displayedComponents: .date)
                    Stepper("Nächte: \(nights)", value: $nights, in: (window?.nightsMin ?? 1)...(window?.nightsMax ?? 28))
                    LabeledContent("Abreise", value: end.formatted(.dateTime.weekday(.abbreviated).day().month().year().locale(Locale(identifier: "de_DE"))))
                    Button(busy ? "Frage an …" : "Diesen Aufenthalt prüfen", systemImage: "magnifyingglass", action: check)
                        .disabled(busy || !fits)
                } header: {
                    Text("Anderen Zeitraum prüfen")
                } footer: {
                    Text(fits ? (note ?? "Die App fragt Preis und Verfügbarkeit für genau diese Daten ab. Bei Plattformen, die den Server abweisen, öffnet sich dafür kurz das Inserat.")
                              : "Dieser Aufenthalt liegt nicht im Zeitfenster der Reise.")
                        .foregroundStyle(fits ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Zeiträume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task(id: model.revision) { await load() }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            async let one = backend.trip(tripID)
            async let two = backend.candidates(tripId: tripID)
            let (detail, list) = try await (one, two)
            trip = detail.trip
            stays = (list.first { $0.id == candidateID }?.stays ?? []).sorted { $0.startDate < $1.startDate }
            if !loaded, let window = detail.trip.flexWindow {
                start = Format.day(window.start) ?? start
                nights = min(window.nightsMax, max(window.nightsMin, (window.nightsMin + window.nightsMax) / 2))
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
        loaded = true
    }

    private func check() {
        guard let backend = model.backend else { return }
        let from = Format.isoDay(start), to = Format.isoDay(end)
        busy = true
        Task {
            do {
                let result = try await backend.checkStay(tripId: tripID, candidateId: candidateID, startDate: from, endDate: to)
                error = nil
                if let check = result.checks.first, check.wantsDevice, let url = check.checkUrl {
                    dismiss()
                    open(url, from, to)
                } else {
                    note = "Der Server fragt diesen Aufenthalt jetzt ab. Das Ergebnis erscheint hier in etwa einer Minute."
                    try? await Task.sleep(for: .seconds(20))
                    model.dataChanged()
                }
            } catch {
                self.error = model.message(for: error)
            }
            busy = false
        }
    }
}
