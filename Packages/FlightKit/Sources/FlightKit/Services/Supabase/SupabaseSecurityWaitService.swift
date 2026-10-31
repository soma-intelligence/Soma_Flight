import Foundation
import Supabase

/// The security wait from `security-wait`, which estimates it from typical checkpoint traffic (or reads a
/// live source when one is allowed) and caches each airport for 5 minutes. `decode` is the exact path the
/// answers take, and the contract tests run the backend's example files through it.
public final class SupabaseSecurityWaitService: SecurityWaitService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The function's answer as it travels.
    struct Answer: Decodable, Sendable {
        var airport: String
        var iata: String?
        var available: Bool
        var reason: String?
        var live: Bool
        var source: Source?
        var fetchedAt: Date
        var checkpoints: [Checkpoint]

        struct Source: Decodable, Sendable { var id: String; var name: String; var url: String? }

        struct Checkpoint: Decodable, Sendable {
            var id: String
            var name: String
            var terminal: String?
            var precheck: Bool?
            var standardMinutes: Int?
            var precheckMinutes: Int?
        }
    }

    /// The app's wait, or nil when the airport has none (outside the US). An available answer without a
    /// source cannot say what its figures are and fails the decode.
    public static func decode(_ data: Data) throws -> SecurityWait? {
        let a = try FlightJSON.decoder.decode(Answer.self, from: data)
        guard a.available else { return nil }
        guard let source = a.source else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "available answer with no source"))
        }
        return SecurityWait(
            airportIcao: a.airport, iata: a.iata, isLive: a.live,
            source: .init(id: source.id, name: source.name, url: source.url.flatMap(URL.init(string:))),
            fetchedAt: a.fetchedAt,
            checkpoints: a.checkpoints.map {
                SecurityCheckpoint(id: $0.id, name: $0.name, terminal: $0.terminal, precheck: $0.precheck,
                                   standardMinutes: $0.standardMinutes, precheckMinutes: $0.precheckMinutes)
            })
    }

    public func securityWait(airport: String) async throws(APIError) -> SecurityWait? {
        try await backend.call("security-wait", method: .get, query: [URLQueryItem(name: "airport", value: airport)],
                               decode: Self.decode)
    }
}
