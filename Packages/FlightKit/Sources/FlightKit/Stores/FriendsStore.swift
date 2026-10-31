import Foundation
import Observation

/// The Friends tab's state for the signed-in user: their friends, pending requests, every friend's upcoming
/// and in-air flights, the user's own code and pause, and the invitations. A switch shows at once and saves
/// in the background; a failed save puts it back and shows the error. Rebuilt on every account change.
@MainActor @Observable
public final class FriendsStore {
    public private(set) var friends: [Friend] = []
    public private(set) var requests: [FriendRequest] = []
    /// Every friend's shared flights, the earliest departure first.
    public private(set) var flights: [FriendFlight] = []
    /// The user's own code, pause, name and emoji; nil until loaded.
    public private(set) var me: FriendsMe?
    /// Friends' Passport totals, loaded when their page opens.
    public private(set) var passports: [Friend.ID: FriendPassport] = [:]
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: APIError?
    /// The last invitation link made, for the share sheet.
    public private(set) var invite: FriendInvite?
    /// The list's filter: everyone, or only friends flying within the next 24 hours.
    public var filter: Filter = .all

    public enum Filter: String, Hashable, Sendable, CaseIterable {
        case all, soon
        public var title: String {
            switch self {
            case .all: "All Friends"
            case .soon: "Flying Soon"
            }
        }
    }

    private let service: any FriendsService
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingInvite: Task<FriendInvite?, Never>?

    public init(service: any FriendsService) { self.service = service }

    // MARK: Loading

    /// Loads everything the tab shows. A failure keeps what was there and sets `error`.
    public func load() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        let service = service
        async let f = service.friends()
        async let r = service.requests()
        async let fl = service.flights(of: nil)
        async let m = service.me()
        do {
            let (friends, requests, flights) = try await (f, r, fl)
            let me = try? await m
            guard gen == generation else { return }
            self.friends = friends
            self.requests = requests
            self.flights = Self.sorted(flights)
            if let me { self.me = me }
            error = nil
        } catch {
            _ = try? await m
            guard gen == generation else { return }
            self.error = error as? APIError ?? .providerUnavailable
        }
        hasLoaded = true
    }

    /// Loads the friend's Passport totals when they share them (their page).
    public func loadPassport(of friend: Friend.ID) async {
        guard let f = self.friend(friend), f.sharesPassport else { passports[friend] = nil; return }
        if let p = try? await service.passport(of: friend) { passports[friend] = p } else { passports[friend] = nil }
    }

    static func sorted(_ flights: [FriendFlight]) -> [FriendFlight] {
        flights.sorted { a, b in
            let ta = DetailFacts.bestOut(a.flight) ?? .distantFuture, tb = DetailFacts.bestOut(b.flight) ?? .distantFuture
            return ta == tb ? a.id < b.id : ta < tb
        }
    }

    // MARK: Reading

    public func friend(_ id: Friend.ID) -> Friend? { friends.first { $0.id == id } }

    /// The friend's shared flights, the earliest first.
    public func flights(of friend: Friend.ID) -> [FriendFlight] { flights.filter { $0.friendId == friend } }

    /// The flight a friend's row shows: the one in the air, else the next to leave.
    public func nextFlight(of friend: Friend.ID) -> Flight? {
        let mine = flights(of: friend).map(\.flight)
        return mine.first { $0.status == .departed || $0.status == .enRoute } ?? mine.first
    }

    /// True when the flight is in the air or leaves within 24 hours of `now`.
    public nonisolated static func isSoon(_ f: Flight, now: Date) -> Bool {
        if f.status == .departed || f.status == .enRoute { return true }
        guard f.status == .scheduled || f.status == .unknown, let out = DetailFacts.bestOut(f) else { return false }
        return out.timeIntervalSince(now) <= 86_400 && out.timeIntervalSince(now) > -3 * 3600
    }

    /// The friends the list shows under the filter.
    public func visibleFriends(now: Date = .now) -> [Friend] {
        switch filter {
        case .all: friends
        case .soon: friends.filter { id in flights(of: id.id).contains { Self.isSoon($0.flight, now: now) } }
        }
    }

    /// The flight a friend's row on the tab shows: the one in the air, else the next that has not landed
    /// (a canceled or diverted one stays, it is news); nil when nothing is coming up.
    public func upcomingFlight(of friend: Friend.ID) -> Flight? {
        let mine = flights(of: friend).map(\.flight)
        return mine.first { $0.status == .departed || $0.status == .enRoute }
            ?? mine.first { $0.status != .landed && $0.status != .arrived }
    }

    /// Where a friend's row sits on the tab.
    public enum Section: String, Hashable, Sendable, CaseIterable {
        case inTheAir, upcoming, noFlights

        public var title: String {
            switch self {
            case .inTheAir: "In the Air"
            case .upcoming: "Upcoming"
            case .noFlights: "No Upcoming Flights"
            }
        }
    }

    /// The tab's list: friends in the air (landing soonest first), then those with a flight coming up
    /// (leaving soonest first), then everyone else by name. Empty sections are left out.
    public func sections() -> [(section: Section, friends: [Friend])] {
        var air: [(Friend, Date)] = [], soon: [(Friend, Date)] = [], rest: [Friend] = []
        for friend in friends {
            guard let f = upcomingFlight(of: friend.id) else { rest.append(friend); continue }
            if f.status == .departed || f.status == .enRoute {
                air.append((friend, DetailFacts.bestIn(f) ?? .distantFuture))
            } else {
                soon.append((friend, DetailFacts.bestOut(f) ?? .distantFuture))
            }
        }
        func byTime(_ list: [(Friend, Date)]) -> [Friend] {
            list.sorted { $0.1 == $1.1 ? Self.byName($0.0, $1.0) : $0.1 < $1.1 }.map(\.0)
        }
        let all: [(Section, [Friend])] = [(.inTheAir, byTime(air)), (.upcoming, byTime(soon)),
                                          (.noFlights, rest.sorted(by: Self.byName))]
        return all.filter { !$0.1.isEmpty }.map { (section: $0.0, friends: $0.1) }
    }

    private nonisolated static func byName(_ a: Friend, _ b: Friend) -> Bool {
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
    }

    /// The friend who follows a flight shown on the globe.
    public func friendFlight(_ id: Flight.ID) -> FriendFlight? { flights.first { $0.flight.id == id } }

    public var incoming: [FriendRequest] { requests.filter(\.incoming) }
    public var outgoing: [FriendRequest] { requests.filter { !$0.incoming } }

    // MARK: Switches

    /// Saves one friend's switches; the list shows the change at once and goes back on failure.
    public func update(_ friend: Friend.ID, _ change: (inout FriendSettings) -> Void) async {
        guard let i = friends.firstIndex(where: { $0.id == friend }) else { return }
        let before = friends[i].settings
        var next = before
        change(&next)
        guard next != before else { return }
        friends[i].settings = next
        do {
            try await service.update(friend, settings: next)
            error = nil
        } catch {
            if let j = friends.firstIndex(where: { $0.id == friend }) { friends[j].settings = before }
            self.error = error
        }
    }

    /// Pauses or resumes every share at once.
    public func setPaused(_ paused: Bool) async {
        guard var m = me, m.sharingPaused != paused else { return }
        let before = m
        m.sharingPaused = paused
        me = m
        do { try await service.setPaused(paused); error = nil } catch { me = before; self.error = error }
    }

    /// Saves the name and emoji friends see. Blank values clear. Returns false when it failed.
    @discardableResult
    public func saveProfile(displayName: String?, emoji: String?) async -> Bool {
        let name = Self.clean(displayName, max: 40)
        let mark = Self.cleanEmoji(emoji)
        do {
            try await service.saveProfile(displayName: name, emoji: mark)
            if me != nil { me?.displayName = name; me?.emoji = mark }
            error = nil
            return true
        } catch {
            self.error = error
            return false
        }
    }

    nonisolated static func clean(_ s: String?, max: Int) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(max))
    }

    /// The first character of an emoji field, kept only when it is an emoji.
    nonisolated static func cleanEmoji(_ s: String?) -> String? {
        guard let c = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).first,
              c.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF })
        else { return nil }
        return String(c)
    }

    // MARK: Friends and invitations

    public func remove(_ friend: Friend.ID) async {
        do {
            try await service.remove(friend)
            friends.removeAll { $0.id == friend }
            flights.removeAll { $0.friendId == friend }
            passports[friend] = nil
            error = nil
        } catch {
            self.error = error
        }
    }

    /// A new invitation link (the share sheet hands it over); nil and `error` on failure.
    public func makeInvite() async -> FriendInvite? {
        do {
            let i = try await service.invite()
            invite = i
            error = nil
            return i
        } catch {
            self.error = error
            return nil
        }
    }

    /// The invitation link for a share or a QR code: a new single-use link each time, made only when it is
    /// asked for. Calls that arrive while one is being made (a share sheet asking twice) get the same link.
    public func shareInviteURL() async throws(APIError) -> URL {
        let task: Task<FriendInvite?, Never>
        if let pendingInvite { task = pendingInvite } else {
            task = Task { await self.makeInvite() }
            pendingInvite = task
        }
        let made = await task.value
        if pendingInvite == task { pendingInvite = nil }
        guard let made else { throw error ?? .providerUnavailable }
        return made.url
    }

    /// Sends a request to a code's owner. Throws so the sheet can say what happened under the field.
    public func request(code raw: String) async throws(APIError) -> FriendCodeResult {
        guard let code = FriendLink.code(raw) else { throw .notFound }
        let result = try await service.request(code: code)
        await load()
        return result
    }

    public func respond(to request: FriendRequest, accept: Bool) async {
        do {
            try await service.respond(request: request.id, accept: accept)
            requests.removeAll { $0.id == request.id }
            if accept { await load() }
        } catch {
            self.error = error
        }
    }

    public func cancel(_ request: FriendRequest) async {
        do {
            try await service.revoke(request.id)
            requests.removeAll { $0.id == request.id }
        } catch {
            self.error = error
        }
    }

    public func resetCode() async {
        do {
            let c = try await service.resetCode()
            me?.friendCode = c
            error = nil
        } catch {
            self.error = error
        }
    }

    /// What an opened invitation link says.
    public func preview(token: String) async -> PendingFriendInvite {
        do { return PendingFriendInvite(token: token, preview: try await service.preview(token: token)) } catch {
            return PendingFriendInvite(token: token, error: error)
        }
    }

    /// Answers an invitation link; reloads on acceptance. Returns the error, nil on success.
    public func respond(token: String, accept: Bool) async -> APIError? {
        do {
            _ = try await service.respond(token: token, accept: accept)
            if accept { await load() }
            return nil
        } catch {
            return error
        }
    }

    public func clearError() { error = nil }

    #if DEBUG
    /// Previews and tests: a state without a load.
    func seed(friends: [Friend], flights: [FriendFlight], requests: [FriendRequest] = [], me: FriendsMe? = nil) {
        self.friends = friends; self.flights = Self.sorted(flights); self.requests = requests; self.me = me
        hasLoaded = true
    }
    #endif
}
