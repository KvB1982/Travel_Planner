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

    func testDetailWithNullReviews() throws {
        struct Wrapper: Decodable { var reviews: Reviews? }
        XCTAssertNil(try APIClient.decoder.decode(Wrapper.self, from: Data(#"{"reviews":null}"#.utf8)).reviews)
    }
}

final class DemoBackendTests: XCTestCase {
    func testVoteAndCountsStayConsistent() async throws {
        let demo = DemoBackend()
        let trips = try await demo.trips()
        XCTAssertEqual(trips.first?.candidateCount, 3)
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

    func testDeleteRemovesOfferAndUpdatesCounts() async throws {
        let demo = DemoBackend()
        try await demo.delete(candidateId: "c-1")
        let list = try await demo.candidates(tripId: "t-1")
        XCTAssertEqual(list.map(\.id), ["c-2", "c-3"])
        let trips = try await demo.trips()
        XCTAssertEqual(trips.first { $0.id == "t-1" }?.candidateCount, 2)
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
