import Foundation

public enum BoardKind: String, Codable, Sendable, Hashable {
    case departures, arrivals, stats, weather
}

public struct AirportBoard: Codable, Sendable, Hashable {
    public var icao: String
    public var kind: BoardKind
    public var fetchedAt: Date
    public var stale: Bool
    public var flights: [Flight]

    public init(icao: String, kind: BoardKind, fetchedAt: Date, stale: Bool, flights: [Flight]) {
        self.icao = icao; self.kind = kind; self.fetchedAt = fetchedAt; self.stale = stale; self.flights = flights
    }
}
