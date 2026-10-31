import Foundation

/// Friends: the user's friend code and profile, their friends and requests, friends' flights and Passport
/// totals, and the invitations. Live builds use `SupabaseFriendsService` (the `friends` edge function for
/// invitations, database functions for the rest, migration 20261031000022); screenshot runs (`-useFakes`) use
/// `FakeFriendsService`. Free: no paid provider behind any of it.
public protocol FriendsService: Sendable {
    /// The user's code, pause, name and emoji (the code is made on the first call).
    func me() async throws(APIError) -> FriendsMe
    /// Saves the name and emoji friends see (Settings > Account). Nil clears.
    func saveProfile(displayName: String?, emoji: String?) async throws(APIError)
    /// Pauses (or resumes) every share with every friend at once.
    func setPaused(_ paused: Bool) async throws(APIError)
    func friends() async throws(APIError) -> [Friend]
    func requests() async throws(APIError) -> [FriendRequest]
    /// Upcoming and in-air flights of one friend, or of every friend when nil.
    func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight]
    /// The friend's Passport totals; nil when they do not share them.
    func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport?
    func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError)
    /// Ends the friendship both ways.
    func remove(_ friend: Friend.ID) async throws(APIError)
    /// A new single-use invitation link.
    func invite() async throws(APIError) -> FriendInvite
    func preview(token: String) async throws(APIError) -> FriendInvitePreview
    /// Accepts or declines an invitation link; returns the new friend on acceptance.
    func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID?
    /// Sends a request to the owner of a friend code.
    func request(code: String) async throws(APIError) -> FriendCodeResult
    /// Accepts or declines a request made to the user.
    func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError)
    /// Withdraws a link or request the user made.
    func revoke(_ invitation: UUID) async throws(APIError)
    /// A new friend code; the old one stops working.
    func resetCode() async throws(APIError) -> String
}

/// No friends and no network call: the default for environments built without a service.
public struct UnavailableFriendsService: FriendsService {
    public init() {}
    public func me() async throws(APIError) -> FriendsMe { throw .providerUnavailable }
    public func saveProfile(displayName: String?, emoji: String?) async throws(APIError) { throw .providerUnavailable }
    public func setPaused(_ paused: Bool) async throws(APIError) { throw .providerUnavailable }
    public func friends() async throws(APIError) -> [Friend] { [] }
    public func requests() async throws(APIError) -> [FriendRequest] { [] }
    public func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight] { [] }
    public func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport? { nil }
    public func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError) { throw .providerUnavailable }
    public func remove(_ friend: Friend.ID) async throws(APIError) { throw .providerUnavailable }
    public func invite() async throws(APIError) -> FriendInvite { throw .providerUnavailable }
    public func preview(token: String) async throws(APIError) -> FriendInvitePreview { throw .providerUnavailable }
    public func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID? { throw .providerUnavailable }
    public func request(code: String) async throws(APIError) -> FriendCodeResult { throw .providerUnavailable }
    public func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError) { throw .providerUnavailable }
    public func revoke(_ invitation: UUID) async throws(APIError) { throw .providerUnavailable }
    public func resetCode() async throws(APIError) -> String { throw .providerUnavailable }
}

/// Two friends for screenshot runs, previews and tests, nothing leaving the device: Maya (an emoji, flying
/// now, shares her Passport) and Theo (initials, flying tomorrow), an incoming request from Sam, and an
/// invitation link that answers as Jun's. Their flights are the seed's, under new ids, so the globe can tell
/// them from the user's own.
public actor FakeFriendsService: FriendsService {
    public static let maya = UUID(uuidString: "F7E4D000-0000-4000-8000-00000000A0A1")!
    public static let theo = UUID(uuidString: "F7E4D000-0000-4000-8000-00000000A0A2")!
    public static let samRequest = UUID(uuidString: "F7E4D000-0000-4000-8000-00000000B0B1")!
    /// The token the fake invitation link carries (`somaflight://i/<token>` opens Jun's invitation).
    public static let junToken = "FakeInviteT0kenFakeInviteT0kenFakeInviteT0k"

    public var nextError: APIError?
    public private(set) var me: FriendsMe
    public private(set) var friendList: [Friend]
    public private(set) var pending: [FriendRequest]
    private var flightList: [FriendFlight]
    private var answered: Set<String> = []
    private var made = 0
    private let now: Date

    public init(now: Date = .now) {
        self.now = now
        let s = FakeSeed.shift(now: now)
        let seed = FakeSeed.flights("followed", shift: s)
        func copy(_ f: Flight, id: String, ident: String) -> Flight {
            var c = f
            c.id = UUID(uuidString: id)!
            c.providerId = "friend-\(ident)"
            c.ident = ident
            return c
        }
        // Maya: in the air now (the seed's flight with a position); Theo: the next one still to leave.
        let inAir = seed.first { $0.position != nil } ?? seed[0]
        let later = seed.first { $0.status == .scheduled && $0.id != inAir.id } ?? seed[min(1, seed.count - 1)]
        flightList = [
            FriendFlight(friendId: Self.maya, flight: copy(inAir, id: "F7E4D000-0000-4000-8000-00000000F001",
                                                           ident: inAir.ident == "AF84" ? "DL262" : "AF84")),
            FriendFlight(friendId: Self.theo, flight: copy(later, id: "F7E4D000-0000-4000-8000-00000000F002",
                                                           ident: later.ident == "BA287" ? "UA901" : "BA287")),
        ]
        friendList = [
            Friend(id: Self.maya, displayName: "Maya", emoji: "🌿", since: now.addingTimeInterval(-90 * 86_400),
                   settings: FriendSettings(shareFlights: true, sharePassport: true, alerts: true),
                   sharesFlights: true, sharesPassport: true),
            Friend(id: Self.theo, displayName: "Theo Martin", since: now.addingTimeInterval(-12 * 86_400)),
        ]
        pending = [FriendRequest(id: Self.samRequest, incoming: true, displayName: "Sam",
                                 createdAt: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(29 * 86_400))]
        me = FriendsMe(friendCode: "K7M2X9QP", displayName: "Quentin", emoji: "✈️")
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    private func check() throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
    }

    public func me() async throws(APIError) -> FriendsMe { try check(); return me }

    public func saveProfile(displayName: String?, emoji: String?) async throws(APIError) {
        try check()
        me.displayName = displayName; me.emoji = emoji
    }

    public func setPaused(_ paused: Bool) async throws(APIError) { try check(); me.sharingPaused = paused }

    public func friends() async throws(APIError) -> [Friend] { try check(); return friendList }

    public func requests() async throws(APIError) -> [FriendRequest] { try check(); return pending }

    public func flights(of friend: Friend.ID?) async throws(APIError) -> [FriendFlight] {
        try check()
        let shared = Set(friendList.filter(\.sharesFlights).map(\.id))
        return flightList.filter { shared.contains($0.friendId) && (friend == nil || $0.friendId == friend) }
    }

    public func passport(of friend: Friend.ID) async throws(APIError) -> FriendPassport? {
        try check()
        guard friendList.first(where: { $0.id == friend })?.sharesPassport == true else { return nil }
        return FriendPassport(flights: 64, distanceKm: 312_400, airMinutes: 24_900, airports: 41, countries: 17, airlines: 19)
    }

    public func update(_ friend: Friend.ID, settings: FriendSettings) async throws(APIError) {
        try check()
        guard let i = friendList.firstIndex(where: { $0.id == friend }) else { throw .notFound }
        friendList[i].settings = settings
    }

    public func remove(_ friend: Friend.ID) async throws(APIError) {
        try check()
        friendList.removeAll { $0.id == friend }
        flightList.removeAll { $0.friendId == friend }
    }

    public func invite() async throws(APIError) -> FriendInvite {
        try check()
        made += 1
        let token = String(format: "FakeInvite%033d", made)
        return FriendInvite(id: UUID(), url: URL(string: "https://somalabs.me/i/\(token)")!,
                            expiresAt: now.addingTimeInterval(7 * 86_400))
    }

    public func preview(token: String) async throws(APIError) -> FriendInvitePreview {
        try check()
        if answered.contains(token) { return FriendInvitePreview(state: .used, displayName: "Jun") }
        return FriendInvitePreview(state: .open, displayName: "Jun", emoji: "🌊")
    }

    public func respond(token: String, accept: Bool) async throws(APIError) -> Friend.ID? {
        try check()
        guard !answered.contains(token) else { throw .outOfWindow }
        answered.insert(token)
        guard accept else { return nil }
        let id = UUID()
        friendList.append(Friend(id: id, displayName: "Jun", emoji: "🌊", since: now))
        return id
    }

    public func request(code: String) async throws(APIError) -> FriendCodeResult {
        try check()
        guard FriendLink.code(code) != nil else { throw .notFound }
        pending.append(FriendRequest(id: UUID(), incoming: false, createdAt: now, expiresAt: now.addingTimeInterval(30 * 86_400)))
        return .sent
    }

    public func respond(request: FriendRequest.ID, accept: Bool) async throws(APIError) {
        try check()
        guard let r = pending.first(where: { $0.id == request && $0.incoming }) else { throw .notFound }
        pending.removeAll { $0.id == request }
        if accept { friendList.append(Friend(id: UUID(), displayName: r.displayName, emoji: r.emoji, since: now)) }
    }

    public func revoke(_ invitation: UUID) async throws(APIError) {
        try check()
        pending.removeAll { $0.id == invitation && !$0.incoming }
    }

    public func resetCode() async throws(APIError) -> String {
        try check()
        me.friendCode = me.friendCode == "K7M2X9QP" ? "R4TW8H2C" : "K7M2X9QP"
        return me.friendCode
    }
}
