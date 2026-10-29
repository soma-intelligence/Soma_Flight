import Foundation

/// The services, cache and airport list one app run works with. The iOS and macOS shells build one
/// at launch and make every store from it.
public struct AppEnvironment: Sendable {
    public var flights: any FlightService
    public var airports: any AirportService
    public var auth: any AuthService
    public var history: any HistoryService
    public var push: any PushService
    public var cache: CacheStore
    public var directory: AirportDirectory
    /// Where recent searches persist.
    public var recents: RecentsStorage

    public init(flights: any FlightService, airports: any AirportService, auth: any AuthService,
                history: any HistoryService, push: any PushService, cache: CacheStore,
                directory: AirportDirectory = .bundled(), recents: RecentsStorage = .memory) {
        self.flights = flights; self.airports = airports; self.auth = auth
        self.history = history; self.push = push; self.cache = cache
        self.directory = directory; self.recents = recents
    }

    /// Seeded fakes over an in-memory cache. `now` is the clock the seed is shifted to.
    /// Async because the SwiftData cache must be built off the main thread.
    @concurrent public static func fake(now: Date = .now) async throws -> AppEnvironment {
        AppEnvironment(flights: FakeFlightService(now: now), airports: FakeAirportService(now: now), auth: FakeAuthService(),
                       history: FakeHistoryService(), push: FakePushService(), cache: try CacheStore.inMemory())
    }

    /// The configuration a normal launch uses: the on-disk cache and persisted recent searches.
    /// The fake data saved here while nobody is signed in belongs to no owner, so the cache drops it at
    /// the first real sign-in (`CacheStore.claim(for:)`).
    // TODO(Task 9): swap the fake services for the Supabase ones.
    @concurrent public static func live() async throws -> AppEnvironment {
        AppEnvironment(flights: FakeFlightService(), airports: FakeAirportService(), auth: FakeAuthService(),
                       history: FakeHistoryService(), push: FakePushService(), cache: try CacheStore.onDisk(),
                       recents: .standard)
    }

    /// Airport by ICAO or IATA, for the screens' `lookup`.
    public var lookup: @Sendable (String) -> Airport? { directory.lookup }

    /// UserDefaults for recent searches; nil keeps them in memory.
    var recentsDefaults: UserDefaults? {
        switch recents {
        case .memory: nil
        case .standard: .standard
        case .suite(let name): UserDefaults(suiteName: name)
        }
    }

    /// Hands the device's saved data to `user` (nil: nobody signed in). When the offline cache belonged to
    /// someone else, the recent searches go and the cache is wiped; a failed wipe throws.
    public func adopt(user: UUID?) async throws {
        guard await cache.owner() != user else { return }
        recentsDefaults?.removeObject(forKey: SearchStore.recentKey)
        try await cache.claim(for: user)
    }

    // MARK: Stores

    /// The list stores write through a scope that a wipe closes, so a load still running for the
    /// previous account cannot refill the cache.
    @MainActor public func makeMyFlightsStore() -> MyFlightsStore { MyFlightsStore(flights: flights, cache: cache.scoped()) }
    @MainActor public func makePassportStore() -> PassportStore { PassportStore(history: history, cache: cache.scoped()) }
    @MainActor public func makeSearchStore() -> SearchStore { SearchStore(flights: flights, defaults: recentsDefaults) }
    @MainActor public func makeAirportStore(code: String) -> AirportStore { AirportStore(code: code, airports: airports) }

    @MainActor public func makeFlightDetailStore(id: Flight.ID) -> FlightDetailStore {
        FlightDetailStore(id: id, flights: flights, airports: airports, cache: cache)
    }

    /// Hands the cache and recent searches over whenever the signed-in user changes.
    @MainActor public func makeSessionStore() -> SessionStore {
        let env = self
        return SessionStore(auth: auth, onUserChange: { try await env.adopt(user: $0) })
    }
}

/// Where recent searches persist.
public enum RecentsStorage: Sendable, Equatable {
    /// Kept in memory only (fakes, tests).
    case memory
    /// `UserDefaults.standard`.
    case standard
    /// A named suite.
    case suite(String)
}
