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
    /// Where recent searches persist; nil keeps them in memory (fakes, tests).
    public var recentsSuite: String?

    public init(flights: any FlightService, airports: any AirportService, auth: any AuthService,
                history: any HistoryService, push: any PushService, cache: CacheStore,
                directory: AirportDirectory = .bundled(), recentsSuite: String? = nil) {
        self.flights = flights; self.airports = airports; self.auth = auth
        self.history = history; self.push = push; self.cache = cache
        self.directory = directory; self.recentsSuite = recentsSuite
    }

    /// Seeded fakes over an in-memory cache. `now` is the clock the seed is shifted to.
    /// Async because the SwiftData cache must be built off the main thread.
    @concurrent public static func fake(now: Date = .now) async throws -> AppEnvironment {
        AppEnvironment(flights: FakeFlightService(now: now), airports: FakeAirportService(now: now), auth: FakeAuthService(),
                       history: FakeHistoryService(), push: FakePushService(), cache: try CacheStore.inMemory())
    }

    /// The configuration a normal launch uses: the on-disk cache and persisted recent searches.
    /// The services are still the fakes; the Supabase services of Task 9 take their place.
    @concurrent public static func live() async throws -> AppEnvironment {
        AppEnvironment(flights: FakeFlightService(), airports: FakeAirportService(), auth: FakeAuthService(),
                       history: FakeHistoryService(), push: FakePushService(), cache: try CacheStore.onDisk(),
                       recentsSuite: "")
    }

    /// Airport by ICAO or IATA, for the screens' `lookup`.
    public var lookup: @Sendable (String) -> Airport? { directory.lookup }

    /// UserDefaults for recent searches: "" is the standard suite.
    var recentsDefaults: UserDefaults? {
        guard let recentsSuite else { return nil }
        return recentsSuite.isEmpty ? .standard : UserDefaults(suiteName: recentsSuite)
    }

    /// Wipes everything the signed-out account left on the device: the offline cache and recent searches.
    public func clearUserData() async {
        await cache.clear()
        recentsDefaults?.removeObject(forKey: SearchStore.recentKey)
    }

    // MARK: Stores

    @MainActor public func makeMyFlightsStore() -> MyFlightsStore { MyFlightsStore(flights: flights, cache: cache) }
    @MainActor public func makePassportStore() -> PassportStore { PassportStore(history: history, cache: cache) }
    @MainActor public func makeSearchStore() -> SearchStore { SearchStore(flights: flights, defaults: recentsDefaults) }
    @MainActor public func makeAirportStore(code: String) -> AirportStore { AirportStore(code: code, airports: airports) }

    @MainActor public func makeFlightDetailStore(id: Flight.ID) -> FlightDetailStore {
        FlightDetailStore(id: id, flights: flights, airports: airports, cache: cache)
    }

    /// Clears the cache and recent searches whenever the session ends.
    @MainActor public func makeSessionStore() -> SessionStore {
        let env = self
        return SessionStore(auth: auth, onSignedOut: { await env.clearUserData() })
    }
}
