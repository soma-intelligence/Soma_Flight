import Foundation
import Supabase

/// `travel_vault` through PostgREST: one row per account, RLS keeps it to its owner. The two parts are
/// AES-GCM boxes sealed on the device (base64), written by an upsert on `user_id` that leaves out the
/// part not given, so saving the loyalty numbers never clears the sealed passport number.
public final class SupabaseTravelVaultService: TravelVaultService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    struct Row: Codable {
        var profile: String?
        var identity: String?
    }

    /// The row as written: only the parts given, so the other column keeps its value.
    struct Upsert: Encodable {
        var user_id: String
        var profile: String?
        var identity: String?
        var updated_at: String

        enum CodingKeys: String, CodingKey { case user_id, profile, identity, updated_at }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(user_id, forKey: .user_id)
            try c.encodeIfPresent(profile, forKey: .profile)
            try c.encodeIfPresent(identity, forKey: .identity)
            try c.encode(updated_at, forKey: .updated_at)
        }
    }

    static func decode(_ data: Data) throws -> TravelVaultCopy? {
        guard let row = try JSONDecoder().decode([Row].self, from: data).first else { return nil }
        return TravelVaultCopy(profile: row.profile.flatMap { Data(base64Encoded: $0) },
                               identity: row.identity.flatMap { Data(base64Encoded: $0) })
    }

    private func user() async throws(APIError) -> UUID {
        do { return try await backend.client.auth.session.user.id } catch { throw .unauthorized }
    }

    public func load() async throws(APIError) -> TravelVaultCopy? {
        _ = try await user()
        let data = try await backend.rows { $0.from("travel_vault").select("profile, identity").limit(1) }
        do { return try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func save(profile: Data?, identity: Data?) async throws(APIError) {
        let user = try await user()
        let row = Upsert(user_id: user.uuidString.lowercased(), profile: profile?.base64EncodedString(),
                         identity: identity?.base64EncodedString(),
                         updated_at: ISO8601DateFormatter().string(from: .now))
        _ = try await backend.write { try $0.from("travel_vault").upsert(row, onConflict: "user_id") }
    }

    public func delete() async throws(APIError) {
        let user = try await user()
        _ = try await backend.rows {
            $0.from("travel_vault").delete().eq("user_id", value: user.uuidString.lowercased()).select("user_id")
        }
    }
}
