import SwiftUI
import TravelPlannerKit

/// The standardised profile of one offer, with voting and comments.
struct CandidateDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let candidateID: String
    /// Moves on to the next (+1) or back to the previous (-1) offer of the list. False when there is none.
    var onStep: (Int) -> Bool = { _ in false }
    /// Called after the offer was deleted, so the surrounding view can close it.
    var onDeleted: () -> Void = {}

    @State private var detail: CandidateDetail?
    /// Every stay known for this offer on a trip with a flexible window, by date.
    @State private var stays: [Stay] = []
    @State private var allStays = false
    /// Why the marked stay leads, as the server says it.
    @State private var bestStayReason: String?
    /// Where the photo strip sits on screen: a swipe that starts on it moves the photos, not the offer.
    @State private var stripFrame: CGRect = .zero
    @State private var error: String?
    @State private var comment = ""
    @State private var captureSource: ListingSource?
    @State private var actionError: String?
    @State private var confirmDelete = false
    @State private var showReviews = false
    @State private var showAddSource = false
    @State private var showMove = false
    @State private var showCorrection = false
    /// The sections unfolded in full; folded they show only their first lines.
    @State private var open: Set<String> = []
    /// The server no longer knows this offer; nothing more is asked about it.
    @State private var gone = false
    @State private var showStays = false
    /// The advert's page to open for one stay, after the stay sheet has closed.
    @State private var stayCheck: StayCheck?
    @State private var mapTarget: MapTarget?
    @State private var sentNote: String?
    @State private var sourceLink = ""
    @AppStorage(Settings.showWarnings) private var showWarnings = false

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let error {
                ContentUnavailableView {
                    Label("Nicht geladen", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Erneut versuchen") {
                        self.error = nil
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // A sideways swipe moves to the next or previous offer of the list. It has to be clearly sideways and long,
        // so scrolling up and down never triggers it; a swipe from the left edge stays the system's way back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { drag in
                let across = drag.translation.width, along = drag.translation.height
                guard abs(across) > 90, abs(across) > abs(along) * 2.5 else { return }
                guard drag.startLocation.x > 28, !stripFrame.contains(drag.startLocation) else { return }
                if !onStep(across < 0 ? 1 : -1) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            }
        )
        .task(id: model.revision) {
            await load()
            // Imports and the search for other platforms finish on the server; look again until both are done.
            while !Task.isCancelled, detail?.candidate.importStatus == .pending || detail?.otherPlatforms?.isRunning == true {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await load()
            }
        }
        .confirmationDialog("Angebot löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { delete() }
        } message: {
            Text("Das Angebot wird mit allen Stimmen und Kommentaren aus der Reise entfernt. Das lässt sich nicht rückgängig machen.")
        }
        .alert("Das hat nicht geklappt", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
        .alert("Link hinzufügen", isPresented: $showAddSource) {
            TextField("https://…", text: $sourceLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Abbrechen", role: .cancel) { sourceLink = "" }
            Button("Hinzufügen") {
                let text = sourceLink
                sourceLink = ""
                if let url = LinkFinder.firstURL(in: text) {
                    perform { try await $0.addSource(candidateId: candidateID, url: url.absoluteString) }
                } else {
                    actionError = "Das ist keine Internetadresse."
                }
            }
        } message: {
            Text("Adresse desselben Hauses auf einer anderen Plattform. Seine Bewertungen und Preise kommen dann dazu.")
        }
        .alert("Seite übernommen", isPresented: .init(get: { sentNote != nil }, set: { if !$0 { sentNote = nil } })) {
            Button("OK") {}
        } message: {
            Text(sentNote ?? "")
        }
        // Fills the screen, like the map of the whole trip: on the iPad a sheet is too small to move about in.
        .fullScreenCover(item: $mapTarget) { target in
            LocationMapView(title: target.title, hint: target.hint, place: target.place)
        }
        .sheet(isPresented: $showStays) {
            StaySheet(candidateID: candidateID, tripID: detail?.candidate.tripId ?? "") { url, start, end in
                // The sheet has to be gone before the next one can come up.
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    stayCheck = StayCheck(url: url, start: start, end: end)
                }
            }
        }
        .sheet(item: $stayCheck) { check in
            CaptureView(source: ListingSource(id: candidateID, platform: detail?.sources.first?.platform ?? "other", url: check.url, canonicalUrl: check.url),
                        candidateID: candidateID, forTrip: true, automatic: true, stay: (check.start, check.end))
        }
        .sheet(isPresented: $showCorrection) {
            if let detail { CorrectionView(detail: detail) }
        }
        .sheet(isPresented: $showMove) {
            MoveOfferView(candidateID: candidateID, title: detail?.listing.title ?? "Angebot",
                          currentTripID: detail?.candidate.tripId ?? "") { _ in onDeleted() }
        }
        .sheet(isPresented: $showReviews) {
            ReviewList(items: detail?.reviews?.items ?? [], fallbackScale: detail?.listing.profile.rating?.scale)
        }
        .sheet(item: $captureSource) { source in
            // Only further sources are named; without a name the page counts for the leading source, on any server.
            CaptureView(source: source, candidateID: candidateID,
                        sourceID: source.id == detail?.sources.first?.id || source.primary == true ? nil : source.id,
                        expectedPictures: expectedPictures(for: source),
                        knownPictures: source.id == detail?.sources.first?.id || source.primary == true ? (detail?.photos ?? []).filter { !PictureQuality.isSmallCheck24($0.url) }.count : 0) { pictures, reviews in
                sentNote = "Gesendet: \(pictures == 0 ? "keine neuen Bilder" : pictures == 1 ? "1 Bild" : "\(pictures) Bilder") und \(reviews == 1 ? "1 Bewertung" : "\(reviews) Bewertungen") im Wortlaut. Der Server wertet das jetzt aus, das dauert bis zu einer Minute."
            }
        }
    }

    /// A few words on why the marked stay leads.
    private var bestLabel: String {
        switch bestStayReason {
        case "preferred": "Lieblingsdauer, günstigster Termin"
        case "cheaper_longer": "länger, aber je Nacht deutlich günstiger"
        case "nearest": "Lieblingsdauer nicht zu haben, nächstliegende Dauer"
        default: "günstigster je Nacht"
        }
    }

    /// "Mögliche Reisedaten": each stay in the trip's window with its price, by date, the cheapest per night marked.
    /// Long lists show the best and the first few; the rest unfolds.
    @ViewBuilder private var staysSection: some View {
        let limit = 4
        let shown = allStays || stays.count <= limit + 1 ? stays : stays.filter { $0.best == true } + stays.filter { $0.best != true }.prefix(limit - 1)
        Section {
            ForEach(shown.sorted { $0.startDate < $1.startDate }) { stay in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.dateRange(stay.startDate, stay.endDate) ?? stay.startDate)
                            .fontWeight(stay.best == true ? .semibold : .regular)
                        Text([stay.nights.map { $0 == 1 ? "1 Nacht" : "\($0) Nächte" }, stay.available == false ? "belegt" : nil,
                              stay.best == true ? bestLabel : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(stay.available == false ? Color.red : stay.best == true ? Color.green : Color.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let total = stay.totalCents { Text(Format.euro(cents: total)).fontWeight(stay.best == true ? .semibold : .regular) }
                        if let night = stay.perNightCents { Text("\(Format.euro(cents: night)) je Nacht").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            if stays.count > limit + 1 {
                Button(allStays ? "Weniger zeigen" : "Alle \(stays.count) Termine zeigen") { withAnimation { allStays.toggle() } }.font(.subheadline)
            }
        } header: {
            Text("Mögliche Reisedaten")
        }
    }

    private func load() async {
        guard !gone, let backend = model.backend else { return }
        do {
            // Fetched apart from the screen's own task: when the system ends that task early, as it sometimes does
            // while moving from one offer to the next, the answer still arrives and the offer still shows.
            let id = candidateID
            var answer = await Task { try await backend.candidate(id) }.result
            if case .failure(let failure) = answer, failure is CancellationError {
                answer = await Task { try await backend.candidate(id) }.result
            }
            detail = try answer.get()
            error = nil
            // The possible stays come with the list of the trip, not with the offer itself.
            if let trip = detail?.candidate.tripId, let list = try? await backend.candidates(tripId: trip) {
                stays = (list.first { $0.id == id }?.stays ?? []).sorted { $0.startDate < $1.startDate }
                bestStayReason = list.first { $0.id == id }?.bestStayReason
            }
        } catch is CancellationError {
            if detail == nil { error = "Das Angebot wurde nicht geladen." }
        } catch let missing as APIError where missing.status == 404 {
            // Deleted or moved elsewhere, perhaps by someone else: it quietly leaves the screen and the list.
            guard !gone else { return }
            gone = true
            detail = nil
            onDeleted()
            model.dataChanged()
        } catch {
            self.error = model.message(for: error)
        }
    }

    private func perform(_ action: @escaping (any TravelBackend) async throws -> Void) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await action(backend)
                model.dataChanged()
            } catch {
                // The offer stays on screen, so a failed action is reported on top of it.
                actionError = model.message(for: error)
            }
        }
    }

    /// Airbnb hands its photos to the server in the page data, so the count seen on the device does not matter there.
    private func expectedPictures(for source: ListingSource) -> Int? {
        guard let detail, source.platform != "airbnb" else { return nil }
        let stated = Int(detail.listing.profile.photoCount ?? 0)
        let known = max(stated, detail.photos?.count ?? 0)
        return known > 0 ? known : nil
    }

    private func delete() {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await backend.delete(candidateId: candidateID)
                model.dataChanged()
                onDeleted()
            } catch {
                actionError = model.message(for: error)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: CandidateDetail) -> some View {
        let profile = detail.listing.profile
        let canEdit = detail.role.canEdit
        List {
            if !detail.gallery.isEmpty {
                Section {
                    PhotoStrip(photos: detail.gallery)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripFrame = $0 }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    // The advert states more pictures than were read, typically because its gallery loads them on demand.
                    if let stated = profile.photoCount, Int(stated) > detail.gallery.count {
                        Text("Das Inserat hat \(Format.number(stated)) Bilder, hier sind \(detail.gallery.count). Für alle: unten „Auf diesem Gerät aktualisieren“ und dort die Bildergalerie einmal durchblättern.")
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.listing.title ?? "Angebot").font(.title2.weight(.semibold))
                    Text(headline(detail)).foregroundStyle(.secondary)
                    if let summary = profile.summary { Text(summary).font(.callout) }
                }
                .listRowSeparator(.hidden)
                // The advert itself, on the platform it came from: in the browser or the platform's own app.
                if let source = detail.sources.first, let url = URL(string: source.url) {
                    Button { openURL(url) } label: {
                        Label("Original auf \(Format.platformName(source.platform)) öffnen", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .listRowSeparator(.hidden)
                }
            }

            // Right under the title: voting is what the group opens an offer for.
            voteSection(detail)
            if stays.count > 1 { staysSection }

            importSection(detail, canEdit: canEdit)

            hintsSection(detail, canEdit: canEdit)

            if let verdict = detail.criteria, !(verdict.results ?? []).isEmpty {
                CriteriaSection(verdict: verdict, canEdit: canEdit) { checks in
                    perform { try await $0.setCriteriaChecks(candidateId: candidateID, checks: checks) }
                }
            }

            // High up on purpose: where the house is decides more than most of the rows below.
            LocationSection(detail: detail) { mapTarget = $0 }

            priceSection(detail)

            if let reviews = detail.reviews, !reviews.isEmpty {
                ReviewsSection(reviews: reviews, rating: profile.rating, showAll: { showReviews = true },
                               readOnDevice: canEdit ? detail.sources.first.map { source in { captureSource = source } } : nil)
            }

            Section("Eckdaten") {
                fact("Art", profile.objectType ?? detail.listing.kind.label, "objectType", profile)
                number("Gäste", profile.maxGuests, "maxGuests", profile)
                number("Schlafzimmer", profile.bedrooms, "bedrooms", profile)
                number("Bäder", profile.bathrooms, "bathrooms", profile)
                if open.contains("facts") {
                    number("Betten", profile.beds, "beds", profile)
                    number("Schlafplätze", profile.sleepingPlaces, "sleepingPlaces", profile)
                    number("Wohnfläche", profile.livingAreaSqm, "livingAreaSqm", profile, unit: " m²")
                    number("Grundstück", profile.plotSqm, "plotSqm", profile, unit: " m²")
                    if detail.reviews?.isEmpty ?? true, let rating = profile.rating, let value = rating.value {
                        let scale = rating.scale.map { " von \(Format.number($0))" } ?? ""
                        let count = rating.count.map { " (\(Format.number($0)) Bewertungen)" } ?? ""
                        LabeledContent("Bewertung", value: "\(Format.number(value))\(scale)\(count)")
                    }
                    ForEach(profile.bedDetails ?? [], id: \.self) { bed in
                        LabeledContent(bed.room, value: bed.beds)
                    }
                }
                if profile.beds != nil || profile.sleepingPlaces != nil || profile.livingAreaSqm != nil || profile.plotSqm != nil || !(profile.bedDetails ?? []).isEmpty {
                    more("facts", "Betten, Flächen und Zimmer")
                }
            }

            if detail.listing.kind != .vacationHome, let trip = profile.packageTrip {
                Section(detail.listing.kind.label) {
                    number("Sterne", trip.hotelStars, "packageTrip.hotelStars", profile)
                    fact("Verpflegung", trip.board, "packageTrip.board", profile)
                    if open.contains("hotel") {
                        fact("Zimmer", trip.roomType, "packageTrip.roomType", profile)
                        fact("Abflug", trip.departureAirport, "packageTrip.departureAirport", profile)
                        number("Dauer", trip.durationDays, "packageTrip.durationDays", profile, unit: " Tage")
                        fact("Veranstalter", trip.tourOperator, "packageTrip.tourOperator", profile)
                        if let transfer = trip.transferIncluded { LabeledContent("Transfer", value: transfer ? "inklusive" : "nicht inklusive") }
                    }
                    if trip.roomType != nil || trip.departureAirport != nil || trip.durationDays != nil || trip.tourOperator != nil || trip.transferIncluded != nil {
                        more("hotel", "Zimmer, Abflug, Dauer, Veranstalter")
                    }
                }
            }

            Section {
                if !open.contains("amenities") {
                    // Folded: what is there and what is not, in two lines.
                    let there = Profile.amenityKeys.filter { profile.amenity($0) == true }.map(Format.amenityName)
                    let missing = Profile.amenityKeys.filter { profile.amenity($0) == false }.map(Format.amenityName)
                    if !there.isEmpty {
                        Label(there.joined(separator: ", "), systemImage: "checkmark.circle.fill").foregroundStyle(.primary, .green)
                    }
                    if !missing.isEmpty {
                        Label(missing.joined(separator: ", "), systemImage: "xmark.circle").foregroundStyle(.secondary, .red).font(.callout)
                    }
                    if there.isEmpty && missing.isEmpty { Text("Das Inserat nennt keine Ausstattung.").foregroundStyle(.secondary) }
                }
                if open.contains("amenities") {
                ForEach(Profile.amenityKeys, id: \.self) { key in
                    HStack {
                        Text(Format.amenityName(key))
                        if profile.isUncertain("amenities.\(key)") { UncertainMark() }
                        Spacer()
                        switch profile.amenity(key) {
                        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("vorhanden")
                        case false?: Image(systemName: "xmark.circle").foregroundStyle(.red).accessibilityLabel("nicht vorhanden")
                        case nil: Text("unbekannt").foregroundStyle(.tertiary)
                        }
                    }
                }
                if let other = profile.otherAmenities, !other.isEmpty {
                    Text(other.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                }
                more("amenities", "ganze Liste, auch Unbekanntes")
            } header: {
                Text("Ausstattung")
            } footer: {
                if open.contains("amenities") { Text("„Unbekannt“ heißt: Das Inserat sagt dazu nichts. Es wird nichts geschätzt.") }
            }

            if let distances = profile.distances {
                Section("Entfernungen") {
                    distance("Strand", distances.beachM, "distances.beachM", profile)
                    distance("Meer", distances.seaM, "distances.seaM", profile)
                    distance("Ort", distances.townM, "distances.townM", profile)
                    if open.contains("distances") {
                        distance("Einkaufen", distances.shopM, "distances.shopM", profile)
                        distance("Restaurant", distances.restaurantM, "distances.restaurantM", profile)
                        number("Flughafen", distances.airportKm, "distances.airportKm", profile, unit: " km")
                    }
                    if distances.shopM != nil || distances.restaurantM != nil || distances.airportKm != nil { more("distances", "Einkaufen, Restaurant, Flughafen") }
                }
            }

            Section("Regeln") {
                fact("Anreise ab", profile.rules?.checkInFrom, "rules.checkInFrom", profile)
                fact("Abreise bis", profile.rules?.checkOutUntil, "rules.checkOutUntil", profile)
                if open.contains("rules") {
                    fact("Anreisetage", profile.rules?.arrivalDays, "rules.arrivalDays", profile)
                    number("Mindestaufenthalt", profile.rules?.minNights, "rules.minNights", profile, unit: " Nächte")
                    fact("Rauchen", profile.rules?.smoking, "rules.smoking", profile)
                    if let cancellation = profile.cancellation {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stornierung").font(.subheadline).foregroundStyle(.secondary)
                            Text(cancellation)
                        }
                    }
                }
                if profile.rules?.arrivalDays != nil || profile.rules?.minNights != nil || profile.rules?.smoking != nil || profile.cancellation != nil {
                    more("rules", "Anreisetage, Mindestaufenthalt, Stornierung")
                }
            }

            SourcesSection(
                detail: detail, canEdit: canEdit,
                refresh: { perform { try await $0.refresh(candidateId: candidateID) } },
                readOnDevice: { captureSource = $0 },
                removeSource: { source in perform { try await $0.removeSource(candidateId: candidateID, sourceId: source.id) } },
                search: { perform { try await $0.searchOtherPlatforms(candidateId: candidateID) } },
                decide: { suggestion, accept in
                    perform { try await $0.decide(candidateId: candidateID, suggestionId: suggestion.id, accept: accept) }
                },
                addLink: { showAddSource = true })

            Section("Kommentare") {
                if detail.comments.count > 3 { more("comments", "\(detail.comments.count - 3) ältere Kommentare") }
                ForEach(open.contains("comments") ? detail.comments : Array(detail.comments.suffix(3))) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(comment.name ?? "Jemand") · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(comment.body)
                    }
                }
                HStack(alignment: .bottom) {
                    TextField("Kommentar schreiben", text: $comment, axis: .vertical)
                    Button("Senden", systemImage: "arrow.up.circle.fill") {
                        let body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                        comment = ""
                        perform { try await $0.comment(candidateId: candidateID, body: body) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(detail.listing.title ?? "Angebot")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Status", selection: Binding(
                            get: { detail.candidate.status },
                            set: { status in perform { try await $0.setStatus(candidateId: candidateID, status: status) } })) {
                            ForEach(CandidateStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Divider()
                        Button("Zeiträume und Preise …", systemImage: "calendar") { showStays = true }
                        Button("Von Hand korrigieren …", systemImage: "pencil") { showCorrection = true }
                        Button("In andere Reise oder auf die Merkliste …", systemImage: "arrow.right.doc.on.clipboard") { showMove = true }
                        Button("Angebot löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label(detail.candidate.status.label, systemImage: detail.candidate.status == .favorite ? "star.fill" : "star")
                    }
                }
            }
        }
    }

    /// The line that unfolds a section, or folds it again.
    private func more(_ key: String, _ what: String) -> some View {
        Button {
            withAnimation { if open.contains(key) { open.remove(key) } else { open.insert(key) } }
        } label: {
            HStack(spacing: 6) {
                Text(open.contains(key) ? "Weniger zeigen" : "Mehr: \(what)")
                Image(systemName: open.contains(key) ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    /// Three large buttons to vote with, the own choice filled in, and how the others voted underneath.
    @ViewBuilder private func voteSection(_ detail: CandidateDetail) -> some View {
        let mine = detail.votes.entries.first { $0.userId == model.user?.id }
        Section {
            HStack(spacing: 10) {
                voteButton(.yes, "Ja", "hand.thumbsup", mine)
                voteButton(.maybe, "Vielleicht", "questionmark.circle", mine)
                voteButton(.no, "Nein", "hand.thumbsdown", mine)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .listRowSeparator(.hidden)
            if mine?.verdict == .no {
                Toggle("Veto: für mich ausgeschlossen", isOn: Binding(
                    get: { mine?.veto ?? false },
                    set: { veto in perform { try await $0.vote(candidateId: candidateID, verdict: .no, veto: veto) } }))
            }
            let others = detail.votes.entries.filter { $0.userId != model.user?.id }
            if !others.isEmpty {
                Text(others.map { "\($0.name): \($0.veto ? "Veto" : $0.verdict.label)" }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(mine == nil ? "Wie findest du es?" : "Deine Stimme")
        } footer: {
            if mine != nil { Text("Noch einmal antippen nimmt deine Stimme zurück.") }
        }
    }

    private func voteButton(_ verdict: Verdict, _ label: String, _ symbol: String, _ mine: VoteEntry?) -> some View {
        let chosen = mine?.verdict == verdict
        return Button {
            // A second tap on the own choice takes the vote back.
            if chosen { perform { try await $0.removeVote(candidateId: candidateID) } }
            else { perform { try await $0.vote(candidateId: candidateID, verdict: verdict, veto: verdict == .no && (mine?.veto ?? false)) } }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: chosen ? symbol + ".fill" : symbol).font(.title2)
                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            // Calm grey next to photos and map; only the own choice stands out, in the colour of the app.
            .foregroundStyle(chosen ? Color.white : Color.primary)
            .background(chosen ? Color.accentColor : Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(chosen ? ", deine Stimme" : "")")
        .accessibilityHint(chosen ? "Tippen nimmt die Stimme zurück" : "")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func headline(_ detail: CandidateDetail) -> String {
        let profile = detail.listing.profile
        var parts = [detail.listing.place, profile.region, detail.listing.country].compactMap { $0 }.filter { !$0.isEmpty }
        parts.append(contentsOf: detail.sources.map { Format.platformName($0.platform) })
        return parts.joined(separator: " · ")
    }

    /// Hints are folded away by default and can be hidden one by one once the group has dealt with them.
    /// Hiding applies to everyone on the trip and can be undone; nothing is deleted.
    @ViewBuilder
    private func hintsSection(_ detail: CandidateDetail, canEdit: Bool) -> some View {
        let visible = detail.hints.filter { !$0.hidden }
        let hidden = detail.hints.filter(\.hidden)
        if !visible.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showWarnings) {
                    ForEach(visible) { hint in
                        Label(hint.text, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .swipeActions(edge: .trailing) {
                                if canEdit {
                                    Button("Ausblenden", systemImage: "eye.slash") {
                                        let list = hidden.map(\.text) + [hint.text]
                                        perform { try await $0.setHiddenWarnings(candidateId: candidateID, hidden: list) }
                                    }
                                    .tint(.gray)
                                }
                            }
                    }
                    if canEdit {
                        Button(visible.count == 1 ? "Hinweis ausblenden" : "Alle \(visible.count) Hinweise ausblenden", systemImage: "eye.slash") {
                            let list = detail.hints.map(\.text)
                            perform { try await $0.setHiddenWarnings(candidateId: candidateID, hidden: list) }
                        }
                    }
                } label: {
                    Label(visible.count == 1 ? "1 Hinweis" : "\(visible.count) Hinweise", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if showWarnings && canEdit {
                    Text("Einzelne Hinweise blendest du aus, indem du sie nach links wischst. Das gilt für alle Mitreisenden.")
                }
            }
        }
        if !hidden.isEmpty && canEdit {
            Section {
                Button(hidden.count == 1 ? "1 ausgeblendeten Hinweis wieder zeigen" : "\(hidden.count) ausgeblendete Hinweise wieder zeigen", systemImage: "eye") {
                    perform { try await $0.setHiddenWarnings(candidateId: candidateID, hidden: []) }
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func importSection(_ detail: CandidateDetail, canEdit: Bool) -> some View {
        switch detail.candidate.importStatus {
        case .ready:
            EmptyView()
        case .pending:
            Section {
                Label("Das Angebot wird gerade ausgelesen …", systemImage: "arrow.triangle.2.circlepath")
            }
        case .partial, .failed:
            Section {
                Label(detail.candidate.importNote ?? "Der Steckbrief ist noch unvollständig.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                if canEdit, let source = detail.sources.first {
                    Button("Auf diesem Gerät auslesen", systemImage: "iphone.and.arrow.forward") {
                        captureSource = source
                    }
                }
            } footer: {
                Text("Die Seite wird hier in der App geöffnet. Was du dort siehst, wird an deinen Server geschickt und in den Steckbrief übersetzt.")
            }
        }
    }

    @ViewBuilder
    private func priceSection(_ detail: CandidateDetail) -> some View {
        let tripID = detail.candidate.tripId
        let current = detail.prices.first { $0.tripId == tripID } ?? detail.prices.first
        Section("Preis") {
            if let current, let text = Format.price(totalCents: current.totalCents, rangeMaxCents: current.rangeMaxCents, kind: current.kind) {
                VStack(alignment: .leading, spacing: 2) {
                    if current.tripId == tripID {
                        Text(text).font(.title3.weight(.semibold))
                    } else {
                        // Same wording as in the list: a link price is never shown as the price of the trip.
                        Text("Preis für euren Zeitraum noch offen").font(.headline)
                        Text("Im geteilten Link stand: \(text)").font(.subheadline)
                    }
                    // A price for other dates or another party says nothing about this trip's cost per person.
                    if current.tripId == tripID,
                       let perNight = Format.perPersonNight(totalCents: current.totalCents, persons: current.persons, nights: current.nights) {
                        Text(perNight).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(priceContext(current)).font(.footnote).foregroundStyle(.secondary)
                    if current.tripId != tripID {
                        Text("Dieser Preis gilt für einen anderen Zeitraum als eure Reise.").font(.footnote).foregroundStyle(.orange)
                    }
                    if current.tripId == tripID, current.available == false {
                        Label("Im Reisezeitraum nicht verfügbar", systemImage: "calendar.badge.exclamationmark")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                    }
                }
            } else {
                Text("Noch kein Preis bekannt").foregroundStyle(.secondary)
            }
            // What the price is made of, what comes on top and what it used to be: folded away until asked for.
            let lines = current?.breakdown ?? []
            let extras = detail.listing.profile.price?.extraCosts ?? []
            let earlier = detail.prices.filter { $0.id != current?.id && $0.totalCents != nil }
            if open.contains("price") {
                ForEach(lines, id: \.self) { line in
                    LabeledContent(line.item, value: line.amountCents.map { Format.euro(cents: $0) } ?? "nicht beziffert")
                }
                ForEach(extras, id: \.self) { cost in
                    LabeledContent(cost.item, value: cost.amountEur.map { Format.euro($0) } ?? (cost.note ?? "zusätzlich"))
                }
                ForEach(earlier) { price in
                    LabeledContent("Früher, \(price.capturedAt.formatted(date: .abbreviated, time: .omitted))",
                                   value: Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            if !lines.isEmpty || !extras.isEmpty || !earlier.isEmpty {
                more("price", [lines.isEmpty ? nil : "Aufschlüsselung", extras.isEmpty ? nil : "Nebenkosten",
                               earlier.isEmpty ? nil : (earlier.count == 1 ? "1 früherer Preis" : "\(earlier.count) frühere Preise")].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    private func priceContext(_ price: PriceSnapshot) -> String {
        var parts: [String] = []
        if let range = Format.dateRange(price.startDate, price.endDate) { parts.append(range) }
        if let persons = price.persons { parts.append("\(persons) Personen") }
        let origin = switch price.capture {
        case "device": "auf dem Gerät gelesen"
        case "manual": "von Hand eingetragen"
        case "auto": "automatisch geprüft"
        default: "aus dem Inserat"
        }
        parts.append("\(origin) am \(price.capturedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    // MARK: Profile rows. Unknown values are left out instead of showing a dash for every gap.

    @ViewBuilder
    private func fact(_ label: String, _ value: String?, _ path: String, _ profile: Profile) -> some View {
        if let value, !value.isEmpty {
            LabeledContent {
                Text(value)
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                    if profile.isUncertain(path) { UncertainMark() }
                }
            }
        }
    }

    @ViewBuilder
    private func number(_ label: String, _ value: Double?, _ path: String, _ profile: Profile, unit: String = "") -> some View {
        fact(label, value.map { Format.number($0) + unit }, path, profile)
    }

    @ViewBuilder
    private func distance(_ label: String, _ meters: Double?, _ path: String, _ profile: Profile) -> some View {
        fact(label, meters.map(Format.distance(meters:)), path, profile)
    }
}

/// Marks a value that came from free text or was contradictory in the advert.
struct UncertainMark: View {
    var body: some View {
        Image(systemName: "questionmark.circle")
            .foregroundStyle(.orange)
            .font(.footnote)
            .accessibilityLabel("unsicher, bitte prüfen")
    }
}

/// One stay to read on the device.
struct StayCheck: Identifiable {
    var url: String
    var start: String
    var end: String
    var id: String { "\(start)|\(end)" }
}
