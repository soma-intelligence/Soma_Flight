import Foundation

public enum WorldRegion: String, Codable, Sendable, CaseIterable {
    case europe
    case northAmerica = "north_america"
    case centralAmerica = "central_america"
    case caribbean
    case southAmerica = "south_america"
    case africa
    case middleEast = "middle_east"
    case asia
    case oceania

    public var title: String {
        switch self {
        case .europe: "Europe"
        case .northAmerica: "N. America"
        case .centralAmerica: "C. America"
        case .caribbean: "Caribbean"
        case .southAmerica: "S. America"
        case .africa: "Africa"
        case .middleEast: "Middle East"
        case .asia: "Asia"
        case .oceania: "Oceania"
        }
    }

    /// Row-major order of the three-by-three region grid.
    public static let gridOrder: [WorldRegion] = [
        .europe, .northAmerica, .asia, .caribbean, .africa, .centralAmerica, .middleEast, .oceania, .southAmerica,
    ]
}

/// A country from the bundled reference list (Resources/Reference/countries.json).
public struct Country: Codable, Sendable, Hashable, Identifiable {
    /// ISO 3166-1 alpha-2, upper case.
    public var id: String
    public var name: String
    public var region: WorldRegion

    public init(id: String, name: String, region: WorldRegion) {
        self.id = id; self.name = name; self.region = region
    }

    private enum CodingKeys: String, CodingKey { case id = "iso2", name, region }
}
