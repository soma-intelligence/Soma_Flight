import Foundation

public enum AircraftFamily: String, Codable, Sendable, CaseIterable {
    case a220, a320, a330, a350, a380, b737, b737max, b747, b757, b767, b777, b787, ejet, crj, atr, other

    public var isWidebody: Bool {
        switch self {
        case .a330, .a350, .a380, .b747, .b767, .b777, .b787: true
        default: false
        }
    }
}

/// An aircraft type from the bundled reference list (Resources/Reference/aircraft_types.json).
public struct AircraftType: Codable, Sendable, Hashable, Identifiable {
    /// ICAO type designator, "B38M".
    public var id: String
    public var family: AircraftFamily
    public var manufacturer: String
    public var name: String

    public init(id: String, family: AircraftFamily, manufacturer: String, name: String) {
        self.id = id; self.family = family; self.manufacturer = manufacturer; self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id = "icaoType", family, manufacturer, name }
}
