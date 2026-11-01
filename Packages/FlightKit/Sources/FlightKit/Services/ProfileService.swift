import Foundation

/// The user's own profile (names, photo, onboarding) and their friends' photos. Live builds use
/// `SupabaseProfileService` (the `profiles` row, the private `avatars` bucket and `friend_avatars`, migration
/// 20261031000030); screenshot runs (`-useFakes`) use `FakeProfileService`.
public protocol ProfileService: Sendable {
    /// What the sign-in provider says about the signed-in account (Apple's name, Google's name and picture,
    /// or only the email); nil when nobody is signed in.
    func identity() async -> AccountIdentity?
    func load() async throws(APIError) -> UserProfile
    /// Saves the names (and the name friends see, and the emoji); `onboarded` also stamps `onboarded_at`.
    func save(firstName: String?, lastName: String?, displayName: String?, emoji: String?,
              onboarded: Bool) async throws(APIError) -> UserProfile
    /// Uploads (or replaces) the photo, a JPEG from `AvatarImage`, and records its path.
    func uploadAvatar(_ jpeg: Data) async throws(APIError) -> UserProfile
    func removeAvatar() async throws(APIError) -> UserProfile
    /// The user's own photo; nil without one.
    func avatar() async throws(APIError) -> Data?
    /// Friends' photos: each friend with a photo, and when it last changed (a cache key).
    func friendAvatars() async throws(APIError) -> [FriendAvatarRef]
    /// The photos of `refs`, by friend.
    func friendAvatarData(_ refs: [FriendAvatarRef]) async throws(APIError) -> [UUID: Data]
    /// The provider's picture (Google), downloaded so onboarding can show it and upload it as the user's own.
    func providerPhoto(_ url: URL) async -> Data?
}

/// A friend's photo in the bucket.
public struct FriendAvatarRef: Sendable, Hashable, Decodable {
    public var friendId: UUID
    public var avatarPath: String
    public var updatedAt: Date

    public init(friendId: UUID, avatarPath: String, updatedAt: Date) {
        self.friendId = friendId; self.avatarPath = avatarPath; self.updatedAt = updatedAt
    }
}

/// No profile and no network call: the default for environments built without a service.
public struct UnavailableProfileService: ProfileService {
    public init() {}
    public func identity() async -> AccountIdentity? { nil }
    public func load() async throws(APIError) -> UserProfile { throw .providerUnavailable }
    public func save(firstName: String?, lastName: String?, displayName: String?, emoji: String?,
                     onboarded: Bool) async throws(APIError) -> UserProfile { throw .providerUnavailable }
    public func uploadAvatar(_ jpeg: Data) async throws(APIError) -> UserProfile { throw .providerUnavailable }
    public func removeAvatar() async throws(APIError) -> UserProfile { throw .providerUnavailable }
    public func avatar() async throws(APIError) -> Data? { nil }
    public func friendAvatars() async throws(APIError) -> [FriendAvatarRef] { [] }
    public func friendAvatarData(_ refs: [FriendAvatarRef]) async throws(APIError) -> [UUID: Data] { [:] }
    public func providerPhoto(_ url: URL) async -> Data? { nil }
}

/// Screenshot runs, previews and tests, nothing leaving the device. `Scenario` picks who signed in:
/// `.done` an account already onboarded (the default, so other screenshots are unchanged), `.apple` a first
/// Apple sign-in with Hide My Email and the name Apple gave, `.email` a magic-link account with nothing known,
/// `.google` a Google account with a name and a picture.
public actor FakeProfileService: ProfileService {
    public enum Scenario: String, Sendable, CaseIterable { case done, apple, email, google }

    public static let userId = UUID(uuidString: "5A1E0000-0000-4000-8000-000000000001")!

    public var nextError: APIError?
    public private(set) var profile: UserProfile
    private var photo: Data?
    private let account: AccountIdentity
    private let friendPhotos: [UUID: Data]

    public init(_ scenario: Scenario = .done, now: Date = .now) {
        switch scenario {
        case .done:
            account = AccountIdentity(provider: .apple, email: "k7q2m9xd4p@privaterelay.appleid.com")
            profile = UserProfile(userId: Self.userId, firstName: "Quentin", lastName: "Caron", displayName: "Quentin Caron",
                                  emoji: "✈️", onboardedAt: now.addingTimeInterval(-86_400))
        case .apple:
            account = AccountIdentity(provider: .apple, email: "k7q2m9xd4p@privaterelay.appleid.com",
                                      givenName: "Camille", familyName: "Laurent")
            profile = UserProfile(userId: Self.userId)
        case .email:
            account = AccountIdentity(provider: .email, email: "x83kq0@privaterelay.appleid.com")
            profile = UserProfile(userId: Self.userId)
        case .google:
            account = AccountIdentity(provider: .google, email: "noa.levi@gmail.com", fullName: "Noa Levi",
                                      givenName: "Noa", familyName: "Levi",
                                      avatarURL: URL(string: "https://example.invalid/fake-google-photo.jpg"))
            profile = UserProfile(userId: Self.userId)
        }
        photo = nil
        // Friends' photos: drawn tiles stand in for real ones (Maya has a photo; Theo keeps his initials).
        friendPhotos = [FakeFriendsService.maya: FakeProfilePhoto.jpeg(hue: 0.38)].compactMapValues { $0 }
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    public func identity() async -> AccountIdentity? { account }

    public func load() async throws(APIError) -> UserProfile { try check(); return profile }

    public func save(firstName: String?, lastName: String?, displayName: String?, emoji: String?,
                     onboarded: Bool) async throws(APIError) -> UserProfile {
        try check()
        profile.firstName = firstName; profile.lastName = lastName; profile.displayName = displayName; profile.emoji = emoji
        if onboarded, profile.onboardedAt == nil { profile.onboardedAt = .now }
        return profile
    }

    public func uploadAvatar(_ jpeg: Data) async throws(APIError) -> UserProfile {
        try check()
        photo = jpeg
        profile.avatarPath = UserProfile.avatarPath(for: profile.userId)
        return profile
    }

    public func removeAvatar() async throws(APIError) -> UserProfile {
        try check()
        photo = nil
        profile.avatarPath = nil
        return profile
    }

    public func avatar() async throws(APIError) -> Data? { try check(); return photo }

    public func friendAvatars() async throws(APIError) -> [FriendAvatarRef] {
        try check()
        return friendPhotos.keys.sorted { $0.uuidString < $1.uuidString }.map {
            FriendAvatarRef(friendId: $0, avatarPath: UserProfile.avatarPath(for: $0), updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    public func friendAvatarData(_ refs: [FriendAvatarRef]) async throws(APIError) -> [UUID: Data] {
        try check()
        return friendPhotos.filter { id, _ in refs.contains { $0.friendId == id } }
    }

    /// The fake Google picture: a drawn tile, never a download.
    public func providerPhoto(_ url: URL) async -> Data? { FakeProfilePhoto.jpeg(hue: 0.08) }
}
