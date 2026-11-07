import Foundation

/// The account's copy of its travel documents (`travel_vault`), sealed on the device before it leaves:
/// the server only ever holds ciphertext it cannot open. `profile` is the loyalty numbers and the
/// passport's country and expiry; `identity` the passport, Known Traveler and Redress numbers. Either
/// may be nil when it was never sent.
public struct TravelVaultCopy: Sendable, Equatable {
    public var profile: Data?
    public var identity: Data?
    public init(profile: Data?, identity: Data?) { self.profile = profile; self.identity = identity }
}

public protocol TravelVaultService: Sendable {
    /// The account's copy, nil when it has none. Throws `.unauthorized` when signed out.
    func load() async throws(APIError) -> TravelVaultCopy?
    /// Writes the parts given and keeps the other one as it is.
    func save(profile: Data?, identity: Data?) async throws(APIError)
    /// Removes the account's copy.
    func delete() async throws(APIError)
}

/// No account copy: travel documents stay in the Keychain (previews, the Mac before sign-in).
public struct UnavailableTravelVaultService: TravelVaultService {
    public init() {}
    public func load() async throws(APIError) -> TravelVaultCopy? { throw .unauthorized }
    public func save(profile: Data?, identity: Data?) async throws(APIError) { throw .unauthorized }
    public func delete() async throws(APIError) { throw .unauthorized }
}

/// In memory, for `-useFakes` and tests.
public actor FakeTravelVaultService: TravelVaultService {
    public private(set) var stored: TravelVaultCopy?
    public private(set) var saves = 0

    public init(_ stored: TravelVaultCopy? = nil) { self.stored = stored }

    public func load() async throws(APIError) -> TravelVaultCopy? { stored }

    public func save(profile: Data?, identity: Data?) async throws(APIError) {
        var copy = stored ?? TravelVaultCopy(profile: nil, identity: nil)
        if let profile { copy.profile = profile }
        if let identity { copy.identity = identity }
        stored = copy
        saves += 1
    }

    public func delete() async throws(APIError) { stored = nil }
}
