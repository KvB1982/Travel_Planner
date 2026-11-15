import SwiftUI
import TravelPlannerKit

/// The standardised profile of one offer, with voting and comments.
struct CandidateDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let candidateID: String

    @State private var detail: CandidateDetail?
    @State private var error: String?
    @State private var comment = ""
    @State private var captureSource: ListingSource?

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
            while !Task.isCancelled, detail?.candidate.importStatus == .pending {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await load()
            }
        }
        .sheet(item: $captureSource) { source in
            CaptureView(source: source, candidateID: candidateID)
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
                self.error = model.message(for: error)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: CandidateDetail) -> some View {
        let profile = detail.listing.profile
        let canEdit = detail.role.canEdit
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if detail.listing.coverImageUrl != nil {
                        CoverImage(url: detail.listing.coverImageUrl)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text(detail.listing.title ?? "Angebot").font(.title2.weight(.semibold))
                    Text(headline(detail)).foregroundStyle(.secondary)
                    if let summary = profile.summary { Text(summary).font(.callout) }
                }
                .listRowSeparator(.hidden)
            }

            importSection(detail, canEdit: canEdit)

            if let warnings = profile.warnings, !warnings.isEmpty {
                Section("Hinweise") {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

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

            Section("Eckdaten") {
                fact("Art", profile.objectType ?? detail.listing.kind.label, "objectType", profile)
                number("Gäste", profile.maxGuests, "maxGuests", profile)
                number("Schlafzimmer", profile.bedrooms, "bedrooms", profile)
                number("Betten", profile.beds, "beds", profile)
                number("Schlafplätze", profile.sleepingPlaces, "sleepingPlaces", profile)
                number("Bäder", profile.bathrooms, "bathrooms", profile)
                number("Wohnfläche", profile.livingAreaSqm, "livingAreaSqm", profile, unit: " m²")
                number("Grundstück", profile.plotSqm, "plotSqm", profile, unit: " m²")
                if let rating = profile.rating, let value = rating.value {
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
                Section("Lage") {
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

            Section("Quellen") {
                ForEach(detail.sources) { source in
                    if let url = URL(string: source.url) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Bei \(Format.platformName(source.platform)) öffnen", systemImage: "safari")
                        }
                    }
                }
                LabeledContent("Steckbrief gefüllt", value: "\(detail.listing.fillPercent) %")
            }

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
                    Text(text).font(.title3.weight(.semibold))
                    if let perNight = Format.perPersonNight(totalCents: current.totalCents, persons: current.persons, nights: current.nights) {
                        Text(perNight).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(priceContext(current)).font(.footnote).foregroundStyle(.secondary)
                    if current.tripId != tripID {
                        Text("Dieser Preis wurde nicht für eure Reise abgefragt.").font(.footnote).foregroundStyle(.orange)
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
