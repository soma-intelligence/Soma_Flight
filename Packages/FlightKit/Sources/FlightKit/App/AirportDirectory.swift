import Foundation

/// Every airport the app knows, by ICAO and by IATA, for the synchronous lookups the screens need
/// (far-end city names, local times, globe pins). Built once from the bundled reference list.
public struct AirportDirectory: Sendable {
    public let all: [Airport]
    private let byCode: [String: Airport]

    public init(_ airports: [Airport]) {
        all = airports.sorted { $0.id < $1.id }
        var map: [String: Airport] = [:]
        for a in all {
            map[a.id.uppercased()] = a
            if let iata = a.iata, map[iata.uppercased()] == nil { map[iata.uppercased()] = a }
        }
        byCode = map
    }

    /// The bundled list (Resources/Fakes/airports.json).
    public static func bundled() -> AirportDirectory { AirportDirectory(FakeSeed.load("airports")) }

    /// Airport by ICAO or IATA code, any case.
    public func airport(_ code: String) -> Airport? {
        byCode[code.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// The lookup closure the screens take.
    public var lookup: @Sendable (String) -> Airport? {
        let me = self
        return { me.airport($0) }
    }
}
