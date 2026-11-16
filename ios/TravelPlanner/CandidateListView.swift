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
    @State private var showCompare = false
    @State private var showMap = false
    /// "2 von 5" while all offers are being checked; nil otherwise.
    @State private var checking: String?
    /// Adverts still to be read on this device during a check of the whole trip.
    @State private var deviceQueue: [TripCheck.Check] = []
    @State private var deviceTotal = 0
    /// How many of them were actually read and sent; the rest were cancelled.
    @State private var deviceDone = 0
    @State private var deviceCheck: TripCheck.Check?

    private var visible: [CandidateSummary] {
        candidates.filter { candidate in
            if let country, OfferGrouping.country(of: candidate) != country { return false }
            if let filter { return candidate.status == filter }
            return candidate.status != .rejected
        }
    }

    private var countries: [String] { OfferGrouping.countries(in: candidates) }

    @ViewBuilder
    private func row(_ candidate: CandidateSummary) -> some View {
        CandidateRow(candidate: candidate, persons: detail?.trip.persons).tag(candidate.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if detail?.role.canEdit ?? false {
                    // Not `role: .destructive`: the row must stay until the question is answered.
                    Button("Löschen", systemImage: "trash") { pendingDelete = candidate }.tint(.red)
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
            if countries.count > 1 {
                Picker("Land", selection: $country) {
                    Text("Alle Länder").tag(String?.none)
                    ForEach(countries, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Spacer()
        }
        .pickerStyle(.menu)
        .textCase(nil)
    }

    var body: some View {
        List(selection: $selection) {
            if let detail {
                Section {
                    TripHeader(detail: detail)
                    if detail.role.canEdit && !candidates.isEmpty {
                        Button {
                            checkAll()
                        } label: {
                            if let checking {
                                HStack(spacing: 10) { ProgressView(); Text("Prüfe \(checking) …") }
                            } else {
                                Label("Verfügbarkeit und Preise prüfen", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(checking != nil)
                    }
                } footer: {
                    if detail.role.canEdit && !candidates.isEmpty {
                        Text("Fragt alle Angebote für den Zeitraum und die Gäste dieser Reise neu ab. Inserate, die der Server nicht lesen kann, öffnet die App danach kurz nacheinander selbst.")
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
        }
        .overlay {
            if loaded && candidates.isEmpty && error == nil {
                ContentUnavailableView {
                    Label("Noch keine Angebote", systemImage: "square.and.arrow.up")
                } description: {
                    Text("Öffne ein Inserat in Safari oder in der App der Plattform, tippe auf Teilen und wähle Travel Planner.")
                } actions: {
                    Button("Link einfügen") { showAddLink = true }
                }
            }
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
            if candidates.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button("Vergleichen", systemImage: "rectangle.split.3x1") { showCompare = true }
                }
            }
            if detail?.role == .organizer {
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
            Button("OK") {}
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
        .fullScreenCover(isPresented: $showCompare) {
            CompareView(candidates: candidates, persons: detail?.trip.persons)
        }
        .sheet(item: $deviceCheck, onDismiss: nextDeviceCheck) { check in
            let url = check.checkUrl ?? ""
            CaptureView(source: ListingSource(id: check.candidateId, platform: check.platform ?? "other", url: url, canonicalUrl: url),
                        candidateID: check.candidateId, forTrip: true, automatic: true,
                        progressLabel: "\(deviceTotal - deviceQueue.count) von \(deviceTotal)") { _, _ in deviceDone += 1 }
        }
        .sheet(item: $invite) { invite in
            InviteSheet(invite: invite)
        }
        .refreshable { await load() }
        .task(id: model.revision) {
            await load()
            // Imports finish in the background on the server; look again until none is pending.
            while !Task.isCancelled, candidates.contains(where: { $0.importStatus == .pending }) {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            async let trip = backend.trip(tripID)
            async let list = backend.candidates(tripId: tripID)
            (detail, candidates) = try await (trip, list)
            error = nil
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
                let result = try await backend.checkTrip(tripId: tripID)
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
                } else {
                    deviceCheck = deviceQueue.removeFirst()
                }
            } catch {
                notice = model.message(for: error)
            }
            checking = nil
        }
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
            Label(people, systemImage: "person.2")
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
                        Text(text).font(.subheadline.weight(.semibold))
                        if !price.forThisTrip {
                            // Not asked for this trip's dates, so say which dates the price belongs to.
                            Text(Format.dateRange(price.startDate, price.endDate) ?? "anderer Zeitraum")
                                .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
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
