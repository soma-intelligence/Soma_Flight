import Foundation
import Supabase

/// The profile over Supabase (migration 20261031000030): the user's `profiles` row through column-limited
/// updates, the photo in the private `avatars` bucket at `<user_id>/avatar.jpg` (owner writes; owner and
/// friends read through short signed URLs), friends' photos listed by `friend_avatars`.
public final class SupabaseProfileService: ProfileService {
    static let bucket = "avatars"
    /// Signed URLs live a few minutes: long enough to download, short enough to be useless if they leak.
    static let signedURLSeconds = 300

    private let backend: SupabaseBackend
    private let session: URLSession

    public init(backend: SupabaseBackend, session: URLSession = .shared) {
        self.backend = backend; self.session = session
    }

    private var auth: AuthClient { backend.client.auth }

    private func userId() async throws(APIError) -> UUID {
        do { return try await auth.session.user.id } catch { throw .unauthorized }
    }

    // MARK: Decoding

    static let columns = "user_id,first_name,last_name,display_name,emoji,avatar_path,onboarded_at"

    static func decodeProfile(_ data: Data) throws -> UserProfile {
        guard let p = try FlightJSON.decoder.decode([UserProfile].self, from: data).first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no profile row"))
        }
        return p
    }

    static func decodeFriendAvatars(_ data: Data) throws -> [FriendAvatarRef] {
        try FlightJSON.decoder.decode([FriendAvatarRef].self, from: data)
    }

    /// `user_metadata` flattened to its string values (Apple and Google only put strings in the keys we read).
    static func strings(_ metadata: [String: AnyJSON]) -> [String: String] {
        metadata.compactMapValues { $0.stringValue }
    }

    // MARK: Calls

    public func identity() async -> AccountIdentity? {
        guard let user = try? await auth.session.user else { return nil }
        let provider = AuthProvider(supabase: user.appMetadata["provider"]?.stringValue)
        return AccountIdentity.from(metadata: Self.strings(user.userMetadata), provider: provider, email: user.email)
    }

    public func load() async throws(APIError) -> UserProfile {
        let id = try await userId().uuidString.lowercased()
        let data = try await backend.rows { $0.from("profiles").select(Self.columns).eq("user_id", value: id).limit(1) }
        do { return try Self.decodeProfile(data) } catch { throw SupabaseBackend.map(error) }
    }

    private struct NamesRow: Encodable, Sendable {
        var first_name: String?
        var last_name: String?
        var display_name: String?
        var emoji: String?
        var onboarded_at: String?
        var stamp: Bool
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // Nil clears a name: encode it as null rather than leaving it out.
            try c.encode(first_name, forKey: .first_name)
            try c.encode(last_name, forKey: .last_name)
            try c.encode(display_name, forKey: .display_name)
            try c.encode(emoji, forKey: .emoji)
            if stamp { try c.encode(onboarded_at, forKey: .onboarded_at) }
        }
        enum CodingKeys: String, CodingKey { case first_name, last_name, display_name, emoji, onboarded_at }
    }

    public func save(firstName: String?, lastName: String?, displayName: String?, emoji: String?,
                     onboarded: Bool) async throws(APIError) -> UserProfile {
        let id = try await userId().uuidString.lowercased()
        let row = NamesRow(first_name: firstName, last_name: lastName, display_name: displayName, emoji: emoji,
                           onboarded_at: ISO8601DateFormatter().string(from: .now), stamp: onboarded)
        let data = try await backend.write {
            try $0.from("profiles").update(row).eq("user_id", value: id).select(Self.columns)
        }
        do { return try Self.decodeProfile(data) } catch { throw SupabaseBackend.map(error) }
    }

    private struct PathRow: Encodable, Sendable {
        var avatar_path: String?
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(avatar_path, forKey: .avatar_path)
        }
        enum CodingKeys: String, CodingKey { case avatar_path }
    }

    private func setPath(_ path: String?, user: UUID) async throws(APIError) -> UserProfile {
        let id = user.uuidString.lowercased()
        let data = try await backend.write {
            try $0.from("profiles").update(PathRow(avatar_path: path)).eq("user_id", value: id).select(Self.columns)
        }
        do { return try Self.decodeProfile(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func uploadAvatar(_ jpeg: Data) async throws(APIError) -> UserProfile {
        let user = try await userId()
        let path = UserProfile.avatarPath(for: user)
        do {
            try await backend.client.storage.from(Self.bucket).upload(
                path, data: jpeg, options: FileOptions(cacheControl: "60", contentType: "image/jpeg", upsert: true))
        } catch { throw SupabaseBackend.map(error) }
        return try await setPath(path, user: user)
    }

    public func removeAvatar() async throws(APIError) -> UserProfile {
        let user = try await userId()
        // The path goes first: a file left behind is never shown and is replaced or erased later.
        let profile = try await setPath(nil, user: user)
        _ = try? await backend.client.storage.from(Self.bucket).remove(paths: [UserProfile.avatarPath(for: user)])
        return profile
    }

    public func avatar() async throws(APIError) -> Data? {
        let user = try await userId()
        do {
            return try await backend.client.storage.from(Self.bucket).download(path: UserProfile.avatarPath(for: user))
        } catch let e as StorageError where e.statusCode == "404" || e.statusCode == "400" {
            return nil
        } catch { throw SupabaseBackend.map(error) }
    }

    public func friendAvatars() async throws(APIError) -> [FriendAvatarRef] {
        let data = try await backend.write { try $0.rpc("friend_avatars") }
        do { return try Self.decodeFriendAvatars(data) } catch { throw SupabaseBackend.map(error) }
    }

    /// Signs the paths in one call, then downloads each; a photo that fails is left out (initials show).
    public func friendAvatarData(_ refs: [FriendAvatarRef]) async throws(APIError) -> [UUID: Data] {
        guard !refs.isEmpty else { return [:] }
        let byPath = Dictionary(refs.map { ($0.avatarPath, $0.friendId) }, uniquingKeysWith: { a, _ in a })
        let signed: [SignedURLResult]
        do {
            signed = try await backend.client.storage.from(Self.bucket)
                .createSignedURLs(paths: Array(byPath.keys), expiresIn: Self.signedURLSeconds)
        } catch { throw SupabaseBackend.map(error) }
        var out: [UUID: Data] = [:]
        for result in signed {
            guard case .success(let path, let url) = result, let id = byPath[path],
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            out[id] = data
        }
        return out
    }

    /// Downloads the provider's picture once (https only, 5 MB at most).
    public func providerPhoto(_ url: URL) async -> Data? {
        guard url.scheme == "https", let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { return nil }
        return data
    }
}
