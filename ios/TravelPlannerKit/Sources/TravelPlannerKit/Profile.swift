import Foundation

/// The standardised listing profile ("Steckbrief"), see backend/src/import/profile.ts.
/// `nil` means "not known"; the app never fills in a guess.
public struct Profile: Codable, Hashable, Sendable {
    public struct Bed: Codable, Hashable, Sendable {
        public var room: String
        public var beds: String
    }
    public struct Distances: Codable, Hashable, Sendable {
        public var beachM: Double?
        public var seaM: Double?
        public var townM: Double?
        public var shopM: Double?
        public var restaurantM: Double?
        public var airportKm: Double?
        public init() {}
    }
    public struct Rules: Codable, Hashable, Sendable {
        public var checkInFrom: String?
        public var checkOutUntil: String?
        public var minNights: Double?
        public var arrivalDays: String?
        public var smoking: String?
        public init() {}
    }
    public struct ExtraCost: Codable, Hashable, Sendable {
        public var item: String
        public var amountEur: Double?
        public var note: String?
    }
    public struct Price: Codable, Hashable, Sendable {
        public var startDate: String?
        public var endDate: String?
        public var nights: Double?
        public var persons: Double?
        public var totalEur: Double?
        public var kind: PriceKind?
        public var rangeMaxEur: Double?
        public var included: [String]?
        public var extraCosts: [ExtraCost]?
        public var depositEur: Double?
        public init() {}
    }
    public struct PackageTrip: Codable, Hashable, Sendable {
        public var hotelStars: Double?
        public var board: String?
        public var roomType: String?
        public var departureAirport: String?
        public var durationDays: Double?
        public var transferIncluded: Bool?
        public var tourOperator: String?
        public init() {}
    }

    public var kind: ListingKind?
    public var title: String?
    public var objectType: String?
    public var place: String?
    public var region: String?
    public var country: String?
    public var lat: Double?
    public var lon: Double?

    public var maxGuests: Double?
    public var bedrooms: Double?
    public var beds: Double?
    public var sleepingPlaces: Double?
    public var bedDetails: [Bed]?
    public var bathrooms: Double?
    public var livingAreaSqm: Double?
    public var plotSqm: Double?
    public var yearBuilt: Double?

    /// Keyed by the amenity names of the backend (`pool`, `wifi`, ...). A missing or null value means unknown.
    public var amenities: [String: Bool?]?
    public var poolType: String?
    public var otherAmenities: [String]?

    public var distances: Distances?
    public var rating: Rating?
    public var rules: Rules?
    public var price: Price?
    public var cancellation: String?
    public var packageTrip: PackageTrip?

    public var photoCount: Double?
    public var coverImageUrl: String?
    public var summary: String?
    public var highlights: [String]?
    public var warnings: [String]?
    /// Dotted field paths whose value is unsure, for example `livingAreaSqm` or `amenities.grill`.
    public var uncertain: [String]?

    public init() {}

    public func isUncertain(_ path: String) -> Bool {
        uncertain?.contains(path) ?? false
    }

    public func amenity(_ key: String) -> Bool? {
        amenities?[key] ?? nil
    }

    /// Order in which amenities are shown, matching `amenityKeys` of the backend.
    public static let amenityKeys = [
        "pool", "poolHeated", "airConditioning", "wifi", "dishwasher", "washingMachine", "grill", "fireplace", "sauna",
        "hotTub", "parking", "evCharger", "seaView", "cot", "highChair", "fenced", "petsAllowed",
    ]
}
