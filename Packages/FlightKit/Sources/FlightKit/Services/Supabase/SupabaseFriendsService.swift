import Foundation
import Supabase

/// Friends over Supabase (migration 20261031000022): the reads and the user's own switches through database
/// functions and column-limited updates as the signed-in user, the invitations through the `friends` edge
/// function (rate limited, the only writer of invitations). The decoders are the exact paths the answers
/// take; the contract tests run the backend's example files through them.
public final class SupabaseFriendsService: FriendsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    // MARK: Decoding

    static func decodeMe(_ data: Data) throws -> FriendsMe {
        guard let me = try FlightJSON.decoder.decode([FriendsMe].self, from: data).first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "friends_me returned nothing"))
        }
        return me
    }

    static func decodeFriends(_ data: Data) throws -> [Friend] { try FlightJSON.decoder.decode([Friend].self, from: data) }
    static func decodeRequests(_ data: Data) throws -> [FriendRequest] {
        try FlightJSON.decoder.decode([FriendRequest].self, from: data)
    }
    static func decodeFlights(_ data: Data) throws -> [FriendFlight] {
        try FlightJSON.decoder.decode([FriendFlight].self, from: data)
    }
    static func decodePassport(_ data: Data) throws -> FriendPassport? {
        try FlightJSON.decoder.decode([FriendPassport].self, from: data).first
    }

    /// The invitation link; an answer whose URL is not https fails rather than reach the share sheet.
    static func decodeInvite(_ data: Data) throws -> FriendInvite {
        let i = try FlightJSON.decoder.decode(FriendInvite.self, from: data)
        guard i.url.scheme == "https" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invite url is not https"))
        }
        return i
    }

    static func decodePreview(_ data: Data) throws -> FriendInvitePreview {
        try FlightJSON.decoder.decode(FriendInvitePreview.self, from: data)
    }

    static func decodeAccepted(_ data: Data) throws -> Friend.ID? {
        struct A: Decodable { var friendId: UUID? }
        return try FlightJSON.decoder.decode(A.self, from: data).friendId
    }

    static func decodeRequested(_ data: Data) throws -> FriendCodeResult {
        struct A: Decodable { var result: FriendCodeResult }
        return try FlightJSON.decoder.decode(A.self, from: data).result
    }

    static func decodeCode(_ data: Data) throws -> String {
        struct A: Decodable { var code: String }
        return try FlightJSON.decoder.decode(A.self, from: data).code
    }

    /// The `friends` function's body for `action` and its fields.
    static func body(_ action: String, _ fields: [String: Any] = [:]) -> Data {
        var all = fields
        all["action"] = action
        return (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data()
    }

    // MARK: Calls

    private struct FriendParam: Encodable, Sendable {
        var p_friend: String?
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_friend, forKey: .p_friend)
        }
        enum CodingKeys: String, CodingKey { case p_friend }
    }

    private static func param(_ id: UUID?) -> FriendParam { FriendParam(p_friend: id?.uuidString.lowercased()) }

    private func rpc<T>(_ name: String, _ params: FriendParam? = nil,
                        decode: @Sendable (Data) throws -> T) async throws(APIError) -> T {
        let data: Data
        if let params {
            data = try await backend.write { try $0.rpc(name, params: params) }
        } else {
            data = try await backend.write { try $0.rpc(name) }
        }
        do { return try decode(data) } catch { throw SupabaseBackend.map(error) }
    }

    private func function<T: Sendable>(_ action: String, _ fields: [String: Any] = [:],
                                       decode: @escaping @Sendable (Data) throws -> T) async throws(APIError) -> T {
        try await backend.call("friends", method: .post, body: Self.body(action, fields), decode: decode)
    }

    private func userId() async throws(APIError) -> String {
        do { return try await backend.client.auth.session.user.id.uuidString.lowercased() } catch { throw .unauthorized }
    }

    public func me() async throws(APIError) -> FriendsMe { try await rpc("friends_me", decode: Self.decodeMe) }

    public func saveProfile(displayName: String?, emoji: String?) async throws(APIError) {
        struct Row: Encodable, Sendable {
            var display_name: String?
            var emoji: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(display_name, forKey: .display_name)
                try c.encode(emoji, forKey: .emoji)
            }
            enum CodingKeys: String, CodingKey { case display_name, emoji }
        }
        let user = try await userId()
        let row = Row(display_name: displayName, emoji: emoji)
        _ = try await backend.write { try $0.from("profiles").update(row).eq("user_id", value: user) }
    }

    public func setPaused(_ paused: Bool) async throws(APIError) {
        struct Row: Encodable, Sendable { var sharing_paused: Bool; var updated_at: String }
        // The row exists once friends_me has run; make sure of it first.
        _ = try await me()
        let user = try await userId()
        let row = Row(sharing_paused: paused, updated_at: ISO8601DateFormatter().string(from: .now))
        _ = try await backend.write { try $0.from("friend_settings").update(row).eq("user_id", value: user) }
    }

    public func friends() async throws(APIError) -> [Friend] { try await rpc("friends_list", decode: Self.decodeFriends) }

    public func requests() async throws(APIError) -> [FriendRequest] {
        try await rpc("friend_requests", decode: Self.decodeRequests)
    }

    public func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight] {
        try await rpc("friend_flights", Self.param(friend), decode: Self.decodeFlights)
    }

    public func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport? {
        try await rpc("friend_passport", Self.param(friend), decode: Self.decodePassport)
    }

    public func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError) {
        struct Row: Encodable, Sendable { var share_flights: Bool; var share_passport: Bool; var alerts: Bool }
        let user = try await userId()
        let row = Row(share_flights: settings.shareFlights, share_passport: settings.sharePassport, alerts: settings.alerts)
        let id = friend.uuidString.lowercased()
        _ = try await backend.write {
            try $0.from("friendships").update(row).eq("user_id", value: user).eq("friend_id", value: id)
        }
    }

    public func remove(_ friend: Friend.ID) async throws(APIError) {
        _ = try await rpc("friend_remove", Self.param(friend)) { _ in () }
    }

    public func invite() async throws(APIError) -> FriendInvite {
        try await function("invite", decode: Self.decodeInvite)
    }

    public func preview(token: String) async throws(APIError) -> FriendInvitePreview {
        try await function("preview", ["token": token], decode: Self.decodePreview)
    }

    public func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID? {
        try await function(accept ? "accept" : "decline", ["token": token], decode: Self.decodeAccepted)
    }

    public func request(code: String) async throws(APIError) -> FriendCodeResult {
        try await function("request", ["code": code], decode: Self.decodeRequested)
    }

    public func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError) {
        _ = try await function("respond", ["invitation_id": request.uuidString.lowercased(), "accept": accept]) { _ in () }
    }

    public func revoke(_ invitation: UUID) async throws(APIError) {
        _ = try await function("revoke", ["invitation_id": invitation.uuidString.lowercased()]) { _ in () }
    }

    public func resetCode() async throws(APIError) -> String {
        try await function("reset_code", decode: Self.decodeCode)
    }
}
