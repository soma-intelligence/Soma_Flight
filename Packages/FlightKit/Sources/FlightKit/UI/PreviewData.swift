import Foundation

/// Seed-backed samples for `#Preview`s and snapshot tests. Times stay at the seed's own "now".
enum PreviewData {
    static let now = FakeSeed.reference
    static let airports: [Airport] = FakeSeed.load("airports")
    static let followed: [Flight] = FakeSeed.load("followed")
    static let boards: [AirportBoard] = FakeSeed.load("boards")
    static let weather: [String: Weather] = FakeSeed.load("weather")
    private struct Pair: Decodable { var departures: DelayStats; var arrivals: DelayStats }
    private static let statsPairs: [String: Pair] = FakeSeed.load("stats")

    static func airport(_ icao: String) -> Airport? { airports.first { $0.id == icao } }
    static func board(_ icao: String, _ kind: BoardKind) -> AirportBoard {
        boards.first { $0.icao == icao && $0.kind == kind }!
    }
    static func stats(_ icao: String, departures: Bool = true) -> DelayStats {
        departures ? statsPairs[icao]!.departures : statsPairs[icao]!.arrivals
    }

    /// AF84, en route with a position.
    static var enRoute: Flight { followed[0] }
    /// AS312: no estimates, no times beyond schedule, few fields.
    static var sparse: Flight { followed.first { $0.ident == "AS312" }! }
    static var canceled: Flight { followed.first { $0.status == .canceled }! }
    static var diverted: Flight { followed.first { $0.status == .diverted }! }
    static var kaus: Airport { airport("KAUS")! }
}
