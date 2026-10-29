public enum FlightStatus: String, Codable, Sendable, Hashable {
    case scheduled, departed
    case enRoute = "en_route"
    case landed, arrived, canceled, diverted, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FlightStatus(rawValue: raw) ?? .unknown
    }
}
