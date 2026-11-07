import Foundation
import Supabase

/// `favorite_airports` through PostgREST. RLS keeps the rows to their owner; the table holds one row per
/// followed airport, capped at 50 per account by the database.
public final class SupabaseFavoriteAirportAlertsService: FavoriteAirportAlertsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    struct Row: Codable, Sendable { var airportIcao: String }

    /// The codes in a select's answer.
    static func decode(_ data: Data) throws -> Set<String> {
        Set(try FlightJSON.decoder.decode([Row].self, from: data).map(\.airportIcao))
    }

    /// The row as PostgREST takes it.
    struct Insert: Encodable {
        var user_id: String
        var airport_icao: String
    }

    public func followed() async throws(APIError) -> Set<String> {
        let data = try await backend.rows { $0.from("favorite_airports").select("airport_icao") }
        do { return try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func set(_ icao: String, following: Bool) async throws(APIError) {
        let code = icao.uppercased()
        if following {
            let user: UUID
            do { user = try await backend.client.auth.session.user.id } catch { throw .unauthorized }
            let row = Insert(user_id: user.uuidString.lowercased(), airport_icao: code)
            _ = try await backend.write {
                try $0.from("favorite_airports").upsert(row, onConflict: "user_id,airport_icao", ignoreDuplicates: true)
            }
        } else {
            _ = try await backend.rows { $0.from("favorite_airports").delete().eq("airport_icao", value: code) }
        }
    }
}
