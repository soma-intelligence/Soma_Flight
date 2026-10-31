import Foundation

/// A mutual friend (migration 20261031000022, `friends_list`): who they are to the user, what the user shares
/// with them and what they share back. Made only by an invitation link or a friend code, never from contacts.
public struct Friend: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The name they chose in Settings > Account; nil until they set one.
    public var displayName: String?
    /// The emoji they chose to show instead of their initials.
    public var emoji: String?
    public var since: Date
    /// The user's switches about this friend: their own upcoming flights go to the friend (on by default),
    /// their Passport totals (off by default), pushes for the friend's flights (off by default).
    public var settings: FriendSettings
    /// What the friend shares with the user now: their switch, unless they paused all sharing.
    public var sharesFlights: Bool
    public var sharesPassport: Bool

    public init(id: UUID, displayName: String?, emoji: String? = nil, since: Date,
                settings: FriendSettings = FriendSettings(), sharesFlights: Bool = true, sharesPassport: Bool = false) {
        self.id = id; self.displayName = displayName; self.emoji = emoji; self.since = since
        self.settings = settings; self.sharesFlights = sharesFlights; self.sharesPassport = sharesPassport
    }

    /// The name shown everywhere; "Friend" until they pick one.
    public var name: String {
        let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Friend" : n
    }

    /// Up to two initials of the name ("Maya Lin" -> "ML"), "?" without a name.
    public var initials: String { FriendAvatarText.initials(displayName) }

    // The `friends_list` row, after .convertFromSnakeCase.
    private enum CodingKeys: String, CodingKey {
        case friendId, displayName, emoji, since, shareFlights, sharePassport, alerts, sharesFlights, sharesPassport
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .friendId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        since = try c.decode(Date.self, forKey: .since)
        settings = FriendSettings(shareFlights: try c.decode(Bool.self, forKey: .shareFlights),
                                  sharePassport: try c.decode(Bool.self, forKey: .sharePassport),
                                  alerts: try c.decode(Bool.self, forKey: .alerts))
        sharesFlights = try c.decode(Bool.self, forKey: .sharesFlights)
        sharesPassport = try c.decode(Bool.self, forKey: .sharesPassport)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .friendId)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encode(since, forKey: .since)
        try c.encode(settings.shareFlights, forKey: .shareFlights)
        try c.encode(settings.sharePassport, forKey: .sharePassport)
        try c.encode(settings.alerts, forKey: .alerts)
        try c.encode(sharesFlights, forKey: .sharesFlights)
        try c.encode(sharesPassport, forKey: .sharesPassport)
    }
}

/// The user's three switches about one friend (their row of `friendships`).
public struct FriendSettings: Codable, Sendable, Hashable {
    /// The user's upcoming flights go to this friend.
    public var shareFlights: Bool
    /// The user's Passport totals go to this friend.
    public var sharePassport: Bool
    /// The user gets a push when this friend's flight takes off, lands or runs late (Delays and Take-off).
    public var alerts: Bool

    public init(shareFlights: Bool = true, sharePassport: Bool = false, alerts: Bool = false) {
        self.shareFlights = shareFlights; self.sharePassport = sharePassport; self.alerts = alerts
    }
}

/// Initials for an avatar.
public enum FriendAvatarText {
    public static func initials(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let s = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return s.isEmpty ? "?" : s
    }

    /// Which of `count` soft colours a friend's avatar takes: the same for a friend on every launch and
    /// device (it reads the id's bytes, never a per-run hash), 0 without an id.
    public static func tone(_ id: UUID?, count: Int) -> Int {
        guard let id, count > 0 else { return 0 }
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % count
    }
}

/// One of a friend's upcoming or in-air flights (`friend_flights`): flight data only, never their seat,
/// booking code, notes or boarding pass.
public struct FriendFlight: Sendable, Hashable, Identifiable {
    public var friendId: UUID
    public var flight: Flight

    public init(friendId: UUID, flight: Flight) { self.friendId = friendId; self.flight = flight }

    /// One flight may be followed by two friends: the pair is the identity.
    public var id: String { "\(friendId.uuidString)-\(flight.id.uuidString)" }
}

extension FriendFlight: Decodable {
    private enum Keys: String, CodingKey { case friendId }

    /// The `friend_flights` row: the friend's id beside the flight's own columns.
    public init(from decoder: any Decoder) throws {
        friendId = try decoder.container(keyedBy: Keys.self).decode(UUID.self, forKey: .friendId)
        flight = try Flight(from: decoder)
    }
}

/// A friend's Passport totals (`friend_passport`), when they share them: no flight, date or place.
public struct FriendPassport: Codable, Sendable, Hashable {
    public var flights: Int
    public var distanceKm: Int
    public var airMinutes: Int
    public var airports: Int
    public var countries: Int
    public var airlines: Int

    public init(flights: Int, distanceKm: Int, airMinutes: Int, airports: Int, countries: Int, airlines: Int) {
        self.flights = flights; self.distanceKm = distanceKm; self.airMinutes = airMinutes
        self.airports = airports; self.countries = countries; self.airlines = airlines
    }
}

/// The user's own friend profile (`friends_me`): the code they hand out, the pause, the name and emoji.
public struct FriendsMe: Codable, Sendable, Hashable {
    public var friendCode: String
    public var sharingPaused: Bool
    public var displayName: String?
    public var emoji: String?

    public init(friendCode: String, sharingPaused: Bool = false, displayName: String? = nil, emoji: String? = nil) {
        self.friendCode = friendCode; self.sharingPaused = sharingPaused
        self.displayName = displayName; self.emoji = emoji
    }

    /// "K7M2 X9QP": the code in two groups, easier to read aloud.
    public var spacedCode: String {
        friendCode.count == 8 ? "\(friendCode.prefix(4)) \(friendCode.suffix(4))" : friendCode
    }
}

/// A pending friend request made with a code (`friend_requests`). An incoming one names who sent it; an
/// outgoing one does not (a code never tells whose it is).
public struct FriendRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var incoming: Bool
    public var displayName: String?
    public var emoji: String?
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: UUID, incoming: Bool, displayName: String? = nil, emoji: String? = nil,
                createdAt: Date, expiresAt: Date) {
        self.id = id; self.incoming = incoming; self.displayName = displayName; self.emoji = emoji
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

/// A new invitation link: `https://somalabs.me/i/<token>`, single use, open until `expiresAt`.
public struct FriendInvite: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: URL
    public var expiresAt: Date

    public init(id: UUID, url: URL, expiresAt: Date) { self.id = id; self.url = url; self.expiresAt = expiresAt }
}

/// What an opened invitation link says before it is answered.
public struct FriendInvitePreview: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case open, expired, used, `self`, friends }
    public var state: State
    public var displayName: String?
    public var emoji: String?

    public init(state: State, displayName: String? = nil, emoji: String? = nil) {
        self.state = state; self.displayName = displayName; self.emoji = emoji
    }

    public var name: String {
        let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Someone" : n
    }
}

/// What typing a friend code did.
public enum FriendCodeResult: String, Codable, Sendable {
    /// A request went to the code's owner.
    case sent
    /// They had asked the user already: now friends.
    case accepted
    /// Already friends.
    case friends
}

/// An invitation the app was opened with, waiting for the user's answer (`HomeModel.pendingInvite`).
public struct PendingFriendInvite: Sendable, Equatable, Identifiable {
    public var token: String
    public var preview: FriendInvitePreview?
    public var error: APIError?

    public init(token: String, preview: FriendInvitePreview? = nil, error: APIError? = nil) {
        self.token = token; self.preview = preview; self.error = error
    }

    public var id: String { token }
}

/// Invitation links the app opens: `https://somalabs.me/i/<token>` (a universal link once the site serves
/// it) and `somaflight://i/<token>`.
public enum FriendLink {
    /// 43 characters of base64url, as the server makes them.
    static func isToken(_ s: String) -> Bool {
        s.count == 43 && s.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The token of an invitation link; nil for any other URL.
    public static func token(from url: URL) -> String? {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "somaflight":
            parts = ([url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        case "https":
            guard let host = url.host()?.lowercased(), host == "somalabs.me" || host == "www.somalabs.me" else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard parts.count == 2, parts[0] == "i", isToken(parts[1]) else { return nil }
        return parts[1]
    }

    /// A friend code as typed ("k7m2-x9qp") in its stored form, or nil when it cannot be one.
    public static func code(_ raw: String) -> String? {
        let c = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return c.count == 8 && c.allSatisfy(alphabet.contains) ? c : nil
    }
}
