import XCTest
@testable import TravelPlannerKit

final class DecodingTests: XCTestCase {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIClient.decoder.decode(type, from: Data(json.utf8))
    }

    func testTripListRow() throws {
        let trip = try decode(Trip.self, """
        {"id":"0a8f2b1e-0000-4000-8000-000000000001","title":"Pfingsten","region":null,"adults":4,"children":3,"pets":0,
         "budgetTotalCents":null,"status":"planning","voteDeadline":null,"createdBy":"x","createdAt":"2026-11-15T09:17:52.123Z",
         "role":"organizer","candidateCount":7,"favoriteCount":2}
        """)
        XCTAssertEqual(trip.persons, 7)
        XCTAssertEqual(trip.role, .organizer)
        XCTAssertEqual(trip.candidateCount, 7)
    }

    func testDatesWithoutFraction() throws {
        XCTAssertNotNil(APIClient.parseDate("2026-11-15T09:17:52Z"))
        XCTAssertNotNil(APIClient.parseDate("2026-11-15T09:17:52.004Z"))
        XCTAssertNil(APIClient.parseDate("gestern"))
    }

    func testCandidateSummary() throws {
        let row = try decode(CandidateSummary.self, """
        {"id":"c1","status":"favorite","importStatus":"partial","importNote":"Gesperrt","tags":["pool"],"addedBy":"Anna",
         "createdAt":"2026-11-15T09:17:52.123Z",
         "listing":{"id":"l1","kind":"vacation_home","title":"Casa","place":null,"country":"Italien","lat":43.4,"lon":11.2,
           "coverImageUrl":null,"fillPercent":62,"maxGuests":8,"bedrooms":4,"bathrooms":2.5,
           "rating":{"value":4.8,"scale":5,"count":31},"platforms":["airbnb","vrbo"]},
         "price":{"totalCents":486000,"rangeMaxCents":null,"kind":"total","nights":14,"persons":8,"startDate":"2027-05-15",
           "endDate":"2027-05-29","forThisTrip":true,"capturedAt":"2026-11-15T09:17:52.123Z"},
         "votes":{"yes":2,"maybe":1,"no":0,"vetoes":0},
         "myVote":{"tripListingId":"c1","userId":"u1","verdict":"yes","veto":false,"updatedAt":"2026-11-15T09:17:52.123Z"}}
        """)
        XCTAssertEqual(row.listing.bathrooms, 2.5)
        XCTAssertEqual(row.myVote?.verdict, .yes)
        XCTAssertEqual(row.votes.total, 3)
        XCTAssertEqual(row.price?.totalCents, 486_000)
    }

    func testCandidateWithoutPriceOrVote() throws {
        let row = try decode(CandidateSummary.self, """
        {"id":"c1","status":"new","importStatus":"pending","importNote":null,"tags":[],"addedBy":"Anna","createdAt":"2026-11-15T09:17:52.123Z",
         "listing":{"id":"l1","kind":"hotel","title":null,"place":null,"country":null,"lat":null,"lon":null,"coverImageUrl":null,
           "fillPercent":0,"maxGuests":null,"bedrooms":null,"bathrooms":null,"rating":{"value":null,"scale":null,"count":null},"platforms":["booking"]},
         "price":null,"votes":{"yes":0,"maybe":0,"no":0,"vetoes":0},"myVote":null}
        """)
        XCTAssertNil(row.price)
        XCTAssertNil(row.myVote)
        XCTAssertEqual(row.listing.kind, .hotel)
    }

    func testCandidateDetailWithProfile() throws {
        let detail = try decode(CandidateDetail.self, """
        {"candidate":{"id":"c1","tripId":"t1","listingId":"l1","status":"new","importStatus":"ready","importNote":null,"addedBy":"u1",
           "rejectionReason":null,"notes":null,"tags":[],"createdAt":"2026-11-15T09:17:52.123Z"},
         "role":"member",
         "listing":{"id":"l1","kind":"vacation_home","title":"Casa","place":"Greve","country":"Italien","lat":null,"lon":null,"coverImageUrl":null,
           "fillPercent":40,"createdAt":"2026-11-15T09:17:52.123Z","updatedAt":"2026-11-15T09:17:52.123Z",
           "profile":{"kind":"vacation_home","title":"Casa","objectType":null,"place":"Greve","region":null,"country":"Italien","lat":null,"lon":null,
             "maxGuests":8,"bedrooms":4,"beds":null,"sleepingPlaces":null,"bedDetails":[{"room":"Zimmer 1","beds":"1 Doppelbett"}],
             "bathrooms":2,"livingAreaSqm":180,"plotSqm":null,"yearBuilt":null,
             "amenities":{"pool":true,"wifi":null,"grill":false},"poolType":null,"otherAmenities":[],
             "distances":{"beachM":null,"seaM":null,"townM":2500,"shopM":null,"restaurantM":null,"airportKm":85},
             "rating":{"value":null,"scale":null,"count":null},
             "rules":{"checkInFrom":"16:00","checkOutUntil":null,"minNights":7,"arrivalDays":null,"smoking":null},
             "price":{"startDate":null,"endDate":null,"nights":null,"persons":null,"totalEur":null,"kind":null,"rangeMaxEur":null,"included":[],"extraCosts":[{"item":"Kurtaxe","amountEur":null,"note":"vor Ort"}],"depositEur":null},
             "cancellation":null,
             "packageTrip":{"hotelStars":null,"board":null,"roomType":null,"departureAirport":null,"durationDays":null,"transferIncluded":null,"tourOperator":null},
             "photoCount":24,"coverImageUrl":null,"summary":null,"highlights":[],"warnings":["Preis gilt für 6 Personen"],"uncertain":["livingAreaSqm","amenities.grill"]}},
         "sources":[{"id":"s1","platform":"vrbo","url":"https://www.fewo-direkt.de/x","canonicalUrl":"https://www.fewo-direkt.de/x","provenance":{"basics":"jsonld"},"lastFetchedAt":null}],
         "prices":[{"id":"p1","listingSourceId":"s1","tripId":"t1","startDate":"2027-05-15","endDate":"2027-05-29","nights":14,"persons":8,"totalCents":486000,
            "rangeMaxCents":null,"currency":"EUR","kind":"total","breakdown":[{"item":"Endreinigung","amountCents":null}],"available":null,"capture":"device",
            "capturedBy":null,"capturedAt":"2026-11-15T09:17:52.123Z"}],
         "votes":{"yes":1,"maybe":0,"no":0,"vetoes":0,"entries":[{"userId":"u1","name":"Anna","verdict":"yes","veto":false,"updatedAt":"2026-11-15T09:17:52.123Z"}]},
         "comments":[{"id":"k1","body":"Schön!","createdAt":"2026-11-15T09:17:52.123Z","userId":"u1","name":"Anna"}]}
        """)
        let profile = detail.listing.profile
        XCTAssertEqual(profile.amenity("pool"), true)
        XCTAssertEqual(profile.amenity("grill"), false)
        XCTAssertNil(profile.amenity("wifi"))
        XCTAssertNil(profile.amenity("sauna"))
        XCTAssertTrue(profile.isUncertain("amenities.grill"))
        XCTAssertEqual(profile.distances?.townM, 2500)
        XCTAssertEqual(detail.prices.first?.capture, "device")
        XCTAssertEqual(detail.sources.first?.platform, "vrbo")
    }

    func testAcceptInviteWhileSignedInHasNoToken() throws {
        let result = try decode(AuthResult.self, #"{"token":null,"user":{"id":"u1","name":"Anna"},"tripId":"t1","role":"member"}"#)
        XCTAssertNil(result.token)
        XCTAssertEqual(result.tripId, "t1")
    }
}

final class HelperTests: XCTestCase {
    func testInviteLink() {
        let link = InviteLink(" https://reisen.von-bleichert.com/einladung/abc123 ")
        XCTAssertEqual(link?.serverURL.absoluteString, "https://reisen.von-bleichert.com")
        XCTAssertEqual(link?.token, "abc123")
    }

    func testInviteLinkWithPortAndPrefix() {
        let link = InviteLink("http://localhost:3000/api/einladung/tok")
        XCTAssertEqual(link?.serverURL.absoluteString, "http://localhost:3000/api")
        XCTAssertEqual(link?.token, "tok")
    }

    func testInviteLinkRejectsOtherLinks() {
        XCTAssertNil(InviteLink("https://www.airbnb.de/rooms/123"))
        XCTAssertNil(InviteLink("https://server/einladung/"))
        XCTAssertNil(InviteLink("abc123"))
    }

    func testFirstURLInSharedText() {
        XCTAssertEqual(LinkFinder.firstURL(in: "Schau dir das an: https://www.airbnb.de/rooms/123?adults=2 Toll, oder?")?.absoluteString,
                       "https://www.airbnb.de/rooms/123?adults=2")
        XCTAssertNil(LinkFinder.firstURL(in: "Kein Link hier"))
    }

    func testRequestBuilding() throws {
        let client = APIClient(baseURL: URL(string: "https://server/api/")!, token: "geheim")
        let request = try client.request("GET", "/trips")
        XCTAssertEqual(request.url?.absoluteString, "https://server/api/trips")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer geheim")
    }

    func testPriceFormatting() {
        XCTAssertEqual(Format.price(totalCents: 486_000, rangeMaxCents: nil, kind: .total)?.filter { !$0.isWhitespace }, "4.860€")
        XCTAssertEqual(Format.price(totalCents: 240_000, rangeMaxCents: nil, kind: .from)?.filter { !$0.isWhitespace }, "ab2.400€")
        XCTAssertNil(Format.price(totalCents: nil, rangeMaxCents: nil, kind: .total))
        XCTAssertEqual(Format.perPersonNight(totalCents: 448_000, persons: 8, nights: 14)?.filter { !$0.isWhitespace }, "40€proPersonundNacht")
        XCTAssertNil(Format.perPersonNight(totalCents: 448_000, persons: 0, nights: 14))
    }

    func testDateRange() {
        XCTAssertEqual(Format.dateRange("2027-05-15", "2027-05-29"), "15.05. – 29.05.2027")
        XCTAssertNil(Format.dateRange("2027-05-15", nil))
        XCTAssertEqual(Format.distance(meters: 450), "450 m")
        XCTAssertEqual(Format.distance(meters: 2500), "2,5 km")
    }
}

final class PhotoTests: XCTestCase {
    let client = APIClient(baseURL: URL(string: "https://reisen.example/api")!, token: "geheim")

    func testOwnServerGetsTokenForRelativeAndAbsoluteAddresses() {
        let relative = client.imageRequest(for: "/media/a.jpg")
        XCTAssertEqual(relative?.url?.absoluteString, "https://reisen.example/api/media/a.jpg")
        XCTAssertEqual(relative?.value(forHTTPHeaderField: "Authorization"), "Bearer geheim")
        let absolute = client.imageRequest(for: "https://reisen.example/media/a.jpg")
        XCTAssertEqual(absolute?.value(forHTTPHeaderField: "Authorization"), "Bearer geheim")
    }

    func testForeignHostsNeverSeeTheToken() {
        for address in ["https://a0.muscache.com/im/x.jpg", "https://reisen.example.evil.com/a.jpg", "http://reisen.example/a.jpg",
                        "https://reisen.example:8443/a.jpg"] {
            let request = client.imageRequest(for: address)
            XCTAssertNotNil(request, address)
            XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"), address)
        }
    }

    func testUnusableAddresses() {
        XCTAssertNil(client.imageRequest(for: "file:///etc/passwd"))
        XCTAssertNil(client.imageRequest(for: "//cdn.example/a.jpg"))
        XCTAssertNil(client.imageRequest(for: ""))
    }

    func testGalleryFallsBackToCover() throws {
        let record = CandidateRecord(id: "c", tripId: "t", listingId: "l")
        var detail = CandidateDetail(candidate: record, role: .member, listing: Listing(id: "l", coverImageUrl: "https://x/cover.jpg"))
        XCTAssertEqual(detail.gallery.map(\.url), ["https://x/cover.jpg"])
        detail.photos = [Photo(id: "1", url: "/m/1.jpg", thumbUrl: "/m/1t.jpg", width: 4000, height: 3000), Photo(id: "2", url: "/m/2.jpg")]
        XCTAssertEqual(detail.gallery.count, 2)
        XCTAssertEqual(detail.gallery[0].aspectRatio ?? 0, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertNil(detail.gallery[1].aspectRatio)
        detail.listing.coverImageUrl = nil
        detail.photos = []
        XCTAssertTrue(detail.gallery.isEmpty)
    }

    func testPhotosDecode() throws {
        let photos = try APIClient.decoder.decode([Photo].self, from: Data(#"[{"id":"p1","url":"/media/1.jpg","thumbUrl":null,"width":null,"height":null,"caption":null},{"id":"p2","url":"https://x/2.jpg","thumbUrl":"/media/2t.jpg","width":4000,"height":3000,"caption":"Pool"}]"#.utf8))
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(photos[1].caption, "Pool")
    }
}

final class ReviewTests: XCTestCase {
    func testReviewsDecodeWithSparseFields() throws {
        let reviews = try APIClient.decoder.decode(Reviews.self, from: Data("""
        {"summary":"Ruhig und sauber.","positives":["Lage"],"negatives":[],"basedOn":12,"generatedAt":"2026-11-15T22:00:00.000Z",
         "items":[{"id":"r1","author":null,"date":null,"rating":null,"scale":null,"title":null,"text":"Schön.","language":null,
                   "translatedText":null,"stayType":null,"ownerReply":null,"platform":"casamundo"},
                  {"id":"r2","author":"Ana","date":"2026-08-01","rating":9.2,"scale":10,"title":"Top","text":"Muy bien","language":"es",
                   "translatedText":"Sehr gut","stayType":"Paar","ownerReply":"Danke","platform":"booking"}]}
        """.utf8))
        XCTAssertFalse(reviews.isEmpty)
        XCTAssertEqual(reviews.items?.count, 2)
        XCTAssertEqual(reviews.items?[1].rating, 9.2)
        XCTAssertNil(reviews.items?[0].author)
    }

    func testEmptyReviews() throws {
        XCTAssertTrue(try APIClient.decoder.decode(Reviews.self, from: Data(#"{"summary":null,"positives":[],"negatives":[],"basedOn":0,"generatedAt":null,"items":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(try APIClient.decoder.decode(Reviews.self, from: Data("{}".utf8)).isEmpty)
    }

    private func detail(_ extra: String) throws -> CandidateDetail {
        try APIClient.decoder.decode(CandidateDetail.self, from: Data("""
        {"candidate":{"id":"c1","tripId":"t1","listingId":"l1","status":"new","importStatus":"ready","importNote":null,"addedBy":"u1",
           "rejectionReason":null,"notes":null,"tags":[],"createdAt":"2026-11-15T09:17:52.123Z"},
         "role":"member","listing":{"id":"l1","kind":"vacation_home","title":"Casa","place":null,"country":null,"lat":null,"lon":null,
           "coverImageUrl":null,"fillPercent":40,"profile":{}},
         "sources":[],"prices":[],"votes":{"yes":0,"maybe":0,"no":0,"vetoes":0,"entries":[]},"comments":[]\(extra)}
        """.utf8))
    }

    func testServerShapeSummaryAndListSideBySide() throws {
        let detail = try detail("""
        ,"photos":[],"reviewSummary":{"summary":"Ruhig.","positives":["Pool","Lage"],"negatives":["Liegen kosten extra"],"basedOn":20},
        "reviews":[{"id":"3b1f","text":"Gut","title":null,"rating":8.5,"scale":10,"date":"2026-08-14","author":"Jörg"},
                   {"id":"9c2e","text":"Okay","title":null,"rating":null,"scale":null,"date":"August 2026","author":null}]
        """)
        XCTAssertEqual(detail.reviews?.summary, "Ruhig.")
        XCTAssertEqual(detail.reviews?.basedOn, 20)
        XCTAssertEqual(detail.reviews?.items?.count, 2)
        XCTAssertEqual(detail.reviews?.items?[1].date, "August 2026")
    }

    func testOfferWithoutReviewsHasNone() throws {
        XCTAssertNil(try detail("").reviews)
        XCTAssertNil(try detail(#","reviewSummary":{"summary":null,"positives":[],"negatives":[],"basedOn":0},"reviews":[]"#).reviews)
        XCTAssertNil(try detail(#","reviewSummary":null,"reviews":null"#).reviews)
    }

    func testHintsWithHiddenStateAndFallbackToProfile() throws {
        let withList = try detail(#","warnings":[{"text":"Preis für 6","hidden":true},{"text":"Kein WLAN","hidden":false}]"#)
        XCTAssertEqual(withList.hints.filter(\.hidden).map(\.text), ["Preis für 6"])
        XCTAssertEqual(withList.hints.filter { !$0.hidden }.map(\.text), ["Kein WLAN"])
        XCTAssertTrue(try detail("").hints.isEmpty)
    }

    func testOtherPlatformsAndRicherSources() throws {
        let detail = try detail("""
        ,"otherPlatforms":{"available":true,"status":"done","searchedAt":"2026-11-15T22:50:00.000Z","note":null,
          "suggestions":[{"id":"s1","url":"https://www.airbnb.de/rooms/1","platform":"airbnb","title":"Casa","reason":"Gleicher Ort.","confidence":"high","status":"proposed"},
                         {"id":"s2","url":"https://x/2","platform":"other","title":null,"reason":null,"confidence":"low","status":"rejected"}]}
        """)
        XCTAssertEqual(detail.otherPlatforms?.open.map(\.id), ["s1"])
        XCTAssertEqual(detail.otherPlatforms?.isRunning, false)
        let source = try APIClient.decoder.decode(ListingSource.self, from: Data(#"{"id":"q","platform":"casamundo","url":"https://c/1","canonicalUrl":"https://c/1","primary":false,"read":false,"needsDevice":true,"title":null,"rating":null,"reviewCount":null,"lastFetchedAt":null}"#.utf8))
        XCTAssertEqual(source.needsDevice, true)
        let old = try APIClient.decoder.decode(ListingSource.self, from: Data(#"{"id":"q","platform":"vrbo","url":"https://f/1","canonicalUrl":"https://f/1","provenance":{},"lastFetchedAt":null}"#.utf8))
        XCTAssertNil(old.primary)
    }

    func testOddExtrasNeverBreakTheOffer() throws {
        let detail = try detail(#","photos":"kaputt","reviewSummary":17,"reviews":{"unerwartet":true}"#)
        XCTAssertEqual(detail.listing.title, "Casa")
        XCTAssertNil(detail.photos)
        XCTAssertNil(detail.reviews)
    }
}

final class ComparisonTests: XCTestCase {
    private func offer(_ id: String, total: Int?, forTrip: Bool = true, bedrooms: Double?, beach: Double?, pool: Bool?,
                       rating: Rating? = nil, yes: Int = 0) -> CandidateDetail {
        var profile = Profile()
        profile.bedrooms = bedrooms
        var distances = Profile.Distances(); distances.beachM = beach
        profile.distances = distances
        profile.amenities = ["pool": pool]
        profile.rating = rating
        let prices = total.map { [PriceSnapshot(id: "p\(id)", tripId: forTrip ? "t" : nil, startDate: "2027-05-15", endDate: "2027-05-29",
                                                nights: 14, persons: 6, totalCents: $0)] } ?? []
        return CandidateDetail(candidate: CandidateRecord(id: id, tripId: "t", listingId: "l\(id)"), role: .member,
                               listing: Listing(id: "l\(id)", title: id, profile: profile), prices: prices,
                               votes: VoteOverview(yes: yes))
    }

    private func row(_ comparison: Comparison, _ id: String) -> Comparison.Row? {
        comparison.sections.flatMap(\.rows).first { $0.id == id }
    }

    func testBestValuesPointTheRightWay() throws {
        let comparison = Comparison(offers: [
            offer("a", total: 480_000, bedrooms: 4, beach: 900, pool: true, rating: Rating(value: 4.5, scale: 5), yes: 2),
            offer("b", total: 420_000, bedrooms: 5, beach: 300, pool: false, rating: Rating(value: 8.6, scale: 10), yes: 1),
            offer("c", total: nil, bedrooms: nil, beach: nil, pool: nil),
        ], persons: 8)
        XCTAssertEqual(row(comparison, "price")?.best, [1], "der niedrigste Preis gewinnt")
        XCTAssertEqual(row(comparison, "bedrooms")?.best, [1])
        XCTAssertEqual(row(comparison, "beach")?.best, [1], "die kürzeste Entfernung gewinnt")
        XCTAssertEqual(row(comparison, "amenity.pool")?.best, [0])
        XCTAssertEqual(row(comparison, "amenity.pool")?.values, ["Ja", "Nein", nil], "unbekannt ist nicht Nein")
        XCTAssertEqual(row(comparison, "rating")?.best, [0], "4,5 von 5 schlägt 8,6 von 10")
        XCTAssertEqual(row(comparison, "yes")?.best, [0])
        // 480.000 Cent / (8 Personen der Reise * 14 Nächte)
        XCTAssertEqual(row(comparison, "perHead")?.values[0]?.filter { !$0.isWhitespace }, "43€")
        XCTAssertNil(row(comparison, "perHead")?.values[2] ?? nil)
    }

    func testPriceForOtherDatesIsShownButNotRanked() throws {
        let comparison = Comparison(offers: [
            offer("a", total: 480_000, bedrooms: 4, beach: nil, pool: nil),
            offer("b", total: 100_000, forTrip: false, bedrooms: 4, beach: nil, pool: nil),
        ], persons: 8)
        let price = try XCTUnwrap(row(comparison, "price"))
        XCTAssertEqual(price.best, [], "ein einzelner gültiger Preis hat keinen Gegner")
        XCTAssertEqual(price.values[1]?.hasPrefix("("), true)
        XCTAssertNotNil(price.note)
        XCTAssertNil(row(comparison, "perHead")?.values[1] ?? nil)
    }

    func testEqualAndUnknownRows() throws {
        let comparison = Comparison(offers: [
            offer("a", total: 400_000, bedrooms: 4, beach: nil, pool: true),
            offer("b", total: 400_000, bedrooms: 4, beach: nil, pool: true),
        ], persons: 6)
        XCTAssertEqual(row(comparison, "price")?.best, [], "Gleichstand hat keinen Sieger")
        XCTAssertEqual(row(comparison, "bedrooms")?.differs, false)
        XCTAssertEqual(row(comparison, "amenity.pool")?.best, [], "beide Ja: nichts hervorzuheben")
        XCTAssertNil(row(comparison, "beach"), "Zeilen ohne jeden Wert entfallen")
        XCTAssertNil(row(comparison, "amenity.sauna"))
        let differences = comparison.differencesOnly()
        XCTAssertNil(row(differences, "bedrooms"))
        XCTAssertFalse(differences.sections.flatMap(\.rows).contains { !$0.differs })
    }

    func testWinsCountBestValues() {
        let comparison = Comparison(offers: [
            offer("a", total: 480_000, bedrooms: 4, beach: 900, pool: true),
            offer("b", total: 420_000, bedrooms: 5, beach: 300, pool: false),
        ], persons: 8)
        XCTAssertEqual(comparison.wins, [1, 4])
    }
}

final class PlaceTests: XCTestCase {
    func testCoordinatesAndQuery() {
        let hint = PlaceHint(latitude: 43.47, longitude: 11.29, place: "Castellina in Chianti", region: "Toskana", country: "Italien")
        XCTAssertTrue(hint.hasCoordinates)
        XCTAssertEqual(hint.query, "Castellina in Chianti, Toskana, Italien")
    }

    func testBrokenCoordinatesAreIgnored() {
        XCTAssertFalse(PlaceHint(latitude: 0, longitude: 0, place: "Vela Luka", region: nil, country: "Kroatien").hasCoordinates)
        XCTAssertFalse(PlaceHint(latitude: 143, longitude: 11, place: nil, region: nil, country: nil).hasCoordinates)
        XCTAssertFalse(PlaceHint(latitude: 43, longitude: nil, place: nil, region: nil, country: nil).hasCoordinates)
        XCTAssertTrue(PlaceHint(latitude: nil, longitude: nil, place: " ", region: nil, country: nil).isEmpty)
    }

    func testQuerySkipsRepeatsAndBlanks() {
        XCTAssertEqual(PlaceHint(latitude: nil, longitude: nil, place: "Korčula", region: "korčula", country: " Kroatien ").query, "Korčula, Kroatien")
        XCTAssertEqual(PlaceHint(latitude: nil, longitude: nil, place: nil, region: nil, country: "Dänemark").query, "Dänemark")
    }

    func testApproximateFlagFromList() throws {
        let json = #"{"id":"l1","kind":"vacation_home","title":"Casa","place":"Vela Luka","country":"Kroatien","lat":42.96,"lon":16.71,"coverImageUrl":null,"fillPercent":50,"maxGuests":null,"bedrooms":null,"bathrooms":null,"rating":null,"platforms":["airbnb"],"photoCount":3,"locationApproximate":true}"#
        let summary = try APIClient.decoder.decode(ListingSummary.self, from: Data(json.utf8))
        XCTAssertTrue(PlaceHint(summary: summary).uncertain)
        XCTAssertTrue(PlaceHint(summary: summary).hasCoordinates)
        XCTAssertFalse(PlaceHint(summary: ListingSummary(id: "x", lat: 1, lon: 1)).uncertain)
    }

    func testGoogleMapsLinks() {
        XCTAssertEqual(MapLinks.googleMaps(latitude: 43.4701, longitude: 11.2893)?.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=43.470100,11.289300")
        XCTAssertEqual(MapLinks.googleMaps(query: "Vela Luka, Kroatien")?.absoluteString,
                       "https://www.google.com/maps/search/?api=1&query=Vela%20Luka,%20Kroatien")
        XCTAssertNil(MapLinks.googleMaps())
    }
}

final class GroupingTests: XCTestCase {
    private func offer(_ id: String, _ country: String?, _ region: String? = nil) -> CandidateSummary {
        CandidateSummary(id: id, addedBy: "A", listing: ListingSummary(id: "l" + id, country: country, region: region))
    }

    func testCountriesSortedWithUnknownLast() {
        let groups = OfferGrouping.groups([offer("1", "Kroatien"), offer("2", nil), offer("3", "Italien"), offer("4", " Kroatien "), offer("5", "Kroatien")])
        XCTAssertEqual(groups.map(\.title), ["Italien", "Kroatien", "Land unbekannt"])
        XCTAssertEqual(groups.first?.title, "Italien")
        XCTAssertEqual(groups.last?.title, "Land unbekannt")
        XCTAssertEqual(groups.first { $0.country == "Kroatien" }?.offers.map(\.id), ["1", "4", "5"], "Reihenfolge innerhalb bleibt")
    }

    func testRegionsSplitOnlyWhenThereAreSeveral() {
        let one = OfferGrouping.groups([offer("1", "Italien", "Toskana"), offer("2", "Italien", "Toskana")])
        XCTAssertEqual(one.map(\.title), ["Italien · Toskana"])
        let mixed = OfferGrouping.groups([offer("1", "Italien", "Toskana"), offer("2", "Italien", nil)])
        XCTAssertEqual(mixed.map(\.title), ["Italien"], "eine Region plus unbekannt: nicht aufteilen und nichts behaupten")
        let several = OfferGrouping.groups([offer("1", "Italien", "Toskana"), offer("2", "Italien", "Ligurien"), offer("3", "Italien", nil), offer("4", "Italien", "Toskana")])
        XCTAssertEqual(several.map(\.title), ["Italien · Ligurien", "Italien · Toskana", "Italien"])
        XCTAssertEqual(several[1].offers.map(\.id), ["1", "4"])
        XCTAssertEqual(Set(several.map(\.id)).count, 3, "Abschnitte brauchen eindeutige Kennungen")
    }

    func testCountryListForFilter() {
        XCTAssertEqual(OfferGrouping.countries(in: [offer("1", "Kroatien"), offer("2", nil), offer("3", "Italien"), offer("4", "Kroatien"), offer("5", "  ")]),
                       ["Italien", "Kroatien"])
    }
}

final class CriteriaAndSortingTests: XCTestCase {
    func testServerShapesDecode() throws {
        let list = try APIClient.decoder.decode(CriteriaList.self, from: Data("""
        {"criteria":[{"id":"a","key":"bedrooms","label":null,"level":"must","target":4},
                     {"id":"b","key":"amenities.pool","label":null,"level":"wish","target":null},
                     {"id":"c","key":"custom","label":"Ruhige Lage","level":"must","target":null}],
         "measurable":[{"key":"bedrooms","label":"Schlafzimmer","group":"space","format":"number","rule":"min"}]}
        """.utf8))
        XCTAssertEqual(list.criteria.map(\.isMust), [true, false, true])
        XCTAssertEqual(list.measurable?.first?.rule, "min")
        let verdict = try APIClient.decoder.decode(CriteriaVerdict.self, from: Data("""
        {"light":"yellow","must":{"met":2,"missed":0,"unknown":1},"wish":{"met":1,"missed":1,"unknown":0},
         "results":[{"id":"a","key":"bedrooms","label":"Schlafzimmer","level":"must","rule":"min","format":"number","target":4,"value":5,"status":"met","manual":false},
                    {"id":"b","key":"amenities.pool","label":"Pool","level":"wish","rule":"yes","format":"boolean","target":null,"value":false,"status":"missed","manual":false},
                    {"id":"c","key":"custom","label":"Ruhige Lage","level":"must","rule":null,"format":null,"target":null,"value":null,"status":"unknown","manual":false}]}
        """.utf8))
        XCTAssertEqual(verdict.rank, 1)
        XCTAssertEqual(verdict.results?.map { $0.value?.text }, ["5", "Nein", nil])
        let period = try APIClient.decoder.decode(OfferPeriod.self, from: Data(#"{"dateOptionId":"d1","label":null,"startDate":"2027-05-15","endDate":"2027-05-29","availability":"unavailable","totalCents":null,"kind":null,"checkedAt":null,"checkUrl":null}"#.utf8))
        XCTAssertEqual(period.availability, "unavailable")
    }

    func testTrafficLightInSampleData() async throws {
        let demo = DemoBackend()
        var list = try await demo.candidates(tripId: "t-1")
        XCTAssertNil(list.first?.criteria, "ohne Kriterien keine Ampel")
        let saved = try await demo.setCriteria(tripId: "t-1", criteria: [
            Criterion(key: "bedrooms", level: "must", target: 5),
            Criterion(key: "amenities.petsAllowed", level: "wish"),
            Criterion(key: "custom", label: "Ruhige Lage", level: "wish"),
        ])
        XCTAssertFalse(saved.criteria.contains { $0.id.isEmpty })
        list = try await demo.candidates(tripId: "t-1")
        let light = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.criteria?.light) })
        XCTAssertEqual(light["c-1"], "red", "4 Schlafzimmer bei Muss 5")
        XCTAssertEqual(light["c-5"], "yellow", "5 Schlafzimmer, aber Haustiere unbekannt")
        let detail = try await demo.candidate("c-1")
        XCTAssertEqual(detail.criteria?.results?.first?.status, "missed")
        // A verdict by hand beats the measured value.
        try await demo.setCriteriaChecks(candidateId: "c-1", checks: [saved.criteria[0].id: "met"])
        let after = try await demo.candidate("c-1")
        XCTAssertEqual(after.criteria?.results?.first?.status, "met")
        XCTAssertEqual(after.criteria?.results?.first?.manual, true)
    }

    private func offer(_ id: String, cents: Int?, forTrip: Bool = true, available: Bool? = nil, rating: Rating? = nil,
                       light: String? = nil, yes: Int = 0, no: Int = 0) -> CandidateSummary {
        var summary = CandidateSummary(id: id, addedBy: "A", listing: ListingSummary(id: "l" + id, rating: rating),
                                       price: cents.map { PriceSummary(totalCents: $0, forThisTrip: forTrip, available: available) },
                                       votes: VoteTally(yes: yes, no: no))
        summary.criteria = light.map { CriteriaVerdict(light: $0) }
        return summary
    }

    func testSortingKeepsEverythingAndPutsUnknownLast() {
        let offers = [
            offer("a", cents: 500_000, rating: Rating(value: 4.5, scale: 5), light: "yellow", yes: 1),
            offer("b", cents: nil, rating: Rating(value: 9.4, scale: 10), light: "green"),
            offer("c", cents: 300_000, forTrip: false, light: "red", no: 2),
            offer("d", cents: 420_000, rating: nil, light: nil, yes: 3),
            offer("e", cents: 100_000, available: false, rating: Rating(value: 4.9, scale: 5)),
        ]
        XCTAssertEqual(OfferSort.added.sorted(offers).map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(OfferSort.price.sorted(offers).map(\.id), ["d", "a", "b", "c", "e"],
                       "Linkpreis und nicht verfügbar zählen nicht als Preis")
        XCTAssertEqual(OfferSort.rating.sorted(offers).map(\.id), ["e", "b", "a", "c", "d"], "4,9 von 5 vor 9,4 von 10")
        XCTAssertEqual(OfferSort.criteria.sorted(offers).map(\.id), ["b", "a", "c", "d", "e"])
        XCTAssertEqual(OfferSort.votes.sorted(offers).map(\.id), ["d", "a", "c", "b", "e"])
        for sort in OfferSort.allCases { XCTAssertEqual(Set(sort.sorted(offers).map(\.id)).count, 5) }
    }
}

final class PitchTests: XCTestCase {
    func testServerShapeDecodes() throws {
        let pitch = try APIClient.decoder.decode(Pitch.self, from: Data("""
        {"phase":"decision","voteDeadline":null,"decided":null,"maxPoints":8,
         "finalists":[{"place":1,"points":7,"firstPlaces":2,
           "candidate":{"id":"c1","status":"new","importStatus":"ready","importNote":null,"tags":[],"addedBy":"A","createdAt":"2026-11-15T09:17:52.123Z",
             "listing":{"id":"l1","kind":"vacation_home","title":"Casa","place":null,"country":null,"lat":null,"lon":null,"coverImageUrl":null,
               "fillPercent":0,"maxGuests":null,"bedrooms":null,"bathrooms":null,"rating":null,"platforms":[]},
             "price":null,"votes":{"yes":0,"maybe":0,"no":0,"vetoes":0},"myVote":null,"finalist":true},
           "summary":"Schön.","highlights":["Pool"],"warnings":[],"reviewSummary":{"summary":"Gut.","positives":[],"negatives":[]}}],
         "rankings":[{"userId":"u1","name":"Anna","order":["c1"],"updatedAt":"2026-11-16T10:00:00.000Z"}],
         "myRanking":["c1"],"missing":[{"userId":"u2","name":"Jonas"}]}
        """.utf8))
        XCTAssertEqual(pitch.finalists.first?.points, 7)
        XCTAssertEqual(pitch.finalists.first?.candidate.finalist, true)
        XCTAssertNil(pitch.decidedCandidateId)
        XCTAssertEqual(pitch.missing.map(\.name), ["Jonas"])
        let decided = try APIClient.decoder.decode(Pitch.self, from: Data(#"{"phase":"booking","decided":{"candidateId":"c1","decidedAt":"2026-11-16T10:00:00.000Z"},"finalists":[]}"#.utf8))
        XCTAssertEqual(decided.decidedCandidateId, "c1")
    }

    func testPhaseOfTrip() throws {
        let json = #"{"id":"t","title":"R","region":null,"adults":2,"children":0,"pets":0,"budgetTotalCents":null,"status":"planning","voteDeadline":null,"createdAt":"2026-11-16T00:00:00.000Z","phase":"booking","currentPhase":"travelling"}"#
        XCTAssertEqual(try APIClient.decoder.decode(Trip.self, from: Data(json.utf8)).activePhase, .travelling, "maßgeblich ist, was heute gilt")
        XCTAssertEqual(Trip(id: "x", title: "Alt").activePhase, .research)
    }

    func testRankingPointsAndDecision() async throws {
        let demo = DemoBackend()
        do {
            _ = try await demo.startPitch(tripId: "t-1", candidateIds: ["c-1"])
            XCTFail("Ein Finalist ist keine Wahl")
        } catch let error as APIError { XCTAssertEqual(error.status, 400) }
        var pitch = try await demo.startPitch(tripId: "t-1", candidateIds: ["c-1", "c-2", "c-5"])
        XCTAssertEqual(pitch.finalists.map(\.candidate.id), ["c-1", "c-2", "c-5"], "Annas Rangfolge allein")
        XCTAssertEqual(pitch.finalists.map(\.points), [3, 2, 1])
        XCTAssertEqual(Set(pitch.missing.map(\.name)), ["Du", "Jonas"])
        pitch = try await demo.setRanking(tripId: "t-1", order: ["c-5", "c-2"])
        XCTAssertEqual(pitch.myRanking, ["c-5", "c-2"])
        // c-5: 1 + 3 = 4, c-2: 2 + 2 = 4, c-1: 3 + 0 = 3. Tie on points; one first place each for c-5 (mine) and none for c-2.
        XCTAssertEqual(pitch.finalists.map(\.candidate.id), ["c-5", "c-2", "c-1"])
        XCTAssertEqual(pitch.finalists.map(\.place), [1, 2, 3])
        XCTAssertEqual(pitch.missing.map(\.name), ["Jonas"])
        let list = try await demo.candidates(tripId: "t-1")
        XCTAssertEqual(list.filter { $0.finalist == true }.count, 3)
        var trips = try await demo.trips()
        XCTAssertEqual(trips.first { $0.id == "t-1" }?.activePhase, .decision)
        pitch = try await demo.decide(tripId: "t-1", candidateId: "c-5", dateOptionId: nil)
        XCTAssertEqual(pitch.decidedCandidateId, "c-5")
        trips = try await demo.trips()
        XCTAssertEqual(trips.first { $0.id == "t-1" }?.activePhase, .booking)
        pitch = try await demo.undoDecision(tripId: "t-1")
        XCTAssertNil(pitch.decidedCandidateId)
    }

    func testVetoGoesToTheBack() async throws {
        let demo = DemoBackend()
        _ = try await demo.startPitch(tripId: "t-1", candidateIds: ["c-1", "c-2"])
        try await demo.vote(candidateId: "c-1", verdict: .no, veto: true)
        let pitch = try await demo.pitch(tripId: "t-1")
        XCTAssertEqual(pitch.finalists.map(\.candidate.id), ["c-2", "c-1"])
    }
}

final class DemoBackendTests: XCTestCase {
    func testVoteAndCountsStayConsistent() async throws {
        let demo = DemoBackend()
        let trips = try await demo.trips()
        XCTAssertEqual(trips.first?.candidateCount, 4)
        XCTAssertEqual(trips.first?.favoriteCount, 1)

        try await demo.vote(candidateId: "c-1", verdict: .no, veto: true)
        try await demo.vote(candidateId: "c-1", verdict: .yes, veto: false)
        let detail = try await demo.candidate("c-1")
        XCTAssertEqual(detail.votes.entries.count, 3, "Eine zweite Stimme ersetzt die erste")
        XCTAssertEqual(detail.votes.yes, 2)
        XCTAssertEqual(detail.votes.vetoes, 0)

        let list = try await demo.candidates(tripId: "t-1")
        XCTAssertEqual(list.first { $0.id == "c-1" }?.myVote?.verdict, .yes)
    }

    func testHidingHintsKeepsThemButMarksThem() async throws {
        let demo = DemoBackend()
        let before = try await demo.candidate("c-2").hints
        XCTAssertEqual(before.count, 2)
        XCTAssertFalse(before.contains(where: \.hidden))
        try await demo.setHiddenWarnings(candidateId: "c-2", hidden: [before[0].text])
        let after = try await demo.candidate("c-2").hints
        XCTAssertEqual(after.map(\.hidden), [true, false])
        try await demo.setHiddenWarnings(candidateId: "c-2", hidden: [])
        let restored = try await demo.candidate("c-2").hints
        XCTAssertFalse(restored.contains(where: \.hidden))
    }

    func testSuggestionAcceptedBecomesSourceAndCanBeRemoved() async throws {
        let demo = DemoBackend()
        try await demo.searchOtherPlatforms(candidateId: "c-1")
        let found = try await demo.candidate("c-1")
        let first = try XCTUnwrap(found.otherPlatforms?.open.first)
        XCTAssertEqual(found.otherPlatforms?.open.count, 2)
        try await demo.decide(candidateId: "c-1", suggestionId: first.id, accept: true)
        let second = try XCTUnwrap(found.otherPlatforms?.open.last)
        try await demo.decide(candidateId: "c-1", suggestionId: second.id, accept: false)
        var after = try await demo.candidate("c-1")
        XCTAssertEqual(after.sources.count, 2)
        XCTAssertEqual(after.otherPlatforms?.open.count, 0)
        let added = try XCTUnwrap(after.sources.last)
        XCTAssertEqual(added.needsDevice, true)
        try await demo.capture(candidateId: "c-1", html: String(repeating: "x", count: 600), sourceId: added.id)
        after = try await demo.candidate("c-1")
        XCTAssertEqual(after.sources.last?.read, true)
        XCTAssertEqual(after.candidate.importStatus, .ready, "eine weitere Quelle ändert den Stand des Angebots nicht")
        try await demo.removeSource(candidateId: "c-1", sourceId: added.id)
        do {
            try await demo.removeSource(candidateId: "c-1", sourceId: after.sources[0].id)
            XCTFail("Die erste Quelle darf nicht entfernbar sein")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "primary_source")
        }
        let end = try await demo.candidate("c-1")
        XCTAssertEqual(end.sources.count, 1)
    }

    func testTripCheckSaysWhoReadsWhat() async throws {
        let check = try APIClient.decoder.decode(TripCheck.self, from: Data("""
        {"startDate":"2027-05-15","endDate":"2027-05-29","adults":4,"children":4,"checks":[
          {"candidateId":"a","platform":"airbnb","mode":"server","needsDevice":false,"checkUrl":"https://www.airbnb.de/rooms/1?check_in=2027-05-15"},
          {"candidateId":"b","platform":"casamundo","mode":"device","needsDevice":true,"checkUrl":"https://www.casamundo.de/rental/x"},
          {"candidateId":"c","platform":"novasol","mode":"server","needsDevice":false,"checkUrl":null},
          {"candidateId":"d","platform":"vrbo","mode":"skipped","needsDevice":true,"checkUrl":"https://www.fewo-direkt.de/x"},
          {"candidateId":"e","platform":"booking","mode":"server","needsDevice":false,"checkUrl":"https://www.booking.com/x"}]}
        """.utf8))
        XCTAssertEqual(check.checks.filter(\.wantsDevice).map(\.candidateId), ["a", "b"],
                       "Airbnb sieht der Server zu wenig, Casamundo gar nicht; ohne Adresse oder eben erst gelesen: nichts zu tun")
        let demo = DemoBackend()
        let own = try await demo.checkTrip(tripId: "t-1")
        XCTAssertEqual(own.checks.filter(\.wantsDevice).map(\.candidateId), ["c-3"])
    }

    func testUnavailableAfterCheck() async throws {
        let demo = DemoBackend()
        var list = try await demo.candidates(tripId: "t-1")
        XCTAssertFalse(list.contains(where: \.isUnavailable))
        for offer in list { try await demo.refresh(candidateId: offer.id) }
        list = try await demo.candidates(tripId: "t-1")
        XCTAssertEqual(list.filter(\.isUnavailable).map(\.id), ["c-2"])
    }

    func testAvailabilityFields() throws {
        func row(_ extra: String, price: String = "null") throws -> CandidateSummary {
            try APIClient.decoder.decode(CandidateSummary.self, from: Data("""
            {"id":"c1","status":"new","importStatus":"ready","importNote":null,"tags":[],"addedBy":"A","createdAt":"2026-11-15T09:17:52.123Z",
             "listing":{"id":"l1","kind":"vacation_home","title":null,"place":null,"country":null,"lat":null,"lon":null,"coverImageUrl":null,
               "fillPercent":0,"maxGuests":null,"bedrooms":null,"bathrooms":null,"rating":null,"platforms":[]},
             "price":\(price),"votes":{"yes":0,"maybe":0,"no":0,"vetoes":0},"myVote":null\(extra)}
            """.utf8))
        }
        XCTAssertFalse(try row("").isUnavailable)
        XCTAssertTrue(try row(#","availability":"unavailable","availabilityCheckedAt":"2026-11-16T00:00:00.000Z""#).isUnavailable)
        XCTAssertFalse(try row(#","availability":"unknown""#).isUnavailable)
        let own = #"{"totalCents":1,"rangeMaxCents":null,"kind":"total","nights":7,"persons":8,"startDate":null,"endDate":null,"forThisTrip":true,"capturedAt":null,"available":false}"#
        XCTAssertTrue(try row("", price: own).isUnavailable)
        XCTAssertFalse(try row("", price: own.replacingOccurrences(of: #""forThisTrip":true"#, with: #""forThisTrip":false"#)).isUnavailable,
                       "belegt in einem anderen Zeitraum sagt nichts über die Reise")
    }

    func testMoveToWatchlistAndBack() async throws {
        let demo = DemoBackend()
        let all = try await demo.trips()
        let watchlist = try XCTUnwrap(all.first(where: \.isWatchlist))
        let moved = try await demo.move(candidateId: "c-1", toTrip: watchlist.id)
        var here = try await demo.candidates(tripId: "t-1")
        XCTAssertFalse(here.contains { $0.id == "c-1" })
        let there = try await demo.candidates(tripId: watchlist.id)
        XCTAssertEqual(there.map(\.id), [moved])
        XCTAssertEqual(there.first?.status, .new, "Favorit war es in der alten Reise")
        XCTAssertEqual(there.first?.votes.total, 0, "Stimmen bleiben in der alten Reise")
        XCTAssertEqual(there.first?.price?.forThisTrip, false, "der Preis galt für die alte Reise")
        let detail = try await demo.candidate(moved)
        XCTAssertEqual(detail.comments.count, 1, "Kommentare ziehen mit")
        _ = try await demo.move(candidateId: moved, toTrip: "t-2")
        here = try await demo.candidates(tripId: "t-2")
        XCTAssertTrue(here.contains { $0.id == moved })
        do {
            _ = try await demo.move(candidateId: moved, toTrip: "gibt-es-nicht")
            XCTFail("Unbekannte Reise")
        } catch let error as APIError { XCTAssertEqual(error.status, 404) }
    }

    func testTripKindDecodes() throws {
        let json = #"{"id":"w","title":"Merkliste","region":null,"adults":2,"children":0,"pets":0,"budgetTotalCents":null,"status":"planning","voteDeadline":null,"createdAt":"2026-11-16T00:00:00.000Z","role":"organizer","candidateCount":1,"favoriteCount":0,"kind":"watchlist"}"#
        XCTAssertTrue(try APIClient.decoder.decode(Trip.self, from: Data(json.utf8)).isWatchlist)
        XCTAssertFalse(try APIClient.decoder.decode(Trip.self, from: Data(json.replacingOccurrences(of: #","kind":"watchlist""#, with: "").utf8)).isWatchlist)
    }

    func testDeleteRemovesOfferAndUpdatesCounts() async throws {
        let demo = DemoBackend()
        try await demo.delete(candidateId: "c-1")
        let list = try await demo.candidates(tripId: "t-1")
        XCTAssertEqual(list.map(\.id), ["c-2", "c-3", "c-5"])
        let trips = try await demo.trips()
        XCTAssertEqual(trips.first { $0.id == "t-1" }?.candidateCount, 3)
        XCTAssertEqual(trips.first { $0.id == "t-1" }?.favoriteCount, 0)
        do {
            try await demo.delete(candidateId: "c-1")
            XCTFail("Ein gelöschtes Angebot darf nicht noch einmal löschbar sein")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testImportMarksBlockedPlatformAndDuplicates() async throws {
        let demo = DemoBackend()
        let first = try await demo.importLink(tripId: "t-2", url: "https://www.fewo-direkt.de/ferienwohnung-ferienhaus/p123", html: nil)
        XCTAssertFalse(first.duplicate)
        XCTAssertEqual(first.platform, "vrbo")
        let detail = try await demo.candidate(first.candidateId)
        XCTAssertEqual(detail.candidate.importStatus, .partial)
        let again = try await demo.importLink(tripId: "t-2", url: "https://www.fewo-direkt.de/ferienwohnung-ferienhaus/p123", html: nil)
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(again.candidateId, first.candidateId)
    }
}

final class LedgerTests: XCTestCase {
    func testAmountsAsPeopleTypeThem() {
        XCTAssertEqual(Format.cents(from: "84,50"), 8450)
        XCTAssertEqual(Format.cents(from: "84.5"), 8450)
        XCTAssertEqual(Format.cents(from: "1.234,00 €"), 123_400)
        XCTAssertEqual(Format.cents(from: "1.234"), 123_400)
        XCTAssertEqual(Format.cents(from: "12"), 1200)
        XCTAssertNil(Format.cents(from: ""))
        XCTAssertNil(Format.cents(from: "0"))
        XCTAssertNil(Format.cents(from: "abc"))
    }

    func testSharesAddUpToTheCent() {
        let parties = ["a", "b", "c"].map { LedgerParty(id: $0, name: $0) }
        let shares = LedgerMath.shares(of: Expense(id: "e", title: "x", amountCents: 1000, paidBy: "a"), parties: parties, splitMode: "equal", childWeight: 1)
        XCTAssertEqual(shares?.values.reduce(0, +), 1000)
        XCTAssertEqual(shares?.values.sorted(), [333, 333, 334])
    }

    func testHeadsCountChildrenByWeight() {
        let parties = [LedgerParty(id: "a", name: "A", adults: 2, children: 2), LedgerParty(id: "b", name: "B", adults: 1, children: 0)]
        let shares = LedgerMath.shares(of: Expense(id: "e", title: "x", amountCents: 8000, paidBy: "a", mode: "heads"), parties: parties, splitMode: "equal", childWeight: 0.5)
        XCTAssertEqual(shares, ["a": 6000, "b": 2000])
    }

    func testExpenseOfRemovedHouseholdIsLeftOut() {
        let parties = [LedgerParty(id: "a", name: "A"), LedgerParty(id: "b", name: "B")]
        let ledger = LedgerMath.ledger(parties: parties, expenses: [Expense(id: "e", title: "x", amountCents: 500, paidBy: "weg")], payments: [],
                                       splitMode: "equal", childWeight: 1, myPartyId: nil)
        XCTAssertEqual(ledger.totalCents, 0)
        XCTAssertEqual(ledger.expenses.first?.unsplit, true)
    }

    func testSampleLedgerBalancesAndSettles() async throws {
        let demo = DemoBackend()
        let ledger = try await demo.ledger(tripId: "t-1")
        XCTAssertEqual(ledger.myPartyId, "p-1")
        XCTAssertEqual(ledger.totalCents, 178_260)
        XCTAssertEqual(ledger.parties.reduce(0) { $0 + $1.balanceCents }, 0)
        XCTAssertEqual(ledger.parties.reduce(0) { $0 + $1.shareCents }, ledger.totalCents)
        XCTAssertFalse(ledger.transfers.isEmpty)
        // Ticking off every suggestion leaves nobody owing anything.
        var settled = ledger
        for transfer in ledger.transfers {
            settled = try await demo.addPayment(tripId: "t-1", from: transfer.from, to: transfer.to, amountCents: transfer.amountCents)
        }
        XCTAssertTrue(settled.transfers.isEmpty)
        XCTAssertTrue(settled.parties.allSatisfy { $0.balanceCents == 0 })
    }

    func testExpensesNeedHouseholdsAndCanBeChanged() async throws {
        let demo = DemoBackend()
        do {
            _ = try await demo.addExpense(tripId: "t-2", expense: ExpenseDraft(title: "Fähre", amountCents: 1000, paidBy: "p"))
            XCTFail("Ohne Haushalte darf es keine Ausgabe geben")
        } catch let error as APIError { XCTAssertEqual(error.code, "no_parties") }
        let start = try await demo.suggestParties(tripId: "t-2")
        XCTAssertEqual(start.parties.count, 3)
        let payer = start.parties[0].id
        var ledger = try await demo.addExpense(tripId: "t-2", expense: ExpenseDraft(title: "Fähre", amountCents: 9000, paidBy: payer))
        XCTAssertEqual(ledger.parties[0].balanceCents, 6000)
        let id = try XCTUnwrap(ledger.expenses.first?.id)
        ledger = try await demo.updateExpense(expenseId: id, expense: ExpenseDraft(title: "Fähre", amountCents: 9000, paidBy: payer, among: [payer, start.parties[1].id]))
        XCTAssertEqual(ledger.parties[0].balanceCents, 4500)
        ledger = try await demo.deleteExpense(expenseId: id)
        XCTAssertTrue(ledger.expenses.isEmpty)
    }

    func testLedgerDecodesAndDraftSendsNullMode() throws {
        let json = #"{"splitMode":"heads","childWeight":0.5,"myPartyId":"a","totalCents":100,"parties":[{"id":"a","name":"A","adults":2,"children":1,"memberIds":[],"paidCents":100,"shareCents":100,"balanceCents":0}],"expenses":[{"id":"e","title":"x","amountCents":100,"paidBy":"a","mode":null,"among":[],"weights":{},"spentOn":"2027-05-16","unsplit":false}],"payments":[],"transfers":[]}"#
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.childWeight, 0.5)
        XCTAssertEqual(ledger.expenses.first?.spentOn, "2027-05-16")
        let sent = String(decoding: try JSONEncoder().encode(ExpenseDraft(title: "x", amountCents: 1, paidBy: "a")), as: UTF8.self)
        XCTAssertTrue(sent.contains(#""mode":null"#))
        let party = String(decoding: try JSONEncoder().encode(PartyDraft(name: "Neu")), as: UTF8.self)
        XCTAssertFalse(party.contains("localID"))
    }
}

final class FramingTests: XCTestCase {
    func testChangesSendClearedFieldsAsNull() throws {
        let sent = String(decoding: try JSONEncoder().encode(TripChanges(title: "X", region: nil, adults: 2, children: 0, pets: 0, budgetTotalCents: nil)), as: UTF8.self)
        XCTAssertTrue(sent.contains(#""region":null"#))
        XCTAssertTrue(sent.contains(#""budgetTotalCents":null"#))
    }

    func testFrameCanBeChangedInSampleData() async throws {
        let demo = DemoBackend()
        var changes = TripChanges(try await demo.trip("t-1").trip)
        changes.adults = 5; changes.budgetTotalCents = nil
        let trip = try await demo.updateTrip(tripId: "t-1", changes: changes)
        XCTAssertEqual(trip.persons, 9)
        XCTAssertNil(trip.budgetTotalCents)
        let option = try await demo.addDateOption(tripId: "t-1", label: "Herbst", startDate: "2027-10-16", endDate: "2027-10-23")
        var detail = try await demo.trip("t-1")
        XCTAssertEqual(detail.dateOptions.count, 2)
        try await demo.removeDateOption(tripId: "t-1", optionId: option.id)
        detail = try await demo.trip("t-1")
        XCTAssertEqual(detail.dateOptions.map(\.id), ["d-1"])
    }

    func testActivityDecodesLooselyAndReadsAsSentence() throws {
        let json = #"[{"id":7,"type":"expense_added","payload":{"expenseId":"x","amountCents":8450},"createdAt":"2026-11-16T10:00:00.000Z","userName":"Anna"},{"id":"b","type":"neu_und_unbekannt","payload":null,"userName":null}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            guard let date = APIClient.parseDate(text) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: text)) }
            return date
        }
        let events = try decoder.decode([ActivityEvent].self, from: Data(json.utf8))
        XCTAssertEqual(events[0].id, "7")
        XCTAssertEqual(events[0].sentence, "hat eine Ausgabe über 84,50\u{a0}€ eingetragen")
        XCTAssertNotNil(events[0].createdAt)
        XCTAssertEqual(events[1].sentence, "hat etwas geändert")
    }
}
