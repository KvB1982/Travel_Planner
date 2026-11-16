import Foundation

/// One corrected value of the fact sheet. `null` says: not known after all.
public enum PatchValue: Encodable, Hashable, Sendable {
    case number(Double), text(String), null

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let value): try c.encode(value)
        case .text(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

/// A price noted by hand for the dates and party of the trip.
public struct ManualPrice: Encodable, Hashable, Sendable {
    public var totalCents: Int
    public var startDate: String?
    public var endDate: String?
    public var persons: Int?
    public var available: Bool?

    public init(totalCents: Int, startDate: String?, endDate: String?, persons: Int?, available: Bool? = nil) {
        self.totalCents = totalCents; self.startDate = startDate; self.endDate = endDate; self.persons = persons; self.available = available
    }
}

/// The fields of the fact sheet that can be corrected by hand in the app, with what was read from the advert.
public enum Correction {
    public struct Field: Identifiable, Hashable, Sendable {
        public var key: String
        public var label: String
        public var isNumber: Bool
        public var id: String { key }
    }

    public static let fields: [Field] = [
        Field(key: "title", label: "Titel", isNumber: false),
        Field(key: "place", label: "Ort", isNumber: false),
        Field(key: "region", label: "Region", isNumber: false),
        Field(key: "country", label: "Land", isNumber: false),
        Field(key: "maxGuests", label: "Gäste", isNumber: true),
        Field(key: "bedrooms", label: "Schlafzimmer", isNumber: true),
        Field(key: "beds", label: "Betten", isNumber: true),
        Field(key: "bathrooms", label: "Bäder", isNumber: true),
        Field(key: "livingAreaSqm", label: "Wohnfläche in m²", isNumber: true),
        Field(key: "plotSqm", label: "Grundstück in m²", isNumber: true),
    ]

    /// What the fact sheet says today, as people would type it. Empty when unknown.
    public static func text(_ field: Field, in profile: Profile) -> String {
        func number(_ value: Double?) -> String {
            guard let value else { return "" }
            return value == value.rounded() ? String(Int(value)) : String(value).replacingOccurrences(of: ".", with: ",")
        }
        switch field.key {
        case "title": return profile.title ?? ""
        case "place": return profile.place ?? ""
        case "region": return profile.region ?? ""
        case "country": return profile.country ?? ""
        case "maxGuests": return number(profile.maxGuests)
        case "bedrooms": return number(profile.bedrooms)
        case "beds": return number(profile.beds)
        case "bathrooms": return number(profile.bathrooms)
        case "livingAreaSqm": return number(profile.livingAreaSqm)
        case "plotSqm": return number(profile.plotSqm)
        default: return ""
        }
    }

    /// Only what differs from the fact sheet. nil when a number cannot be read.
    public static func changes(from profile: Profile, typed: [String: String]) -> [String: PatchValue]? {
        var result: [String: PatchValue] = [:]
        for field in fields {
            let new = (typed[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            guard new != text(field, in: profile) else { continue }
            if new.isEmpty {
                // The server does not take a title of nothing.
                if field.key == "title" { return nil }
                result[field.key] = .null
            } else if field.isNumber {
                guard let value = Double(new.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
                result[field.key] = .number(value)
            } else {
                result[field.key] = .text(new)
            }
        }
        return result
    }
}
