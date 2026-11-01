import Foundation
import Supabase

/// The Airports list and the airport card's live layer. Live builds use `SupabaseAirportOverviewService`
/// (`airport-weather`, `airport-stats`, `airport_regulars`); screenshot runs (`-useFakes`) use
/// `FakeAirportOverviewService`.
public protocol AirportOverviewService: Sendable {
    /// Weather and FAA programs for these airports (ICAO or IATA), in that order; unknown codes are left out.
    func overviews(_ codes: [String]) async throws(APIError) -> [AirportOverview]
    /// The list's on-time and delay columns; `available` false while the backend has no board provider.
    func liveSummaries(_ codes: [String]) async throws(APIError) -> AirportLiveList
    /// The card's live numbers; nil when this service cannot tell (the card then keeps its own boards).
    func liveStats(_ code: String) async throws(APIError) -> AirportLiveStats?
    /// The user and the friends who share their Passport, by flights through the airport, most first.
    func regulars(_ code: String) async throws(APIError) -> [RunwayRegular]
}

/// Nothing anywhere and no network call: the default for stores built without a service.
public struct UnavailableAirportOverviewService: AirportOverviewService {
    public init() {}
    public func overviews(_ codes: [String]) async throws(APIError) -> [AirportOverview] { [] }
    public func liveSummaries(_ codes: [String]) async throws(APIError) -> AirportLiveList {
        AirportLiveList(available: false, airports: [])
    }
    public func liveStats(_ code: String) async throws(APIError) -> AirportLiveStats? { nil }
    public func regulars(_ code: String) async throws(APIError) -> [RunwayRegular] { [] }
}

/// The backend: two edge functions and one database function, each as the signed-in user.
public final class SupabaseAirportOverviewService: AirportOverviewService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The most codes one call takes (the functions refuse more).
    static let weatherBatch = 40
    static let statsBatch = 20

    // MARK: Wire shapes

    struct WeatherAnswer: Decodable, Sendable {
        var airports: [Item]
        struct Item: Decodable, Sendable {
            var icao: String
            var iata: String?
            var weather: AirportConditions?
            var faa: Faa?
        }
        struct Faa: Decodable, Sendable {
            var programs: [SupabaseFAAService.ProgramsAnswer.Program]
        }
    }

    struct ListAnswer: Decodable, Sendable {
        var available: Bool
        var airports: [Item]
        struct Item: Decodable, Sendable {
            var icao: String
            var stale: Bool
            var departures: AirportBrief?
            var arrivals: AirportBrief?
        }
    }

    struct RegularRow: Decodable, Sendable {
        var userId: UUID
        var isMe: Bool
        var displayName: String?
        var emoji: String?
        var visits: Int
        var lastVisit: String?
    }

    // MARK: Decoding (the contract tests run the backend's example files through these)

    public static func decodeOverviews(_ data: Data) throws -> [AirportOverview] {
        let a = try FlightJSON.decoder.decode(WeatherAnswer.self, from: data)
        return a.airports.map { item in
            AirportOverview(icao: item.icao, iata: item.iata, weather: item.weather,
                            programs: item.faa.map { faa in
                                AirportProgram.sorted(faa.programs.compactMap(SupabaseFAAService.program(from:)))
                            })
        }
    }

    public static func decodeSummaries(_ data: Data) throws -> AirportLiveList {
        let a = try FlightJSON.decoder.decode(ListAnswer.self, from: data)
        return AirportLiveList(available: a.available, airports: a.airports.map {
            AirportLiveSummary(icao: $0.icao, departures: $0.departures, arrivals: $0.arrivals, stale: $0.stale)
        })
    }

    public static func decodeLiveStats(_ data: Data) throws -> AirportLiveStats? {
        try FlightJSON.decoder.decode(AirportLiveStats.self, from: data)
    }

    public static func decodeRegulars(_ data: Data) throws -> [RunwayRegular] {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .gmt
        day.dateFormat = "yyyy-MM-dd"
        return try FlightJSON.decoder.decode([RegularRow].self, from: data).map {
            RunwayRegular(userId: $0.userId, isMe: $0.isMe, displayName: $0.displayName, emoji: $0.emoji,
                          visits: $0.visits, lastVisit: $0.lastVisit.flatMap(day.date(from:)))
        }
    }

    // MARK: Calls

    public func overviews(_ codes: [String]) async throws(APIError) -> [AirportOverview] {
        var out: [AirportOverview] = []
        for chunk in Self.chunks(codes, Self.weatherBatch) {
            out += try await backend.call("airport-weather", method: .get,
                                          query: [URLQueryItem(name: "airports", value: chunk.joined(separator: ","))],
                                          decode: Self.decodeOverviews)
        }
        return out
    }

    public func liveSummaries(_ codes: [String]) async throws(APIError) -> AirportLiveList {
        var out = AirportLiveList(available: true, airports: [])
        for chunk in Self.chunks(codes, Self.statsBatch) {
            let part = try await backend.call("airport-stats", method: .get,
                                              query: [URLQueryItem(name: "airports", value: chunk.joined(separator: ","))],
                                              decode: Self.decodeSummaries)
            // No provider: one answer says it for every airport, so stop asking.
            guard part.available else { return AirportLiveList(available: false, airports: []) }
            out.airports += part.airports
        }
        return out
    }

    public func liveStats(_ code: String) async throws(APIError) -> AirportLiveStats? {
        try await backend.call("airport-stats", method: .get, query: [URLQueryItem(name: "airport", value: code)],
                               decode: Self.decodeLiveStats)
    }

    public func regulars(_ code: String) async throws(APIError) -> [RunwayRegular] {
        struct Params: Encodable, Sendable { var p_icao: String }
        let data = try await backend.write { try $0.rpc("airport_regulars", params: Params(p_icao: code)) }
        do { return try Self.decodeRegulars(data) } catch { throw .decoding("\(error)") }
    }

    static func chunks(_ codes: [String], _ size: Int) -> [[String]] {
        stride(from: 0, to: codes.count, by: size).map { Array(codes[$0..<min($0 + size, codes.count)]) }
    }
}
