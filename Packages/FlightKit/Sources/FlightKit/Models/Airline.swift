import Foundation

public enum Alliance: String, Codable, Sendable, Hashable, CaseIterable {
    case starAlliance = "star_alliance"
    case oneworld
    case skyteam

    public var title: String {
        switch self {
        case .starAlliance: "Star Alliance"
        case .oneworld: "oneworld"
        case .skyteam: "SkyTeam"
        }
    }
}

/// An airline from the bundled reference list (Resources/Reference/airlines.json). The list writes
/// a missing value as an empty string; it decodes as nil here.
public struct Airline: Codable, Sendable, Hashable, Identifiable {
    /// ICAO designator, "UAL".
    public var id: String
    public var iata: String?
    public var name: String
    public var callsign: String?
    public var alliance: Alliance?
    /// ISO 3166-1 alpha-2.
    public var country: String?
    /// "#RRGGBB".
    public var colorPrimary: String
    public var colorSecondary: String?
    public var phone: String?
    public var website: URL?
    public var x: URL?
    public var facebook: URL?

    public init(id: String, iata: String? = nil, name: String, callsign: String? = nil, alliance: Alliance? = nil,
                country: String? = nil, colorPrimary: String, colorSecondary: String? = nil, phone: String? = nil,
                website: URL? = nil, x: URL? = nil, facebook: URL? = nil) {
        self.id = id; self.iata = iata; self.name = name; self.callsign = callsign; self.alliance = alliance
        self.country = country; self.colorPrimary = colorPrimary; self.colorSecondary = colorSecondary
        self.phone = phone; self.website = website; self.x = x; self.facebook = facebook
    }

    private enum CodingKeys: String, CodingKey {
        case id = "icao", iata, name, callsign, alliance, country, colorPrimary, colorSecondary, phone, website, x, facebook
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String? {
            guard let s = try c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
            return s
        }
        func link(_ key: CodingKeys) throws -> URL? { try text(key).flatMap { URL(string: $0) } }
        id = try c.decode(String.self, forKey: .id)
        iata = try text(.iata)
        name = try c.decode(String.self, forKey: .name)
        callsign = try text(.callsign)
        alliance = try text(.alliance).flatMap { Alliance(rawValue: $0) }
        country = try text(.country)
        colorPrimary = try c.decode(String.self, forKey: .colorPrimary)
        colorSecondary = try text(.colorSecondary)
        phone = try text(.phone)
        website = try link(.website); x = try link(.x); facebook = try link(.facebook)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(iata, forKey: .iata)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(callsign, forKey: .callsign)
        try c.encodeIfPresent(alliance, forKey: .alliance)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encode(colorPrimary, forKey: .colorPrimary)
        try c.encodeIfPresent(colorSecondary, forKey: .colorSecondary)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(facebook, forKey: .facebook)
    }
}
