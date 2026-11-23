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
    @State private var rehoming: TripHome?
    /// The phase whose surface is shown; follows the trip until someone picks another.
    @State private var viewedPhase: TripPhase = .research
    /// The phase shown before the line with the trip's frame was tapped; a second tap on that line goes back there.
    @State private var phaseBeforeFrame: TripPhase?
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
        CandidateRow(candidate: candidate, persons: detail?.trip.persons, evaluating: evaluating[candidate.id] != nil, flexible: detail?.trip.flexWindow != nil).tag(candidate.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if detail?.role.canEdit ?? false {
                    // Not `role: .destructive`: the row must stay until the question is answered.
                    Button("Löschen", systemImage: "trash") { pendingDelete = candidate }.tint(.red)
                    Button("Verschieben", systemImage: "arrow.right.doc.on.clipboard") { moving = candidate }.tint(.indigo)
                }
            }
    }

    /// Everything that steers the list in one line of small chips: status, country, period, sorting, and the check.
    /// It scrolls sideways when it does not fit, so it never takes more than one line from the offers.
    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Status", selection: $filter) {
                        Text("Alle offenen").tag(CandidateStatus?.none)
                        ForEach(CandidateStatus.allCases, id: \.self) { status in
                            Text(status.label).tag(CandidateStatus?.some(status))
                        }
                    }
                } label: {
                    Chip(text: filter?.label ?? "Alle offenen", symbol: "line.3.horizontal.decrease", active: filter != nil)
                }
                if countries.count > 1 {
                    Menu {
                        Picker("Land", selection: $country) {
                            Text("Alle Länder").tag(String?.none)
                            ForEach(countries, id: \.self) { Text("\(Format.flag(forCountry: $0).map { $0 + " " } ?? "")\($0)").tag(String?.some($0)) }
                        }
                    } label: {
                        Chip(text: country ?? "Alle Länder", symbol: "globe.europe.africa", active: country != nil)
                    }
                }
                if let detail, detail.dateOptions.count > 1 {
                    // Prices, availability and the check refer to the period chosen here.
                    Menu {
                        Picker("Zeitraum", selection: $periodID) {
                            ForEach(Array(detail.dateOptions.enumerated()), id: \.element.id) { index, option in
                                Text(option.label ?? Format.dateRange(option.startDate, option.endDate) ?? "Zeitraum \(index + 1)")
                                    .tag(index == 0 ? String?.none : String?.some(option.id))
                            }
                        }
                    } label: {
                        Chip(text: periodLabel(detail), symbol: "calendar", active: periodID != nil)
                    }
                }
                Menu {
                    Picker("Sortieren", selection: $sortRaw) {
                        ForEach(OfferSort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Nur verfügbare zeigen", isOn: $onlyAvailable)
                } label: {
                    Chip(text: sort == .added ? "Sortieren" : sort.label, symbol: "arrow.up.arrow.down", active: sort != .added || onlyAvailable)
                }
                if let detail, detail.role.canEdit, !candidates.isEmpty, !detail.trip.isWatchlist {
                    Button { confirmCheck = true } label: {
                        if let checking {
                            Chip(text: "Prüfe \(checking)", symbol: nil, active: true, busy: true)
                        } else {
                            Chip(text: "Preise prüfen", symbol: "arrow.triangle.2.circlepath", active: false)
                        }
                    }
                    .disabled(checking != nil)
                    .accessibilityLabel("Verfügbarkeit und Preise prüfen")
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func periodLabel(_ detail: TripDetail) -> String {
        let option = detail.dateOptions.first { $0.id == periodID } ?? detail.dateOptions.first
        return option?.label ?? option.flatMap { Format.dateRange($0.startDate, $0.endDate) } ?? "Zeitraum"
    }

    /// Countries folded shut, as "trip|country" entries separated by line breaks, remembered across launches.
    @AppStorage("foldedCountries") private var foldedRaw = ""
    private var foldedCountries: Set<String> { Set(foldedRaw.split(separator: "\n").map(String.init)) }
    private func foldKey(_ country: String) -> String { "\(tripID)|\(country)" }

    private func toggleCountry(_ country: String) {
        var set = foldedCountries
        let key = foldKey(country)
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation { foldedRaw = set.sorted().joined(separator: "\n") }
    }

    /// The offers of one country with its regions, the way the list shows them.
    private struct CountrySection: Identifiable {
        var country: String?
        var regions: [OfferGroup]
        var id: String { country ?? "?" }
        var count: Int { regions.reduce(0) { $0 + $1.offers.count } }
    }

    private var countrySections: [CountrySection] {
        var result: [CountrySection] = []
        for group in OfferGrouping.groups(visible) {
            if let index = result.firstIndex(where: { $0.country == group.country }) { result[index].regions.append(group) }
            else { result.append(CountrySection(country: group.country, regions: [group])) }
        }
        return result
    }

    /// The offers as the list shows them from top to bottom, without those in countries folded shut.
    private var shownOrder: [String] {
        countrySections.filter { !foldedCountries.contains("\(tripID)|\($0.id)") }.flatMap { $0.regions.flatMap { $0.offers.map(\.id) } }
    }

    /// The head of one country in the list: flag, name in large type and number of offers.
    /// A country with a single region names it here; several regions get dividers below instead.
    private func countryHeader(_ section: CountrySection, folded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let flag = Format.flag(forCountry: section.country) { Text(flag).font(.title2) }
            // In a narrow column the name shrinks a little and the rest gives way; nothing wraps.
            Text(section.country ?? "Land unbekannt").font(.title3.weight(.bold)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(2)
            if section.regions.count == 1, let region = section.regions[0].region {
                Text(region).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                Text(section.count == 1 ? "1 Angebot" : "\(section.count) Angebote").lineLimit(1).fixedSize()
                Text("\(section.count)").lineLimit(1).fixedSize()
            }
                .layoutPriority(1)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(.tint)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(folded ? -90 : 0))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(folded ? "zugeklappt" : "aufgeklappt")
        .accessibilityAddTraits(.isHeader)
    }

    /// A region inside a country: a slim line with its name, far less weight than the country above.
    private func regionDivider(_ name: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(name.uppercased()).font(.caption2.weight(.semibold)).kerning(0.6).foregroundStyle(.secondary)
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(height: 16)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Region \(name), \(count == 1 ? "1 Angebot" : "\(count) Angebote")")
    }

    /// Everything but the research: each phase brings its own sections.
    @ViewBuilder private func otherPhase(_ detail: TripDetail) -> some View {
        switch viewedPhase {
        case .decision:
            PitchSections(tripID: tripID, role: detail.role, candidates: candidates, persons: detail.trip.persons, selection: $selection)
        case .framing:
            FramingSections(detail: detail, showCriteria: { showCriteria = true }, invite: { createInvite() },
                            showLedger: { showLedger = true }, sheet: $framingSheet, removing: $removingPeriod, rehoming: $rehoming)
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
                    // Phase and frame of the trip in one line, right under its name.
                    HStack(spacing: 10) {
                        PhaseMenu(trip: detail.trip, viewed: Binding(get: { viewedPhase }, set: { viewedPhase = $0; phasePicked = true; phaseBeforeFrame = nil }),
                                  setPhase: detail.role == .organizer ? { phase in setPhase(phase) } : nil)
                        // The line with the frame works like a fold: one tap opens the frame, the next returns to where one was.
                        CompactTripHeader(detail: detail, open: viewedPhase == .framing && phaseBeforeFrame != nil) {
                            withAnimation {
                                if viewedPhase == .framing, let back = phaseBeforeFrame {
                                    viewedPhase = back
                                    phaseBeforeFrame = nil
                                } else if viewedPhase != .framing {
                                    phaseBeforeFrame = viewedPhase
                                    viewedPhase = .framing
                                }
                                phasePicked = true
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    if viewedPhase == .research, !candidates.isEmpty { controlBar }
                }
                .listSectionSpacing(.compact)
            }
            if let detail, viewedPhase != .research, !detail.trip.isWatchlist {
                otherPhase(detail)
            } else {
            if let detail, detail.trip.isWatchlist {
                Section {
                    CompactTripHeader(detail: detail, open: false) {}
                    if !candidates.isEmpty { controlBar }
                }
                .listSectionSpacing(.compact)
            }
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
            }
            // One section per country under a head that cannot be overlooked; its regions follow with a slim divider.
            ForEach(countrySections) { section in
                Section {
                    // A row of its own, not a section header: headers are forced small and grey by the system.
                    let headed = countrySections.count > 1 || section.country != nil
                    if headed {
                        Button { toggleCountry(section.id) } label: { countryHeader(section, folded: foldedCountries.contains(foldKey(section.id))) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.accentColor.opacity(0.10))
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                    // A folded country keeps its head with the number of offers; its offers wait behind it.
                    if !headed || !foldedCountries.contains(foldKey(section.id)) {
                        ForEach(section.regions) { region in
                            if section.regions.count > 1 {
                                regionDivider(region.region ?? "Weitere", count: region.offers.count)
                            }
                            ForEach(region.offers) { row($0) }
                        }
                    }
                }
                .listSectionSpacing(14)
            }
            if visible.isEmpty && !candidates.isEmpty {
                Section { Text("Kein Angebot passt zu dieser Auswahl.").foregroundStyle(.secondary) }
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
        // Region dividers are slimmer than a normal row may be by default.
        .environment(\.defaultMinListRowHeight, 12)
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
        .modifier(FramingPresenter(tripID: tripID, trip: detail?.trip, sheet: $framingSheet, removing: $removingPeriod, rehoming: $rehoming, run: frame))
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
        .onChange(of: shownOrder, initial: true) { model.offerOrder = shownOrder }
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
            let margin = sent.addingTimeInterval(-5)
            let fresh = [candidate?.price?.checkedAt, candidate?.price?.capturedAt, candidate?.availabilityCheckedAt, candidate?.emptyCheckAt].compactMap { $0 }.contains { $0 > margin }
            // While the run on this device is still going, offers further down the queue keep waiting.
            let waiting = checking != nil || deviceCheck != nil || !deviceQueue.isEmpty
            if candidate == nil || fresh || (!waiting && Date.now.timeIntervalSince(sent) > 180) { evaluating[id] = nil }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            // Fetched apart from the screen's own task: when the system ends that task early, as it does after
            // coming back from another screen, the answer still arrives instead of leaving an empty list.
            let id = tripID, period = periodID
            func fetch() async -> Result<(TripDetail, [CandidateSummary]), Error> {
                await Task {
                    async let trip = backend.trip(id)
                    async let list = backend.candidates(tripId: id, dateOptionId: period)
                    return try await (trip, list)
                }.result
            }
            var answer = await fetch()
            if case .failure(let failure) = answer, failure is CancellationError { answer = await fetch() }
            (detail, candidates) = try answer.get()
            error = nil
            if !phasePicked, let trip = detail?.trip {
                // Open the surface the trip is in; phases without a surface yet fall back to the research.
                viewedPhase = [.framing, .research, .decision, .booking, .preparation, .travelling].contains(trip.activePhase) ? trip.activePhase : .research
            }
        } catch is CancellationError {
            // Nothing was learned: the list must not claim to be empty.
            if !loaded { error = "Die Angebote wurden nicht geladen. Zieh die Liste nach unten, um es noch einmal zu versuchen." }
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
                // Every offer of the run shows a moving sign from now on: those the server reads, and those waiting
                // for this device, until their result is in.
                for check in result.checks where check.mode == "server" || check.wantsDevice { evaluating[check.candidateId] = .now }
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
            guard let address = check.checkUrl, let url = URL(string: address) else { failed += 1; evaluating[check.candidateId] = nil; continue }
            hiddenPage.load(url)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if !hiddenPage.isLoading { break }
            }
            try? await Task.sleep(for: .seconds(2))
            let platform = check.platform ?? "?"
            if await hiddenPage.isChallenge() {
                WebPage.log.info("Prüflauf \(platform, privacy: .public): Sicherheitsabfrage")
                needsPerson.append(check); evaluating[check.candidateId] = nil; continue
            }
            if await hiddenPage.isConsentWall() {
                // A question only a person may answer: the advert is shown to them afterwards, like a security check.
                WebPage.log.info("Prüflauf \(platform, privacy: .public): Cookie-Abfrage vor dem Inserat")
                needsPerson.append(check); evaluating[check.candidateId] = nil; continue
            }
            await hiddenPage.waitForPrice()
            if await hiddenPage.lacksDates() {
                WebPage.log.info("Prüflauf \(platform, privacy: .public): Seite ohne Zeitraum")
                withoutDates += 1; evaluating[check.candidateId] = nil; continue
            }
            do {
                let captured = try await hiddenPage.capture(quick: true)
                WebPage.log.info("Prüflauf \(platform, privacy: .public): \(captured.html.count) Zeichen gelesen")
                if await hiddenPage.isChallenge() { needsPerson.append(check); continue }
                // Check24's phone page carries no reliable price: better no reading than a wrong one.
                guard captured.html.count >= 500, !captured.lean else { failed += 1; evaluating[check.candidateId] = nil; continue }
                // The address asked for, not where the site redirected to: only it is sure to carry the dates of the trip.
                try await backend.capture(candidateId: check.candidateId, html: captured.html, sourceId: nil, forTrip: true,
                                          url: address, dateOptionId: periodID)
                done += 1
                evaluating[check.candidateId] = .now
                model.dataChanged()
            } catch {
                failed += 1
                evaluating[check.candidateId] = nil
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
            text += needsPerson.count == 1 ? " 1 Inserat zeigt eine Sicherheits- oder Cookie-Abfrage und wird dir jetzt angezeigt."
                                           : " \(needsPerson.count) Inserate zeigen eine Sicherheits- oder Cookie-Abfrage und werden dir jetzt angezeigt."
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
            do {
                invite = try await backend.createInvite(tripId: tripID, role: .member)
                // So the new link shows among the open invites.
                model.dataChanged()
            } catch { notice = model.message(for: error) }
        }
    }
}

struct InviteSheet: View {
    let invite: Invite
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Die Einladung gilt 14 Tage und für eine Person. Sie wird nur jetzt angezeigt. Ein Tipp auf den Link öffnet beim Empfänger die App.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                // The address is long and tells a person nothing; it stays one quiet line, the buttons do the work.
                Text(invite.url).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
                if let url = URL(string: invite.url) {
                    HStack(spacing: 12) {
                        InviteMailButton(url: url).buttonStyle(.borderedProminent)
                        InviteShareButton(url: url).buttonStyle(.borderedProminent)
                    }
                }
                Button(copied ? "Kopiert" : "Link kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = invite.url
                    copied = true
                }
                .buttonStyle(.bordered)
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

/// One small pill of the control bar above the offers.
private struct Chip: View {
    let text: String
    let symbol: String?
    /// Set when it filters, sorts or works: then it stands out.
    let active: Bool
    var busy = false

    var body: some View {
        HStack(spacing: 5) {
            if busy { ProgressView().controlSize(.mini) }
            if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
            Text(text).font(.subheadline.weight(active ? .semibold : .regular)).lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .background(active ? Color.accentColor.opacity(0.16) : Color(.secondarySystemFill), in: Capsule())
        .contentShape(Capsule())
    }
}

/// The frame of the trip in one line, so the offers start right below. The details live under "Rahmen".
private struct CompactTripHeader: View {
    let detail: TripDetail
    /// The frame is unfolded and a tap folds it away again.
    let open: Bool
    let openFrame: () -> Void

    var body: some View {
        if detail.trip.isWatchlist {
            Text(detail.trip.groupId == nil ? "Angebote für später. Wische eines nach links, um es in eine Reise zu verschieben."
                                            : "Merkliste von „\(detail.trip.groupName ?? "der Gruppe")“, für alle Mitglieder. Wische ein Angebot nach links, um es in eine Reise zu verschieben.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Button(action: openFrame) {
                HStack(spacing: 6) {
                    Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(open ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rahmen der Reise: \(summary)")
            .accessibilityHint(open ? "Schließt den Rahmen und kehrt zur vorigen Ansicht zurück" : "Öffnet den Rahmen der Reise")
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let window = detail.trip.flexWindow, detail.dateOptions.isEmpty { parts.append(window.summary) }
        else if let first = detail.dateOptions.first, let range = Format.dateRange(first.startDate, first.endDate) {
            parts.append(detail.dateOptions.count > 1 ? "\(range) und \(detail.dateOptions.count - 1) weitere" : range)
        }
        parts.append(detail.trip.persons == 1 ? "1 Person" : "\(detail.trip.persons) Personen")
        if let budget = detail.trip.budgetTotalCents { parts.append("Budget \(Format.euro(cents: budget))") }
        if let group = detail.trip.groupName, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " · ")
    }
}

private struct TripHeader: View {
    let detail: TripDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let group = detail.trip.groupName, !group.isEmpty {
                Label(detail.trip.isWatchlist ? "Merkliste von „\(group)“" : group, systemImage: "person.3")
            }
            ForEach(detail.dateOptions) { option in
                if let range = Format.dateRange(option.startDate, option.endDate) {
                    Label(option.label.map { "\($0): \(range)" } ?? range, systemImage: "calendar")
                }
            }
            if detail.trip.isWatchlist {
                Text(detail.trip.groupId == nil ? "Angebote für später, die zu keiner Reise gehören. Wische eines nach links, um es in eine Reise zu verschieben."
                                                : "Angebote für später, die alle Mitglieder der Gruppe sehen und pflegen. Wische eines nach links, um es in eine Reise zu verschieben.")
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
    /// The trip has a flexible window, so the stay behind each price is worth naming.
    var flexible = false

    /// Something is still being read or evaluated for this offer, here or on the server.
    private var busy: Bool { evaluating || candidate.importStatus == .pending || candidate.deviceRead == false }

    /// What exactly is going on, in a few words.
    private var busyText: String {
        if evaluating { return "Preis wird gerade abgefragt …" }
        if candidate.deviceRead == false && candidate.importStatus != .pending { return "Wird gleich vom Gerät gelesen …" }
        return "Wird gerade ausgewertet …"
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
                    // Covered by the moving sign in the price line below.
                    EmptyView()
                case .partial:
                    if !busy { Label("Details fehlen noch", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                case .failed:
                    if !busy { Label("Auslesen fehlgeschlagen", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.red) }
                case .ready:
                    EmptyView()
                }
                HStack {
                    if let price = candidate.price, price.forThisTrip, let text = candidate.groupPriceText {
                        // Only a price asked for this trip's dates is shown as the price of the offer, and always for the whole group.
                        Text(text).font(.subheadline.weight(.semibold))
                        if candidate.share.splits, let each = candidate.share.household(price.totalCents) {
                            Text("\(Format.euro(cents: each)) je Haushalt").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        // The price on screen is the old one until the new reading is through.
                        if busy { ProgressView().controlSize(.mini).accessibilityLabel(busyText) }
                    } else if busy {
                        // Still at work: say so with a moving sign, so nobody takes the wait for a failure.
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text(busyText).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !candidate.isUnavailable, candidate.importStatus != .failed {
                        // Nothing is running and there is no price for the trip: say what to do about it.
                        VStack(alignment: .leading, spacing: 1) {
                            Label(candidate.emptyCheckAt != nil ? "Kein Preis gefunden, bitte erneut prüfen" : "Noch kein Preis für euren Zeitraum, tippe oben auf „Preise prüfen“",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                            if let price = candidate.price, let text = Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) {
                                // A price from the shared link belongs to other dates: named as such, small, never as "the" price.
                                Text("im Link: \(text)" + (Format.dateRange(price.startDate, price.endDate).map { " für \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    VoteBadges(votes: candidate.votes)
                }
                if let price = candidate.price, price.forThisTrip, let nights = price.nights, nights > 0, (candidate.stays?.count ?? 0) > 0 || flexible {
                    // With a flexible window every advert may show another stay: say which, and what a night costs.
                    // Several possible stays: their number comes first, where a narrow list does not cut it off.
                    let several = (candidate.stays?.count ?? 0) > 1
                    Text([several ? "\(candidate.stays?.count ?? 0) Termine" : nil,
                          Format.dateRange(price.startDate, price.endDate).map { several ? "bester \($0)" : $0 },
                          nights == 1 ? "1 Nacht" : "\(nights) Nächte",
                          price.totalCents.map { "\(Format.euro(cents: $0 / nights)) je Nacht" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let price = candidate.price, price.forThisTrip, let asked = price.persons, let persons, asked != persons {
                    // Some platforms keep the party of the shared link: the price is real, but for fewer or more people.
                    Label("Preis für \(asked == 1 ? "1 Person" : "\(asked) Personen"), nicht für \(persons)", systemImage: "person.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !busy, candidate.emptyCheckAt != nil, candidate.price?.forThisTrip == true {
                    Label("Letzter Abruf ohne Ergebnis, bitte erneut prüfen", systemImage: "arrow.clockwise.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if candidate.fitsParty == false {
                    Label("Zu klein für eure Personenzahl", systemImage: "person.2.slash").font(.caption).foregroundStyle(.orange)
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
