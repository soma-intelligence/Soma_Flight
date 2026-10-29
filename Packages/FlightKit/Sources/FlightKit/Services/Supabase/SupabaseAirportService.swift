import Foundation
import Supabase

/// Airports from the bundled directory (the `airports` table when a code is not in it), boards, delay
/// stats and weather from `airport-board`. The `decode…` functions are the exact path the answers take,
/// and the contract tests run the backend's example files through them.
public final class SupabaseAirportService: AirportService {
    private let backend: SupabaseBackend
    private let directory: @Sendable (String) -> Airport?

    /// - Parameter airport: the bundled directory (ICAO or IATA).
    public init(backend: SupabaseBackend, airport: @escaping @Sendable (String) -> Airport?) {
        self.backend = backend; self.directory = airport
    }

    // MARK: Decoding (shared with the contract tests)

    public struct StatsAnswer: Decodable, Sendable {
        public var icao: String
        public var fetchedAt: Date
        public var stale: Bool
        public var departures: DelayStats
        public var arrivals: DelayStats
    }

    public struct WeatherAnswer: Decodable, Sendable {
        public var icao: String
        public var fetchedAt: Date
        public var stale: Bool
        public var weather: Weather
    }

    public static func decodeBoard(_ data: Data) throws -> AirportBoard {
        try FlightJSON.decoder.decode(AirportBoard.self, from: data)
    }

    public static func decodeStats(_ data: Data) throws -> StatsAnswer {
        try FlightJSON.decoder.decode(StatsAnswer.self, from: data)
    }

    public static func decodeWeather(_ data: Data) throws -> WeatherAnswer {
        try FlightJSON.decoder.decode(WeatherAnswer.self, from: data)
    }

    // MARK: AirportService

    /// A row of the `airports` table (city, country and zone may be null there).
    private struct AirportRow: Decodable {
        var icao: String
        var iata: String?
        var name: String
        var city: String?
        var country: String?
        var lat: Double
        var lon: Double
        var tz: String?

        var airport: Airport {
            Airport(id: icao, iata: iata, name: name, city: city ?? "", country: country ?? "", lat: lat, lon: lon,
                    tz: tz ?? "UTC")
        }
    }

    public func airport(_ code: String) async throws(APIError) -> Airport {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        if let known = directory(c) { return known }
        let column = c.count == 3 ? "iata" : "icao"
        let data = try await backend.rows { $0.from("airports").select().eq(column, value: c).limit(1) }
        let rows: [AirportRow]
        do { rows = try FlightJSON.decoder.decode([AirportRow].self, from: data) } catch { throw SupabaseBackend.map(error) }
        guard let row = rows.first else { throw .notFound }
        return row.airport
    }

    private func query(_ code: String, _ kind: BoardKind) -> [URLQueryItem] {
        [URLQueryItem(name: "airport", value: code.trimmingCharacters(in: .whitespaces).uppercased()),
         URLQueryItem(name: "kind", value: kind.rawValue)]
    }

    public func board(_ code: String, _ kind: BoardKind) async throws(APIError) -> AirportBoard {
        guard kind == .departures || kind == .arrivals else { throw .decoding("no board of kind \(kind.rawValue)") }
        return try await backend.call("airport-board", method: .get, query: query(code, kind), decode: Self.decodeBoard)
    }

    public func stats(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, departures: DelayStats, arrivals: DelayStats) {
        let s = try await backend.call("airport-board", method: .get, query: query(code, .stats), decode: Self.decodeStats)
        return (s.fetchedAt, s.stale, s.departures, s.arrivals)
    }

    public func weather(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, weather: Weather) {
        let w = try await backend.call("airport-board", method: .get, query: query(code, .weather), decode: Self.decodeWeather)
        return (w.fetchedAt, w.stale, w.weather)
    }
}
