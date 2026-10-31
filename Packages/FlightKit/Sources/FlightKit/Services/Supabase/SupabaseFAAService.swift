import Foundation
import Supabase

/// FAA advisories from `faa-status` (the FAA's NAS status feed, cached 5 minutes for everyone) and
/// `faa-notams` (the FAA NOTAM API, cached 15 minutes per airport). `decodePrograms` and `decodeNotams`
/// are the exact paths the answers take, and the contract tests run the backend's example files
/// through them.
public final class SupabaseFAAService: FAAService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// `faa-status`'s answer as it travels.
    struct ProgramsAnswer: Decodable, Sendable {
        var airport: String
        var iata: String?
        var available: Bool
        var stale: Bool?
        var fetchedAt: Date
        var programs: [Program]

        struct Program: Decodable, Sendable {
            var airport: String
            var kind: String
            var reason: String?
            var reasonRaw: String?
            var averageMinutes: Int?
            var trend: String?
            var `extension`: String?
            var startsAt: Date?
            var endsAt: Date?
            var updatedAt: Date?
            var advisoryUrl: String?
        }
    }

    /// `faa-notams`'s answer as it travels.
    struct NotamsAnswer: Decodable, Sendable {
        var airport: String
        var iata: String?
        var configured: Bool
        var stale: Bool?
        var fetchedAt: Date
        var notams: [Item]

        struct Item: Decodable, Sendable {
            var number: String
            var kind: String
            var title: String
            var detail: String?
            var relevance: Int
            var raw: String
            var startsAt: Date?
            var endsAt: Date?
            var endsEstimated: Bool?
        }
    }

    /// The airport's programs, or nil outside the US. A program of a kind this build does not know (a
    /// newer backend) is left out rather than failing the rest.
    public static func decodePrograms(_ data: Data) throws -> AirportPrograms? {
        let a = try FlightJSON.decoder.decode(ProgramsAnswer.self, from: data)
        guard a.available else { return nil }
        let programs = a.programs.compactMap { p -> AirportProgram? in
            guard let kind = AirportProgram.Kind(rawValue: p.kind) else { return nil }
            return AirportProgram(airport: p.airport, kind: kind, reason: p.reason, reasonRaw: p.reasonRaw,
                                  averageMinutes: p.averageMinutes, trend: p.trend.flatMap(AirportProgram.Trend.init),
                                  extensionChance: p.extension.flatMap(AirportProgram.Extension.init),
                                  startsAt: p.startsAt, endsAt: p.endsAt, updatedAt: p.updatedAt,
                                  advisoryURL: p.advisoryUrl.flatMap(URL.init(string:)))
        }
        return AirportPrograms(airportIcao: a.airport, iata: a.iata, isStale: a.stale ?? false,
                               fetchedAt: a.fetchedAt, programs: AirportProgram.sorted(programs))
    }

    /// The airport's notices, or nil while the backend has no FAA NOTAM key. Unknown kinds are left out.
    public static func decodeNotams(_ data: Data) throws -> NotamReport? {
        let a = try FlightJSON.decoder.decode(NotamsAnswer.self, from: data)
        guard a.configured else { return nil }
        let notams = a.notams.compactMap { n -> Notam? in
            guard let kind = Notam.Kind(rawValue: n.kind) else { return nil }
            return Notam(number: n.number, kind: kind, title: n.title, detail: n.detail, relevance: n.relevance,
                         raw: n.raw, startsAt: n.startsAt, endsAt: n.endsAt, endsEstimated: n.endsEstimated ?? false)
        }
        return NotamReport(airportIcao: a.airport, iata: a.iata, isStale: a.stale ?? false, fetchedAt: a.fetchedAt,
                           notams: notams)
    }

    public func programs(airport: String) async throws(APIError) -> AirportPrograms? {
        try await backend.call("faa-status", method: .get, query: [URLQueryItem(name: "airport", value: airport)],
                               decode: Self.decodePrograms)
    }

    public func notams(airport: String) async throws(APIError) -> NotamReport? {
        try await backend.call("faa-notams", method: .get, query: [URLQueryItem(name: "airport", value: airport)],
                               decode: Self.decodeNotams)
    }
}
