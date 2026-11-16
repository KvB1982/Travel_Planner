import SwiftUI
import TravelPlannerKit

/// The standardised profile of one offer, with voting and comments.
struct CandidateDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let candidateID: String
    /// Called after the offer was deleted, so the surrounding view can close it.
    var onDeleted: () -> Void = {}

    @State private var detail: CandidateDetail?
    @State private var error: String?
    @State private var comment = ""
    @State private var captureSource: ListingSource?
    @State private var actionError: String?
    @State private var confirmDelete = false
    @State private var showReviews = false
    @State private var showAddSource = false
    @State private var showMove = false
    @State private var showCorrection = false
    @State private var mapTarget: MapTarget?
    @State private var sentNote: String?
    @State private var sourceLink = ""
    @AppStorage(Settings.showWarnings) private var showWarnings = false

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let error {
                ContentUnavailableView("Nicht geladen", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(item: $mapTarget) { target in
            LocationMapView(title: target.title, hint: target.hint, place: target.place)
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
                        expectedPictures: expectedPictures(for: source)) { pictures, reviews in
                sentNote = "Gesendet: \(pictures == 1 ? "1 Bild" : "\(pictures) Bilder") und \(reviews == 1 ? "1 Bewertung" : "\(reviews) Bewertungen") im Wortlaut. Der Server wertet das jetzt aus, das dauert bis zu einer Minute."
            }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        do {
            detail = try await backend.candidate(candidateID)
            error = nil
        } catch is CancellationError {
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
            }

            importSection(detail, canEdit: canEdit)

            hintsSection(detail, canEdit: canEdit)

            if let verdict = detail.criteria, !(verdict.results ?? []).isEmpty {
                CriteriaSection(verdict: verdict, canEdit: canEdit) { checks in
                    perform { try await $0.setCriteriaChecks(candidateId: candidateID, checks: checks) }
                }
            }

            // High up on purpose: where the house is decides more than most of the rows below.
            LocationSection(detail: detail) { mapTarget = $0 }

            Section("Deine Stimme") {
                let mine = detail.votes.entries.first { $0.userId == model.user?.id }
                Picker("Deine Stimme", selection: Binding(
                    get: { mine?.verdict },
                    set: { verdict in
                        if let verdict { perform { try await $0.vote(candidateId: candidateID, verdict: verdict, veto: verdict == .no && (mine?.veto ?? false)) } }
                    })) {
                    ForEach(Verdict.allCases, id: \.self) { verdict in
                        Text(verdict.label).tag(Verdict?.some(verdict))
                    }
                }
                .pickerStyle(.segmented)
                if mine?.verdict == .no {
                    Toggle("Veto: für mich ausgeschlossen", isOn: Binding(
                        get: { mine?.veto ?? false },
                        set: { veto in perform { try await $0.vote(candidateId: candidateID, verdict: .no, veto: veto) } }))
                }
                ForEach(detail.votes.entries) { entry in
                    LabeledContent(entry.name, value: entry.veto ? "Veto" : entry.verdict.label)
                }
            }

            priceSection(detail)

            if let reviews = detail.reviews, !reviews.isEmpty {
                ReviewsSection(reviews: reviews, rating: profile.rating, showAll: { showReviews = true },
                               readOnDevice: canEdit ? detail.sources.first.map { source in { captureSource = source } } : nil)
            }

            Section("Eckdaten") {
                fact("Art", profile.objectType ?? detail.listing.kind.label, "objectType", profile)
                number("Gäste", profile.maxGuests, "maxGuests", profile)
                number("Schlafzimmer", profile.bedrooms, "bedrooms", profile)
                number("Betten", profile.beds, "beds", profile)
                number("Schlafplätze", profile.sleepingPlaces, "sleepingPlaces", profile)
                number("Bäder", profile.bathrooms, "bathrooms", profile)
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

            if detail.listing.kind != .vacationHome, let trip = profile.packageTrip {
                Section(detail.listing.kind.label) {
                    number("Sterne", trip.hotelStars, "packageTrip.hotelStars", profile)
                    fact("Verpflegung", trip.board, "packageTrip.board", profile)
                    fact("Zimmer", trip.roomType, "packageTrip.roomType", profile)
                    fact("Abflug", trip.departureAirport, "packageTrip.departureAirport", profile)
                    number("Dauer", trip.durationDays, "packageTrip.durationDays", profile, unit: " Tage")
                    fact("Veranstalter", trip.tourOperator, "packageTrip.tourOperator", profile)
                    if let transfer = trip.transferIncluded { LabeledContent("Transfer", value: transfer ? "inklusive" : "nicht inklusive") }
                }
            }

            Section {
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
            } header: {
                Text("Ausstattung")
            } footer: {
                Text("„Unbekannt“ heißt: Das Inserat sagt dazu nichts. Es wird nichts geschätzt.")
            }

            if let distances = profile.distances {
                Section("Entfernungen") {
                    distance("Strand", distances.beachM, "distances.beachM", profile)
                    distance("Meer", distances.seaM, "distances.seaM", profile)
                    distance("Ort", distances.townM, "distances.townM", profile)
                    distance("Einkaufen", distances.shopM, "distances.shopM", profile)
                    distance("Restaurant", distances.restaurantM, "distances.restaurantM", profile)
                    number("Flughafen", distances.airportKm, "distances.airportKm", profile, unit: " km")
                }
            }

            Section("Regeln") {
                fact("Anreise ab", profile.rules?.checkInFrom, "rules.checkInFrom", profile)
                fact("Abreise bis", profile.rules?.checkOutUntil, "rules.checkOutUntil", profile)
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
                ForEach(detail.comments) { comment in
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
                ForEach(current.breakdown ?? [], id: \.self) { line in
                    LabeledContent(line.item, value: line.amountCents.map { Format.euro(cents: $0) } ?? "nicht beziffert")
                }
                let earlier = detail.prices.filter { $0.id != current.id && $0.totalCents != nil }
                if !earlier.isEmpty {
                    DisclosureGroup("Frühere Preise (\(earlier.count))") {
                        ForEach(earlier) { price in
                            LabeledContent(price.capturedAt.formatted(date: .abbreviated, time: .omitted),
                                           value: Format.price(totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind) ?? "")
                        }
                    }
                }
            } else {
                Text("Noch kein Preis bekannt").foregroundStyle(.secondary)
            }
            ForEach(detail.listing.profile.price?.extraCosts ?? [], id: \.self) { cost in
                LabeledContent(cost.item, value: cost.amountEur.map { Format.euro($0) } ?? (cost.note ?? "zusätzlich"))
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
