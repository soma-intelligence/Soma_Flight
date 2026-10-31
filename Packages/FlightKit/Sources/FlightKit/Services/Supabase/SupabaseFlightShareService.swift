import Foundation
import Supabase

/// Live links from `share-flight`: POST makes one, GET says whether the user still shares the flight,
/// DELETE stops every link of theirs to it. The decoders are the exact paths the answers take, and the
/// contract tests run the backend's example files through them.
public final class SupabaseFlightShareService: FlightShareService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    struct Created: Decodable, Sendable { var url: String; var expiresAt: Date }
    struct Status: Decodable, Sendable { var active: Bool; var expiresAt: Date? }
    struct Stopped: Decodable, Sendable { var revoked: Int }

    /// The new link; an answer whose URL is not https fails the decode rather than reach the share sheet.
    static func decodeCreated(_ data: Data) throws -> FlightShareLink {
        let c = try FlightJSON.decoder.decode(Created.self, from: data)
        guard let url = URL(string: c.url), url.scheme == "https" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "share url is not https"))
        }
        return FlightShareLink(url: url, expiresAt: c.expiresAt)
    }

    /// When the live link closes, or nil when there is none.
    static func decodeStatus(_ data: Data) throws -> Date? {
        let s = try FlightJSON.decoder.decode(Status.self, from: data)
        return s.active ? s.expiresAt : nil
    }

    static func body(_ flight: Flight.ID) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["flight_id": flight.uuidString.lowercased()])) ?? Data()
    }

    private static func query(_ flight: Flight.ID) -> [URLQueryItem] {
        [URLQueryItem(name: "flight_id", value: flight.uuidString.lowercased())]
    }

    public func share(_ flight: Flight.ID) async throws(APIError) -> FlightShareLink {
        try await backend.call("share-flight", method: .post, body: Self.body(flight), decode: Self.decodeCreated)
    }

    public func activeShare(_ flight: Flight.ID) async throws(APIError) -> Date? {
        try await backend.call("share-flight", method: .get, query: Self.query(flight), decode: Self.decodeStatus)
    }

    public func stopSharing(_ flight: Flight.ID) async throws(APIError) {
        _ = try await backend.call("share-flight", method: .delete, query: Self.query(flight)) { data in
            try FlightJSON.decoder.decode(Stopped.self, from: data)
        }
    }
}
