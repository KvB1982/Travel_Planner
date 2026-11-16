import OSLog
import SwiftUI
import TravelPlannerKit

struct CandidateListView: View {
    @Environment(AppModel.self) private var model
    let tripID: String
    @Binding var selection: String?

    @State private var detail: TripDetail?
    @State private var candidates: [CandidateSummary] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var filter: CandidateStatus?
    /// Shows only offers of one country; nil shows all.
    @State private var country: String?
    @State private var showAddLink = false
    @State private var link = ""
    @State private var invite: Invite?
    @State private var notice: String?
    @State private var pendingDelete: CandidateSummary?
    @State private var moving: CandidateSummary?
    @State private var showCompare = false
    @State private var showPresentation = false
    @State private var showCriteria = false
    @State private var showLedger = false
    @State private var framingSheet: FramingSheet?
    @State private var bookingRequests = BookingRequests()
    @State private var planSheet: PlanSheet?
    @State private var houseEditing: HouseBook?
    @State private var removingPeriod: DateOption?
    /// The phase whose surface is shown; follows the trip until someone picks another.
    @State private var viewedPhase: TripPhase = .research
    @State private var phasePicked = false
    @AppStorage("offerSort") private var sortRaw = OfferSort.added.rawValue
    @State private var onlyAvailable = false
    /// The period that prices and availability refer to; nil means the earliest of the trip.
    @State private var periodID: String?
    @State private var showMap = false
    /// "2 von 5" while all offers are being checked; nil otherwise.
    @State private var checking: String?
    @State private var confirmCheck = false
    @AppStorage(Settings.showCheckRun) private var showCheckRun = false
    /// The web page used to read adverts out of sight during a check.
    @State private var hiddenPage = WebPage()
    /// Adverts still to be read on this device during a check of the whole trip.
    @State private var deviceQueue: [TripCheck.Check] = []
    @State private var deviceTotal = 0
    /// How many of them were actually read and sent; the rest were cancelled.
    @State private var deviceDone = 0
    /// Offers whose page went to the server a moment ago: when it was sent. Until the server has read it,
    /// the list says so instead of showing the old state as if nothing had happened.
    @State private var evaluating: [String: Date] = [:]
    @State private var deviceCheck: TripCheck.Check?
    /// Adverts the hidden run could not read because the site wants a person; shown once the summary is closed.
    @State private var pendingVisible: [TripCheck.Check] = []

    private var sort: OfferSort { OfferSort(rawValue: sortRaw) ?? .added }

    private var visible: [CandidateSummary] {
        sort.sorted(candidates.filter { candidate in
            if let country, OfferGrouping.country(of: candidate) != country { return false }
            if onlyAvailable && candidate.isUnavailable { return false }
            if let filter { return candidate.status == filter }
            return candidate.status != .rejected
        })
    }

    /// What the presentation walks through: the offers on screen that are still in the running.
    private var presentable: [CandidateSummary] {
        visible.filter { !$0.isUnavailable && $0.importStatus != .pending }
    }

    private var countries: [String] { OfferGrouping.countries(in: candidates) }

    @ViewBuilder
    private func row(_ candidate: CandidateSummary) -> some View {
        CandidateRow(candidate: candidate, persons: detail?.trip.persons, evaluating: evaluating[candidate.id] != nil).tag(candidate.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if detail?.role.canEdit ?? false {
                    // Not `role: .destructive`: the row must stay until the question is answered.
                    Button("Löschen", systemImage: "trash") { pendingDelete = candidate }.tint(.red)
                    Button("Verschieben", systemImage: "arrow.right.doc.on.clipboard") { moving = candidate }.tint(.indigo)
                }
            }
    }

    /// Status and country, side by side above the offers. The country menu only appears when there is a choice.
    private var filters: some View {
        HStack(spacing: 16) {
            Picker("Status", selection: $filter) {
                Text("Alle offenen").tag(CandidateStatus?.none)
                ForEach(CandidateStatus.allCases, id: \.self) { status in
                    Text(status.label).tag(CandidateStatus?.some(status))
                }
            }
            .fixedSize()
            if countries.count > 1 {
                Picker("Land", selection: $country) {
                    Text("Alle Länder").tag(String?.none)
                    ForEach(countries, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
            }
            Spacer()
            Menu {
                Picker("Sortieren", selection: $sortRaw) {
                    ForEach(OfferSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Nur verfügbare zeigen", isOn: $onlyAvailable)
            } label: {
                Label("Sortieren und filtern", systemImage: sort == .added && !onlyAvailable ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
            }
        }
        .pickerStyle(.menu)
        .textCase(nil)
    }

    /// Everything but the research: each phase brings its own sections.
    @ViewBuilder private func otherPhase(_ detail: TripDetail) -> some View {
        switch viewedPhase {
        case .decision:
            PitchSections(tripID: tripID, role: detail.role, candidates: candidates, persons: detail.trip.persons, selection: $selection)
        case .framing:
            FramingSections(detail: detail, showCriteria: { showCriteria = true }, invite: { createInvite() },
                            showLedger: { showLedger = true }, sheet: $framingSheet, removing: $removingPeriod)
        case .booking:
            BookingSections(detail: detail, candidates: candidates, requests: $bookingRequests)
        case .preparation:
            PreparationSections(detail: detail, sheet: $planSheet)
        case .travelling:
            TravellingSections(detail: detail, editing: $houseEditing, showLedger: { showLedger = true })
        default:
            PhasePlaceholder(phase: viewedPhase)
        }
    }

    var body: some View {
        List(selection: $selection) {
            if let detail, !detail.trip.isWatchlist {
                Section {
                    PhaseBar(trip: detail.trip, viewed: Binding(get: { viewedPhase }, set: { viewedPhase = $0; phasePicked = true }),
                             setPhase: detail.role == .organizer ? { phase in setPhase(phase) } : nil)
                }
                .listSectionSpacing(.compact)
            }
            if let detail, viewedPhase != .research, !detail.trip.isWatchlist {
                otherPhase(detail)
            } else {
            if let detail {
                Section {
                    TripHeader(detail: detail)
                    if detail.dateOptions.count > 1 {
                        // Prices, availability and the check refer to the period chosen here.
                        Picker("Zeitraum", selection: $periodID) {
                            ForEach(Array(detail.dateOptions.enumerated()), id: \.element.id) { index, option in
                                Text(option.label ?? Format.dateRange(option.startDate, option.endDate) ?? "Zeitraum \(index + 1)")
                                    .tag(index == 0 ? String?.none : String?.some(option.id))
                            }
                        }
                    }
                    if detail.role.canEdit && !candidates.isEmpty && !detail.trip.isWatchlist {
                        Button {
                            confirmCheck = true
                        } label: {
                            if let checking {
                                HStack(spacing: 10) { ProgressView(); Text("Prüfe \(checking) …") }
                            } else {
                                Label("Verfügbarkeit und Preise prüfen", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(checking != nil)
                    }
                }
            }
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
            }
            let groups = OfferGrouping.groups(visible)
            if groups.count > 1 {
                // Searching in several countries or regions at once: one section each.
                if !candidates.isEmpty {
                    Section { EmptyView() } header: { filters }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.offers) { row($0) }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.offers.count)").foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                    }
                }
            } else {
                Section {
                    ForEach(visible) { row($0) }
                    if visible.isEmpty && !candidates.isEmpty {
                        Text("Kein Angebot passt zu dieser Auswahl.").foregroundStyle(.secondary)
                    }
                } header: {
                    if !candidates.isEmpty { filters }
                }
            }
            if let detail, detail.role == .organizer, !detail.trip.isWatchlist, candidates.count >= 2 {
                Section {
                    Button("Weiter zur Entscheidung", systemImage: "trophy") {
                        viewedPhase = .decision
                        phasePicked = true
                    }
                } footer: {
                    Text("Dort wählst du die Finalisten aus, und die Gruppe bringt sie in eine Rangfolge.")
                }
            }
            }
        }
        .overlay {
            if loaded && candidates.isEmpty && error == nil && viewedPhase == .research {
                ContentUnavailableView {
                    Label("Noch keine Angebote", systemImage: "square.and.arrow.up")
                } description: {
                    Text("Öffne ein Inserat in Safari oder in der App der Plattform, tippe auf Teilen und wähle Travel Planner.")
                } actions: {
                    Button("Link einfügen") { showAddLink = true }
                }
            }
        }
        // The hidden page has to be part of the screen to load like a real one; it sits behind the list, unseen.
        .background {
            WebViewContainer(webView: hiddenPage.webView)
                .frame(width: 390, height: 800)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle(detail?.trip.title ?? "Angebote")
        .toolbar {
            if detail?.role.canEdit ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button("Link hinzufügen", systemImage: "plus") { showAddLink = true }
                }
            }
            if !candidates.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Karte", systemImage: "map") { showMap = true }
                }
            }
            if !presentable.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Präsentation", systemImage: "play.rectangle") { showPresentation = true }
                }
            }
            if candidates.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button("Vergleichen", systemImage: "rectangle.split.3x1") { showCompare = true }
                }
            }
            if detail?.role.canEdit ?? false, detail?.trip.isWatchlist != true {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Kriterien", systemImage: "checklist") { showCriteria = true }
                }
            }
            if detail != nil, detail?.trip.isWatchlist != true {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Gemeinsame Kasse", systemImage: "eurosign.circle") { showLedger = true }
                }
            }
            // The watchlist is personal: nobody can be invited to it.
            if detail?.role == .organizer, detail?.trip.isWatchlist != true {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Jemanden einladen", systemImage: "person.badge.plus") { createInvite() }
                }
            }
        }
        .alert("Link hinzufügen", isPresented: $showAddLink) {
            TextField("https://…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Abbrechen", role: .cancel) { link = "" }
            Button("Hinzufügen") { addLink() }
        } message: {
            Text("Adresse eines Inserats, zum Beispiel von Airbnb, FeWo-direkt, Novasol, Check24 oder Casamundo.")
        }
        .alert("Hinweis", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {
                guard !pendingVisible.isEmpty else { return }
                deviceTotal = pendingVisible.count
                deviceQueue = pendingVisible
                pendingVisible = []
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    deviceCheck = deviceQueue.removeFirst()
                }
            }
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog("Angebot löschen?", isPresented: .init(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { candidate in
            Button("Löschen", role: .destructive) { delete(candidate) }
        } message: { candidate in
            Text("„\(candidate.listing.title ?? "Dieses Angebot")“ wird mit allen Stimmen und Kommentaren aus der Reise entfernt. Das lässt sich nicht rückgängig machen.")
        }
        .fullScreenCover(isPresented: $showMap) {
            // Rejected offers stay off the map unless the list is filtered to show them.
            TripMapView(title: detail?.trip.title ?? "Karte", candidates: visible) { selection = $0 }
        }
        .sheet(isPresented: $showCriteria) { CriteriaEditor(tripID: tripID) }
        .sheet(item: $houseEditing) { book in
            HouseEditor(book: book) { changes in frame { _ = try await $0.updateHouse(tripId: tripID, changes: changes) } }
        }
        .modifier(PlanPresenter(tripID: tripID, sheet: $planSheet, run: frame))
        .modifier(BookingPresenter(tripID: tripID, requests: $bookingRequests, run: frame))
        .modifier(FramingPresenter(tripID: tripID, trip: detail?.trip, sheet: $framingSheet, removing: $removingPeriod, run: frame))
        .sheet(isPresented: $showLedger) { LedgerView(tripID: tripID, role: detail?.role ?? .guest, members: detail?.members ?? []) }
        .fullScreenCover(isPresented: $showPresentation) {
            PresentationView(candidates: presentable, persons: detail?.trip.persons)
        }
        .fullScreenCover(isPresented: $showCompare) {
            CompareView(candidates: candidates, persons: detail?.trip.persons)
        }
        // An alert, so both answers are always on screen; a popover would hide "Abbrechen".
        .alert("Verfügbarkeit und Preise prüfen?", isPresented: $confirmCheck) {
            Button("Abbrechen", role: .cancel) {}
            Button("Jetzt prüfen") { checkAll() }
        } message: {
            Text(showCheckRun
                 ? "Alle Angebote werden für den Zeitraum und die Gäste dieser Reise neu abgefragt. Inserate, die der Server nicht lesen kann, öffnet die App danach kurz nacheinander selbst. Das dauert etwa eine Viertelminute je Angebot."
                 : "Alle Angebote werden für den Zeitraum und die Gäste dieser Reise neu abgefragt, im Hintergrund. Du kannst währenddessen weiterarbeiten, die App muss nur geöffnet bleiben. Das dauert etwa eine Viertelminute je Angebot.")
        }
        .sheet(item: $deviceCheck, onDismiss: nextDeviceCheck) { check in
            let url = check.checkUrl ?? ""
            CaptureView(source: ListingSource(id: check.candidateId, platform: check.platform ?? "other", url: url, canonicalUrl: url),
                        candidateID: check.candidateId, forTrip: true, dateOptionID: periodID, automatic: true,
                        progressLabel: "\(deviceTotal - deviceQueue.count) von \(deviceTotal)") { _, _ in deviceDone += 1; evaluating[check.candidateId] = .now; model.dataChanged() }
        }
        .sheet(item: $moving) { candidate in
            MoveOfferView(candidateID: candidate.id, title: candidate.listing.title ?? "Angebot", currentTripID: tripID) { _ in
                if selection == candidate.id { selection = nil }
            }
        }
        .sheet(item: $invite) { invite in
            InviteSheet(invite: invite)
        }
        .refreshable { await load() }
        .onChange(of: periodID) { model.dataChanged() }
        .task(id: model.revision) {
            await load()
            // Imports finish in the background on the server; look again until none is pending.
            while !Task.isCancelled, candidates.contains(where: { $0.importStatus == .pending }) || !evaluating.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await load()
                settleEvaluating()
            }
        }
    }

    /// Drops the mark once the server shows a newer price or verdict for the offer, or after a minute and a half.
    private func settleEvaluating() {
        for (id, sent) in evaluating {
            let candidate = candidates.first { $0.id == id }
            let fresh = (candidate?.price?.capturedAt).map { $0 > sent.addingTimeInterval(-5) } ?? false
            if candidate == nil || fresh || Date.now.timeIntervalSince(sent) > 90 { evaluating[id] = nil }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            async let trip = backend.trip(tripID)
            async let list = backend.candidates(tripId: tripID, dateOptionId: periodID)
            (detail, candidates) = try await (trip, list)
            error = nil
            if !phasePicked, let trip = detail?.trip {
                // Open the surface the trip is in; phases without a surface yet fall back to the research.
                viewedPhase = [.framing, .research, .decision, .booking, .preparation, .travelling].contains(trip.activePhase) ? trip.activePhase : .research
            }
        } catch is CancellationError {
        } catch {
            self.error = model.message(for: error)
        }
        loaded = true
    }

    private func addLink() {
        let text = link
        link = ""
        guard let backend = model.backend else { return }
        guard let url = LinkFinder.firstURL(in: text) else {
            notice = "Das ist keine Internetadresse."
            return
        }
        Task {
            do {
                let result = try await backend.importLink(tripId: tripID, url: url.absoluteString, html: nil)
                if result.duplicate { notice = "Dieses Angebot ist schon in der Reise." }
                model.dataChanged()
                selection = result.candidateId
            } catch {
                notice = model.message(for: error)
            }
        }
    }

    private func delete(_ candidate: CandidateSummary) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await backend.delete(candidateId: candidate.id)
                if selection == candidate.id { selection = nil }
                model.dataChanged()
            } catch {
                notice = model.message(for: error)
            }
        }
    }

    /// Has the server check every offer for the trip's dates and party, then reads on this device what the
    /// server cannot see, one advert after the other.
    private func checkAll() {
        guard let backend = model.backend else { return }
        checking = "alle Angebote"
        Task {
            do {
                let result = try await backend.checkTrip(tripId: tripID, dateOptionId: periodID)
                for check in result.checks where check.mode == "server" { evaluating[check.candidateId] = .now }
                model.dataChanged()
                let onDevice = result.checks.filter(\.wantsDevice)
                deviceTotal = onDevice.count
                deviceQueue = onDevice
                let server = result.checks.filter { $0.mode == "server" }.count
                let skipped = result.checks.filter { $0.mode == "skipped" }.count
                if onDevice.isEmpty {
                    var parts = [server == 1 ? "1 Angebot wird vom Server neu abgefragt" : "\(server) Angebote werden vom Server neu abgefragt"]
                    if skipped > 0 { parts.append(skipped == 1 ? "1 wurde eben erst geprüft" : "\(skipped) wurden eben erst geprüft") }
                    notice = parts.joined(separator: ", ") + ". Die Ergebnisse erscheinen in der Liste, sobald der Server fertig ist."
                } else if showCheckRun {
                    deviceCheck = deviceQueue.removeFirst()
                } else {
                    deviceQueue = []
                    await readOutOfSight(onDevice, backend: backend)
                }
            } catch {
                notice = model.message(for: error)
            }
            checking = nil
        }
    }

    /// Reads the adverts one after the other in a web page nobody sees, while the app stays usable.
    /// A page that asks "bot or human?" cannot be answered out of sight: those adverts are shown afterwards.
    private func readOutOfSight(_ checks: [TripCheck.Check], backend: any TravelBackend) async {
        var done = 0, withoutDates = 0, failed = 0
        var needsPerson: [TripCheck.Check] = []
        for (index, check) in checks.enumerated() {
            checking = "\(index + 1) von \(checks.count)"
            guard let address = check.checkUrl, let url = URL(string: address) else { failed += 1; continue }
            hiddenPage.load(url)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if !hiddenPage.isLoading { break }
            }
            try? await Task.sleep(for: .seconds(2))
            let platform = check.platform ?? "?"
            if await hiddenPage.isChallenge() {
                WebPage.log.info("Prüflauf \(platform, privacy: .public): Sicherheitsabfrage")
                needsPerson.append(check); continue
            }
            await hiddenPage.waitForPrice()
            if await hiddenPage.lacksDates() {
                WebPage.log.info("Prüflauf \(platform, privacy: .public): Seite ohne Zeitraum")
                withoutDates += 1; continue
            }
            do {
                let captured = try await hiddenPage.capture(quick: true)
                WebPage.log.info("Prüflauf \(platform, privacy: .public): \(captured.html.count) Zeichen gelesen")
                if await hiddenPage.isChallenge() { needsPerson.append(check); continue }
                guard captured.html.count >= 500 else { failed += 1; continue }
                try await backend.capture(candidateId: check.candidateId, html: captured.html, sourceId: nil, forTrip: true,
                                          url: hiddenPage.advertURL ?? address, dateOptionId: periodID)
                done += 1
                evaluating[check.candidateId] = .now
                model.dataChanged()
            } catch {
                failed += 1
                // Signed out, or the day's allowance on the server is used up: going on would fail the same way.
                if let api = error as? APIError, api.isUnauthorized || api.code == "daily_limit" { notice = model.message(for: error); return }
            }
        }
        hiddenPage.load(URL(string: "about:blank")!)
        var parts = [done == 1 ? "1 Angebot wurde für euren Zeitraum gelesen" : "\(done) Angebote wurden für euren Zeitraum gelesen"]
        if withoutDates > 0 { parts.append(withoutDates == 1 ? "bei 1 hat die Seite den Zeitraum nicht übernommen" : "bei \(withoutDates) hat die Seite den Zeitraum nicht übernommen") }
        if failed > 0 { parts.append(failed == 1 ? "1 ließ sich nicht lesen" : "\(failed) ließen sich nicht lesen") }
        var text = parts.joined(separator: ", ") + ". Die Ergebnisse erscheinen in der Liste, sobald der Server sie ausgewertet hat."
        if !needsPerson.isEmpty {
            text += needsPerson.count == 1 ? " 1 Inserat zeigt eine Sicherheitsabfrage und wird dir jetzt angezeigt."
                                           : " \(needsPerson.count) Inserate zeigen eine Sicherheitsabfrage und werden dir jetzt angezeigt."
            pendingVisible = needsPerson
        }
        notice = text
    }

    /// After one advert was read on the device (or skipped): the next one, or the summary.
    private func nextDeviceCheck() {
        if deviceQueue.isEmpty {
            let left = deviceTotal - deviceDone
            var text = deviceDone == 0 ? "Auf diesem Gerät wurde kein Angebot gelesen."
                : deviceDone == 1 ? "1 Angebot wurde auf diesem Gerät für euren Zeitraum gelesen. Der Server wertet es jetzt aus, das Ergebnis erscheint gleich in der Liste."
                : "\(deviceDone) Angebote wurden auf diesem Gerät für euren Zeitraum gelesen. Der Server wertet sie jetzt aus, die Ergebnisse erscheinen gleich in der Liste."
            if left > 0 { text += left == 1 ? " 1 Angebot wurde abgebrochen und ist nicht geprüft." : " \(left) Angebote wurden abgebrochen und sind nicht geprüft." }
            notice = text
            deviceDone = 0
            deviceTotal = 0
        } else {
            let next = deviceQueue.removeFirst()
            // The sheet has to be gone before the next one can come up.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                deviceCheck = next
            }
        }
    }

    private func setPhase(_ phase: TripPhase) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await backend.setPhase(tripId: tripID, phase: phase)
                model.dataChanged()
            } catch {
                notice = model.message(for: error)
            }
        }
    }

    /// Changes to the frame of the trip, then everything is read again.
    private func frame(_ action: @escaping (any TravelBackend) async throws -> Void) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await action(backend)
                model.dataChanged()
            } catch {
                notice = model.message(for: error)
            }
        }
    }

    private func createInvite() {
        guard let backend = model.backend else { return }
        Task {
            do { invite = try await backend.createInvite(tripId: tripID, role: .member) } catch { notice = model.message(for: error) }
        }
    }
}

private struct InviteSheet: View {
    let invite: Invite
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Dieser Link gilt 14 Tage und für eine Person. Er wird nur jetzt angezeigt.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(invite.url).font(.callout.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(copied ? "Kopiert" : "Link kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = invite.url
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    if let url = URL(string: invite.url) {
                        ShareLink("Einladung senden", item: url).buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Einladung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

private struct TripHeader: View {
    let detail: TripDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.dateOptions) { option in
                if let range = Format.dateRange(option.startDate, option.endDate) {
                    Label(option.label.map { "\($0): \(range)" } ?? range, systemImage: "calendar")
                }
            }
            if detail.trip.isWatchlist {
                Text("Angebote für später, die zu keiner Reise gehören. Wische eines nach links, um es in eine Reise zu verschieben.")
            } else {
                Label(people, systemImage: "person.2")
            }
            if let budget = detail.trip.budgetTotalCents {
                Label("Budget \(Format.euro(cents: budget))", systemImage: "eurosign.circle")
            }
            Label(detail.members.map(\.name).joined(separator: ", "), systemImage: "person.crop.circle.badge.checkmark")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var people: String {
        var parts = ["\(detail.trip.adults) Erwachsene"]
        if detail.trip.children > 0 { parts.append("\(detail.trip.children) Kinder") }
        if detail.trip.pets > 0 { parts.append(detail.trip.pets == 1 ? "1 Haustier" : "\(detail.trip.pets) Haustiere") }
        return parts.joined(separator: ", ")
    }
}

private struct CandidateRow: View {
    let candidate: CandidateSummary
    let persons: Int?

    /// The page of this offer is with the server right now.
    var evaluating = false

    private var working: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("Preis wird gerade ausgewertet …").font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: candidate.listing.coverImageUrl)
                .frame(width: 88, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let count = candidate.listing.photoCount, count > 1 {
                        Text(Format.number(count))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(4)
                            .accessibilityLabel("\(Format.number(count)) Bilder")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if candidate.status == .favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if candidate.status == .booked { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    if let verdict = candidate.criteria { CriteriaLight(verdict: verdict).font(.subheadline) }
                    if candidate.finalist == true {
                        Image(systemName: "trophy.fill").font(.subheadline).foregroundStyle(.tint).accessibilityLabel("Finalist")
                    }
                    Text(candidate.listing.title ?? "Angebot wird gelesen …").font(.headline).lineLimit(2)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if candidate.isUnavailable {
                    Label("Im Reisezeitraum nicht verfügbar", systemImage: "calendar.badge.exclamationmark")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                }
                switch candidate.importStatus {
                case .pending:
                    Label("Wird ausgelesen …", systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary)
                case .partial:
                    Label("Details fehlen noch", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                case .failed:
                    Label("Auslesen fehlgeschlagen", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.red)
                case .ready:
                    EmptyView()
                }
                HStack {
                    if let price = candidate.price, let text = Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) {
                        if price.forThisTrip {
                            // Only a price asked for this trip's dates is shown as the price of the offer.
                            Text(text).font(.subheadline.weight(.semibold))
                            // The price on screen is the old one until the server has read the new page.
                            if evaluating { ProgressView().controlSize(.mini).accessibilityLabel("Preis wird gerade neu ausgewertet") }
                        } else if evaluating {
                            working
                        } else if !candidate.isUnavailable {
                            // A price from the shared link belongs to other dates: named as such, small, never as "the" price.
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Preis für euren Zeitraum noch offen").font(.caption).foregroundStyle(.secondary)
                                Text("im Link: \(text)" + (Format.dateRange(price.startDate, price.endDate).map { " für \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else if evaluating {
                        working
                    } else if !candidate.isUnavailable && candidate.importStatus == .ready {
                        Text("Preis für euren Zeitraum noch offen").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VoteBadges(votes: candidate.votes)
                }
            }
        }
        .padding(.vertical, 2)
        // Booked out for the trip's dates: still there to look at, but out of the running.
        .opacity(candidate.isUnavailable ? 0.45 : 1)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let place = candidate.listing.place ?? candidate.listing.country { parts.append(place) }
        if let bedrooms = candidate.listing.bedrooms { parts.append("\(Format.number(bedrooms)) Schlafzimmer") }
        if let guests = candidate.listing.maxGuests { parts.append("bis \(Format.number(guests)) Gäste") }
        if parts.isEmpty { parts = candidate.listing.platforms.map(Format.platformName) }
        return parts.joined(separator: " · ")
    }
}

struct VoteBadges: View {
    let votes: VoteTally

    var body: some View {
        HStack(spacing: 10) {
            if votes.yes > 0 { badge("\(votes.yes)", "hand.thumbsup.fill", .green, "Ja") }
            if votes.maybe > 0 { badge("\(votes.maybe)", "questionmark.circle.fill", .orange, "Vielleicht") }
            if votes.no > 0 { badge("\(votes.no)", "hand.thumbsdown.fill", .red, "Nein") }
            if votes.vetoes > 0 { badge("Veto", "hand.raised.fill", .red, "Veto") }
        }
        .font(.caption)
    }

    private func badge(_ text: String, _ symbol: String, _ color: Color, _ meaning: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meaning): \(text)")
    }
}

struct CoverImage: View {
    let url: String?

    var body: some View {
        // Clear color fixes the size; the picture fills it and is cropped.
        Color.clear.overlay { RemoteImage(address: url, maxPixel: PhotoSize.thumb * 2) }.clipped()
    }
}
