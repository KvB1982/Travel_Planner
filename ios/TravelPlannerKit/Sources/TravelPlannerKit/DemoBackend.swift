import Foundation

/// Sample data that behaves like the server, for trying the app before the backend is reachable.
/// Nothing leaves the device and nothing is kept after the app closes.
public actor DemoBackend: TravelBackend {
    private let user = User(id: "u-1", name: "Du")
    private var trips: [Trip]
    private var details: [String: CandidateDetail]
    private var order: [String]
    private var counter = 100

    public init() {
        let trip1 = Trip(id: "t-1", title: "Pfingstferien 2027", region: "Toskana", adults: 4, children: 4, pets: 0, budgetTotalCents: 600_000, role: .organizer)
        let trip2 = Trip(id: "t-2", title: "Sommerurlaub 2027", region: "Dänemark, Nordsee", adults: 6, children: 5, pets: 1, role: .member)
        trips = [trip1, trip2]
        let samples = DemoBackend.samples()
        details = Dictionary(uniqueKeysWithValues: samples.map { ($0.candidate.id, $0) })
        order = samples.map(\.candidate.id)
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func detail(_ id: String) throws -> CandidateDetail {
        guard let detail = details[id] else { throw APIError(status: 404, code: "not_found", message: "Dieses Angebot gibt es nicht mehr.") }
        return detail
    }

    public func me() async throws -> User { user }

    /// Sample pictures are drawn by the app itself (`demo://photo/<n>`), so the demo needs no network.
    public nonisolated func imageRequest(for address: String) -> URLRequest? {
        URL(string: address).map { URLRequest(url: $0) }
    }

    public func logout() async throws {}

    public func trips() async throws -> [Trip] {
        trips.map { trip in
            var trip = trip
            let own = details.values.filter { $0.candidate.tripId == trip.id }
            trip.candidateCount = own.count
            trip.favoriteCount = own.filter { $0.candidate.status == .favorite }.count
            return trip
        }
    }

    public func trip(_ id: String) async throws -> TripDetail {
        guard let trip = trips.first(where: { $0.id == id }) else { throw APIError(status: 404, code: "not_found", message: "Diese Reise gibt es nicht.") }
        let options = id == "t-1"
            ? [DateOption(id: "d-1", label: "Pfingsten", startDate: "2027-05-15", endDate: "2027-05-29")]
            : [DateOption(id: "d-2", label: "Erste Hälfte", startDate: "2027-07-31", endDate: "2027-08-14"),
               DateOption(id: "d-3", label: "Zweite Hälfte", startDate: "2027-08-14", endDate: "2027-08-28")]
        let members = [Member(id: "u-1", name: "Du", role: trip.role ?? .member), Member(id: "u-2", name: "Anna", role: .member), Member(id: "u-3", name: "Jonas", role: .guest)]
        return TripDetail(trip: trip, role: trip.role ?? .member, members: members, dateOptions: options)
    }

    public func createTrip(_ new: NewTrip) async throws -> Trip {
        let trip = Trip(id: nextID("t"), title: new.title, region: new.region, adults: new.adults, children: new.children, pets: new.pets,
                        budgetTotalCents: new.budgetTotalCents, role: .organizer)
        trips.insert(trip, at: 0)
        return trip
    }

    public func createInvite(tripId: String, role: MemberRole) async throws -> Invite {
        Invite(token: "demo", url: "https://reisen.example/einladung/demo", role: role, expiresAt: nil, maxUses: 1)
    }

    public func candidates(tripId: String) async throws -> [CandidateSummary] {
        order.compactMap { details[$0] }.filter { $0.candidate.tripId == tripId }.map { detail in
            let profile = detail.listing.profile
            let price = detail.prices.first
            return CandidateSummary(
                id: detail.candidate.id, status: detail.candidate.status, importStatus: detail.candidate.importStatus,
                importNote: detail.candidate.importNote, tags: detail.candidate.tags, addedBy: "Anna", createdAt: detail.candidate.createdAt,
                listing: ListingSummary(id: detail.listing.id, kind: detail.listing.kind, title: detail.listing.title, place: detail.listing.place,
                                        country: detail.listing.country, lat: detail.listing.lat, lon: detail.listing.lon,
                                        coverImageUrl: detail.listing.coverImageUrl, fillPercent: detail.listing.fillPercent,
                                        maxGuests: profile.maxGuests, bedrooms: profile.bedrooms, bathrooms: profile.bathrooms,
                                        rating: profile.rating, platforms: detail.sources.map(\.platform),
                                        photoCount: detail.photos.map { Double($0.count) },
                                        region: profile.region),
                price: price.map { PriceSummary(totalCents: $0.totalCents, rangeMaxCents: $0.rangeMaxCents, kind: $0.kind, nights: $0.nights,
                                                persons: $0.persons, startDate: $0.startDate, endDate: $0.endDate,
                                                forThisTrip: $0.tripId == tripId, capturedAt: $0.capturedAt, available: $0.available) },
                votes: VoteTally(yes: detail.votes.yes, maybe: detail.votes.maybe, no: detail.votes.no, vetoes: detail.votes.vetoes),
                myVote: detail.votes.entries.first { $0.userId == user.id }.map { Vote(verdict: $0.verdict, veto: $0.veto) })
        }
    }

    public func candidate(_ id: String) async throws -> CandidateDetail { try detail(id) }

    public func importLink(tripId: String, url: String, html: String?) async throws -> ImportResult {
        if let existing = details.values.first(where: { $0.candidate.tripId == tripId && $0.sources.contains { $0.url == url } }) {
            return ImportResult(candidateId: existing.candidate.id, duplicate: true)
        }
        let id = nextID("c")
        let host = URL(string: url)?.host ?? ""
        let platform = ["airbnb", "novasol", "check24", "casamundo", "booking"].first { host.contains($0) } ?? (host.contains("fewo-direkt") || host.contains("vrbo") ? "vrbo" : "other")
        let blocked = platform == "vrbo" || platform == "casamundo"
        var profile = Profile()
        profile.title = "Neues Angebot (\(Format.platformName(platform)))"
        let listing = Listing(id: nextID("l"), title: profile.title, profile: profile, fillPercent: 4)
        let record = CandidateRecord(
            id: id, tripId: tripId, listingId: listing.id, importStatus: html == nil && blocked ? .partial : .failed,
            importNote: html == nil && blocked
                ? "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen."
                : "In der Demo wird nichts ausgelesen. Mit dem echten Server füllt sich der Steckbrief von selbst.")
        details[id] = CandidateDetail(candidate: record, role: .organizer, listing: listing,
                                      sources: [ListingSource(id: nextID("s"), platform: platform, url: url, canonicalUrl: url)])
        order.insert(id, at: 0)
        return ImportResult(candidateId: id, duplicate: false, platform: platform)
    }

    public func checkTrip(tripId: String) async throws -> TripCheck {
        let offers = order.compactMap { details[$0] }.filter { $0.candidate.tripId == tripId && $0.candidate.status != .rejected }
        for offer in offers { try await refresh(candidateId: offer.candidate.id) }
        return TripCheck(checks: offers.map { offer in
            let source = offer.sources.first
            let blocked = source?.platform == "vrbo" || source?.platform == "casamundo"
            return .init(candidateId: offer.candidate.id, platform: source?.platform, mode: blocked ? "device" : "server",
                         needsDevice: blocked, checkUrl: blocked ? source?.url : nil)
        })
    }

    public func capture(candidateId: String, html: String, sourceId: String?, forTrip: Bool) async throws {
        var detail = try detail(candidateId)
        if forTrip {
            detail.candidate.importNote = "Für den Reisezeitraum auf dem Gerät geprüft (\(html.utf8.count / 1024) KB). In der Demo wird die Seite nicht ausgewertet."
            details[candidateId] = detail
            return
        }
        if let sourceId, let index = detail.sources.firstIndex(where: { $0.id == sourceId }) {
            detail.sources[index].read = true
            detail.sources[index].needsDevice = false
        } else {
            detail.candidate.importStatus = .failed
            detail.candidate.importNote = "Seite auf dem Gerät gelesen (\(html.utf8.count / 1024) KB). In der Demo wird sie nicht ausgewertet."
        }
        details[candidateId] = detail
    }

    public func searchOtherPlatforms(candidateId: String) async throws {
        var detail = try detail(candidateId)
        detail.otherPlatforms = OtherPlatforms(status: .done, searchedAt: .now, note: "Beispieltreffer. Mit dem echten Server sucht hier eine KI im Netz.", suggestions: [
            .init(id: nextID("v"), url: "https://www.fewo-direkt.de/", platform: "vrbo", title: detail.listing.title.map { "\($0) (FeWo-direkt)" },
                  reason: "Gleicher Ort, gleiche Zahl an Schlafzimmern, Pool.", confidence: .high),
            .init(id: nextID("v"), url: "https://www.casamundo.de/", platform: "casamundo", title: "Landhaus mit Pool",
                  reason: "Gleicher Ort, aber ein Schlafzimmer weniger.", confidence: .low),
        ])
        details[candidateId] = detail
    }

    public func decide(candidateId: String, suggestionId: String, accept: Bool) async throws {
        var detail = try detail(candidateId)
        guard var other = detail.otherPlatforms, let index = other.suggestions?.firstIndex(where: { $0.id == suggestionId }),
              let suggestion = other.suggestions?[index] else {
            throw APIError(status: 404, code: "not_found", message: "Diesen Vorschlag gibt es nicht mehr.")
        }
        other.suggestions?[index].status = accept ? .accepted : .rejected
        detail.otherPlatforms = other
        if accept {
            detail.sources.append(ListingSource(id: nextID("s"), platform: suggestion.platform, url: suggestion.url, canonicalUrl: suggestion.url,
                                                primary: false, read: false, needsDevice: true, title: suggestion.title))
        }
        details[candidateId] = detail
    }

    public func addSource(candidateId: String, url: String) async throws {
        var detail = try detail(candidateId)
        guard !detail.sources.contains(where: { $0.url == url }) else { return }
        detail.sources.append(ListingSource(id: nextID("s"), platform: "other", url: url, canonicalUrl: url, primary: false, read: false, needsDevice: true))
        details[candidateId] = detail
    }

    public func removeSource(candidateId: String, sourceId: String) async throws {
        var detail = try detail(candidateId)
        guard let index = detail.sources.firstIndex(where: { $0.id == sourceId }) else { return }
        guard index > 0 else { throw APIError(status: 409, code: "primary_source", message: "Die erste Quelle lässt sich nicht entfernen.") }
        detail.sources.remove(at: index)
        details[candidateId] = detail
    }

    /// In the sample data a check finds one offer booked out, to show what that looks like.
    public func refresh(candidateId: String) async throws {
        var detail = try detail(candidateId)
        guard candidateId == "c-2", !detail.prices.isEmpty else { return }
        detail.prices[0].available = false
        detail.prices[0].capturedAt = .now
        details[candidateId] = detail
    }

    public func setHiddenWarnings(candidateId: String, hidden: [String]) async throws {
        var detail = try detail(candidateId)
        detail.warnings = (detail.listing.profile.warnings ?? []).map { Hint(text: $0, hidden: hidden.contains($0)) }
        details[candidateId] = detail
    }

    public func delete(candidateId: String) async throws {
        _ = try detail(candidateId)
        details[candidateId] = nil
        order.removeAll { $0 == candidateId }
    }

    public func setStatus(candidateId: String, status: CandidateStatus) async throws {
        var detail = try detail(candidateId)
        detail.candidate.status = status
        details[candidateId] = detail
    }

    public func vote(candidateId: String, verdict: Verdict, veto: Bool) async throws {
        var detail = try detail(candidateId)
        var entries = detail.votes.entries.filter { $0.userId != user.id }
        entries.append(VoteEntry(userId: user.id, name: user.name, verdict: verdict, veto: veto))
        detail.votes = VoteOverview(yes: entries.filter { $0.verdict == .yes }.count, maybe: entries.filter { $0.verdict == .maybe }.count,
                                    no: entries.filter { $0.verdict == .no }.count, vetoes: entries.filter(\.veto).count, entries: entries)
        details[candidateId] = detail
    }

    public func comment(candidateId: String, body: String) async throws {
        var detail = try detail(candidateId)
        detail.comments.append(Comment(id: nextID("k"), body: body, userId: user.id, name: user.name))
        details[candidateId] = detail
    }

    // MARK: Sample offers

    private static func samples() -> [CandidateDetail] {
        func home(_ id: String, trip: String, title: String, place: String, country: String, lat: Double, lon: Double, platform: String,
                  guests: Double, bedrooms: Double, baths: Double, sqm: Double?, total: Int, start: String, end: String, nights: Int, persons: Int,
                  status: CandidateStatus, amenities: [String: Bool?], uncertain: [String] = [], warnings: [String] = [],
                  votes: [VoteEntry] = [], comments: [Comment] = [], fill: Int) -> CandidateDetail {
            var profile = Profile()
            profile.kind = .vacationHome
            profile.title = title; profile.objectType = "Ferienhaus"; profile.place = place; profile.country = country
            profile.region = country == "Italien" ? "Toskana" : (country == "Dänemark" ? "Jütland" : nil)
            profile.lat = lat; profile.lon = lon
            profile.maxGuests = guests; profile.bedrooms = bedrooms; profile.bathrooms = baths; profile.livingAreaSqm = sqm
            profile.sleepingPlaces = guests; profile.amenities = amenities
            profile.rating = Rating(value: 4.7, scale: 5, count: 38)
            var distances = Profile.Distances(); distances.beachM = 450; distances.shopM = 1200; distances.townM = 2500; distances.airportKm = 85
            profile.distances = distances
            var rules = Profile.Rules(); rules.checkInFrom = "16:00"; rules.checkOutUntil = "10:00"; rules.arrivalDays = "Samstag"
            profile.rules = rules
            profile.cancellation = "Kostenlose Stornierung bis 60 Tage vor Anreise"
            profile.summary = "Freistehendes Haus mit großem Garten, ruhig gelegen, gut geeignet für zwei Familien."
            profile.highlights = ["Großer Garten", "Zwei Wohnbereiche"]
            profile.warnings = warnings
            profile.uncertain = uncertain
            let number = Int(id.dropFirst(2)) ?? 1
            let photos = (0..<(number == 3 ? 0 : 6 + number * 3)).map { index in
                Photo(id: "\(id)-\(index)", url: "demo://photo/\(number * 100 + index)?full=1", thumbUrl: "demo://photo/\(number * 100 + index)",
                      width: index % 4 == 3 ? 3000 : 4000, height: index % 4 == 3 ? 4000 : 3000)
            }
            let listing = Listing(id: "l-\(id)", title: title, place: place, country: country, lat: lat, lon: lon,
                                  coverImageUrl: photos.first?.thumbUrl, profile: profile, fillPercent: fill)
            let record = CandidateRecord(id: id, tripId: trip, listingId: listing.id, status: status)
            let price = PriceSnapshot(id: "p-\(id)", tripId: trip, startDate: start, endDate: end, nights: nights, persons: persons, totalCents: total,
                                      breakdown: [.init(item: "Miete", amountCents: total - 18_000), .init(item: "Endreinigung", amountCents: 18_000)])
            let older = PriceSnapshot(id: "p0-\(id)", tripId: trip, startDate: start, endDate: end, nights: nights, persons: persons,
                                      totalCents: total + 24_000, capturedAt: .now.addingTimeInterval(-9 * 86_400))
            return CandidateDetail(
                candidate: record, role: .organizer, listing: listing,
                sources: [ListingSource(id: "s-\(id)", platform: platform, url: "https://example.com/\(id)", canonicalUrl: "https://example.com/\(id)")],
                prices: [price, older],
                votes: VoteOverview(yes: votes.filter { $0.verdict == .yes }.count, maybe: votes.filter { $0.verdict == .maybe }.count,
                                    no: votes.filter { $0.verdict == .no }.count, vetoes: votes.filter(\.veto).count, entries: votes),
                comments: comments, photos: photos, otherPlatforms: OtherPlatforms(),
                reviews: number == 3 ? nil : Reviews(
                    summary: "Gäste loben vor allem die ruhige Lage, den großen Garten und die hilfsbereiten Vermieter. Die Küche gilt als gut ausgestattet. Mehrfach erwähnt werden die schmale Zufahrt und dass es im Obergeschoss im Hochsommer warm wird.",
                    positives: ["Ruhige Lage mit Weitblick", "Großer Garten, Pool gepflegt", "Vermieter schnell erreichbar", "Küche gut ausgestattet"],
                    negatives: ["Schmale, steile Zufahrt", "Obergeschoss im Sommer warm", "WLAN im Garten schwach"],
                    basedOn: 38, generatedAt: .now,
                    items: [
                        .init(id: "r-\(id)-1", author: "Familie M.", date: "2026-08-22", rating: 5, scale: 5, title: "Perfekt für zwei Familien",
                              text: "Wir waren mit acht Personen dort und hatten reichlich Platz. Der Pool war jeden Tag sauber, die Kinder wollten gar nicht mehr raus. Die Vermieterin hat uns frisches Gemüse vorbeigebracht.",
                              stayType: "Familie mit Kindern", platform: platform),
                        .init(id: "r-\(id)-2", author: "Thomas", date: "2026-07-05", rating: 4, scale: 5,
                              text: "Sehr schönes Haus, nur die Zufahrt ist mit einem großen Auto abenteuerlich. Oben wird es nachts warm, Ventilatoren sind vorhanden.",
                              ownerReply: "Danke für den Hinweis, wir haben inzwischen im Obergeschoss eine Klimaanlage nachgerüstet.", platform: platform),
                        .init(id: "r-\(id)-3", author: "Giulia", date: "2026-05-30", rating: 5, scale: 5, text: "Posto meraviglioso, casa pulitissima e proprietari gentilissimi.",
                              language: "it", translatedText: "Wunderschöner Ort, sehr sauberes Haus und überaus freundliche Eigentümer.", platform: platform),
                    ]))
        }

        var blocked = home("c-3", trip: "t-1", title: "Podere mit Blick auf San Gimignano", place: "San Gimignano", country: "Italien",
                           lat: 43.4677, lon: 11.0432, platform: "vrbo", guests: 10, bedrooms: 5, baths: 3, sqm: nil, total: 512_000,
                           start: "2027-05-15", end: "2027-05-29", nights: 14, persons: 8, status: .new, amenities: [:], fill: 18)
        blocked.candidate.importStatus = .partial
        blocked.candidate.importNote = "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen."
        blocked.sources = [ListingSource(id: "s-c-3", platform: "vrbo", url: "https://www.fewo-direkt.de/", canonicalUrl: "https://www.fewo-direkt.de/")]
        blocked.prices = []

        return [
            home("c-1", trip: "t-1", title: "Casa Olivia mit Pool", place: "Castellina in Chianti", country: "Italien", lat: 43.4701, lon: 11.2893,
                 platform: "airbnb", guests: 9, bedrooms: 4, baths: 3, sqm: 210, total: 486_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .favorite,
                 amenities: ["pool": true, "poolHeated": false, "airConditioning": true, "wifi": true, "dishwasher": true, "washingMachine": true, "grill": true, "parking": true, "cot": true, "highChair": true, "petsAllowed": false],
                 uncertain: ["livingAreaSqm", "amenities.grill"],
                 votes: [VoteEntry(userId: "u-2", name: "Anna", verdict: .yes), VoteEntry(userId: "u-3", name: "Jonas", verdict: .maybe)],
                 comments: [Comment(id: "k-1", body: "Der Pool ist nicht eingezäunt, das müssten wir mit den Kleinen klären.", createdAt: .now.addingTimeInterval(-86_400), userId: "u-2", name: "Anna")],
                 fill: 86),
            home("c-2", trip: "t-1", title: "Villa Il Poggio", place: "Greve in Chianti", country: "Italien", lat: 43.5846, lon: 11.3166,
                 platform: "novasol", guests: 8, bedrooms: 4, baths: 2, sqm: 180, total: 539_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .shortlist,
                 amenities: ["pool": true, "airConditioning": false, "wifi": true, "dishwasher": true, "washingMachine": true, "fireplace": true, "parking": true, "petsAllowed": true],
                 warnings: ["Das Inserat nennt 8 Gäste, die Reise hat 8 Personen: kein Spielraum.", "Die Endreinigung ist im Preis nicht enthalten."],
                 votes: [VoteEntry(userId: "u-2", name: "Anna", verdict: .no, veto: false)], fill: 78),
            blocked,
            home("c-5", trip: "t-1", title: "Villa Gradina am Strand", place: "Vela Luka", country: "Kroatien", lat: 42.9614, lon: 16.7189,
                 platform: "airbnb", guests: 10, bedrooms: 5, baths: 4, sqm: 230, total: 574_000, start: "2027-05-15", end: "2027-05-29", nights: 14,
                 persons: 8, status: .new,
                 amenities: ["pool": true, "airConditioning": true, "wifi": true, "dishwasher": true, "grill": true, "seaView": true, "parking": true],
                 fill: 74),
            home("c-4", trip: "t-2", title: "Reetdachhaus hinter der Düne", place: "Henne Strand", country: "Dänemark", lat: 55.7372, lon: 8.1832,
                 platform: "novasol", guests: 12, bedrooms: 6, baths: 3, sqm: 240, total: 398_000, start: "2027-07-31", end: "2027-08-14", nights: 14,
                 persons: 11, status: .new,
                 amenities: ["pool": true, "poolHeated": true, "wifi": true, "dishwasher": true, "washingMachine": true, "sauna": true, "hotTub": true, "fireplace": true, "parking": true, "evCharger": true, "petsAllowed": true],
                 fill: 91),
        ]
    }
}
