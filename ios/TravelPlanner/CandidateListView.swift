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
    @State private var showAddLink = false
    @State private var link = ""
    @State private var invite: Invite?
    @State private var notice: String?

    private var visible: [CandidateSummary] {
        candidates.filter { candidate in
            if let filter { return candidate.status == filter }
            return candidate.status != .rejected
        }
    }

    var body: some View {
        List(selection: $selection) {
            if let detail {
                Section {
                    TripHeader(detail: detail)
                }
            }
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
            }
            Section {
                ForEach(visible) { candidate in
                    CandidateRow(candidate: candidate, persons: detail?.trip.persons).tag(candidate.id)
                }
            } header: {
                if !candidates.isEmpty {
                    Picker("Anzeigen", selection: $filter) {
                        Text("Alle offenen").tag(CandidateStatus?.none)
                        ForEach(CandidateStatus.allCases, id: \.self) { status in
                            Text(status.label).tag(CandidateStatus?.some(status))
                        }
                    }
                    .pickerStyle(.menu)
                    .textCase(nil)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Dieser Link gilt 14 Tage und für eine Person. Er wird nur jetzt angezeigt.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(invite.url).font(.callout.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                if let url = URL(string: invite.url) {
                    ShareLink("Einladung senden", item: url).buttonStyle(.borderedProminent)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if candidate.status == .favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if candidate.status == .booked { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    Text(candidate.listing.title ?? "Angebot wird gelesen …").font(.headline).lineLimit(2)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
                            Text("anderer Zeitraum").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    VoteBadges(votes: candidate.votes)
                }
            }
        }
        .padding(.vertical, 2)
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
