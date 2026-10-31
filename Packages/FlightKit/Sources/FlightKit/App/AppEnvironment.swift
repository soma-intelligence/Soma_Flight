import Foundation
import Supabase

/// The services, cache and airport list one app run works with. The iOS and macOS shells build one
/// at launch and make every store from it.
public struct AppEnvironment: Sendable {
    public var flights: any FlightService
    public var airports: any AirportService
    public var auth: any AuthService
    public var history: any HistoryService {
        didSet { detailHistory = CachedHistoryService(history) }
    }
    /// `history` kept for ten minutes, for the flight sheets' history card.
    private var detailHistory: CachedHistoryService
    public var push: any PushService
    /// Airframe delivery dates and names for the Passport's ages; nil shows no ages.
    public var aircraftFacts: (any AircraftFactsService)?
    /// Airline logos (versioned disk cache over `brand-asset`); the shells put it in `\.brandAssets`.
    public var brand: any BrandAssetService
    /// The flight sheet's paid insights (arrival forecast, inbound chain): the fakes with `-useFakes`,
    /// `flight-insights` in live builds whose Info.plist turns them on (`INSIGHTS_ENABLED`), nothing otherwise.
    public var insights: any InsightsService
    /// The account's alert categories (Settings > Notifications); the home's `notificationSettings`.
    public var notificationPreferences: any NotificationPreferencesService
    /// Security (TSA) waits for Good to Know and the airport sheet: the fakes with `-useFakes`,
    /// `security-wait` in live builds (free, so always on).
    public var security: any SecurityWaitService
    /// Other direct flights on a route, for the Connection Assistant (paid data, like `insights`): the fakes
    /// with `-useFakes`, `alternate-flights` when `INSIGHTS_ENABLED` is on, nothing otherwise.
    public var alternates: any AlternateFlightsService = UnavailableAlternateFlightsService()
    public var cache: CacheStore
    public var directory: AirportDirectory
    /// Airlines, aircraft types and countries.
    public var reference: ReferenceData
    /// Where recent searches persist.
    public var recents: RecentsStorage
    /// Boarding passes, one folder per account on this device; never sent to the server (they are
    /// personal data). The fakes keep them in memory with a pass on AF 84.
    public var passes: BoardingPassShelf
    /// True with the fakes: Add to Apple Wallet only pretends (the fake pass has no signed file).
    public var simulatesWallet: Bool
    /// True when nothing works without an account (the backend): the shells show Sign In until there
    /// is a session. The fakes answer without one, so screenshot runs open straight on the home.
    public var requiresSignIn: Bool

    public init(flights: any FlightService, airports: any AirportService, auth: any AuthService,
                history: any HistoryService, push: any PushService, cache: CacheStore,
                directory: AirportDirectory = .bundled(), reference: ReferenceData = .bundled(),
                recents: RecentsStorage = .memory, requiresSignIn: Bool = false,
                aircraftFacts: (any AircraftFactsService)? = nil,
                brand: any BrandAssetService = FakeBrandAssetService(),
                insights: any InsightsService = UnavailableInsightsService(),
                notificationPreferences: any NotificationPreferencesService = FakeNotificationPreferencesService(),
                security: any SecurityWaitService = UnavailableSecurityWaitService(),
                passes: BoardingPassShelf = .inMemory(), simulatesWallet: Bool = false) {
        self.passes = passes; self.simulatesWallet = simulatesWallet
        self.flights = flights; self.airports = airports; self.auth = auth
        self.history = history; self.detailHistory = CachedHistoryService(history); self.push = push; self.aircraftFacts = aircraftFacts; self.brand = brand; self.insights = insights; self.security = security; self.cache = cache
        self.notificationPreferences = notificationPreferences
        self.directory = directory; self.reference = reference; self.recents = recents; self.requiresSignIn = requiresSignIn
    }

    /// Seeded fakes over an in-memory cache. `now` is the clock the seed is shifted to.
    /// Async because the SwiftData cache must be built off the main thread.
    /// - Parameter pastLimit: keeps only the newest flights of the past history (`-fakePast <n>`).
    @concurrent public static func fake(now: Date = .now, pastLimit: Int? = nil) async throws -> AppEnvironment {
        let flights = FakeFlightService(now: now)
        return AppEnvironment(flights: flights, airports: FakeAirportService(now: now), auth: FakeAuthService(),
                              history: FakeHistoryService(limit: pastLimit), push: FakePushService(),
                              cache: try CacheStore.inMemory(), aircraftFacts: FakeAircraftFactsService(),
                              brand: BundledSideViews(over: FakeBrandAssetService.bundled()), insights: FakeInsightsService(flights: flights),
                              security: FakeSecurityWaitService(now: now),
                              passes: .inMemory(seed: [FakeBoardingPass.af84(now: now)]), simulatesWallet: true)
        .withAlternates(FakeAlternateFlightsService(flights: flights))
    }

    /// The configuration a normal launch uses: the Supabase services, the on-disk cache and persisted
    /// recent searches. The backend is the one in Info.plist (`SupabaseConfig.fromBundle()`).
    @concurrent public static func live() async throws -> AppEnvironment {
        var env = try supabase(config: SupabaseConfig.fromBundle(), cache: CacheStore.onDisk(), recents: .standard,
                               insights: SupabaseInsightsService.isEnabled())
        env.passes = .onDisk()
        return env
    }

    /// The Supabase services over one client, with the bundled airport directory.
    /// - Parameters:
    ///   - authStorage: where the session persists; nil is the Keychain.
    ///   - insights: true asks `flight-insights` for the paid sections; false shows none and calls nothing.
    public static func supabase(config: SupabaseConfig, cache: CacheStore, recents: RecentsStorage,
                                directory: AirportDirectory = .bundled(),
                                authStorage: (any AuthLocalStorage)? = nil,
                                insights: Bool = false) -> AppEnvironment {
        let backend = SupabaseBackend(config: config, authStorage: authStorage)
        let lookup = directory.lookup
        let push = SupabasePushService(backend: backend, defaults: recents == .memory ? nil : .standard)
        return AppEnvironment(flights: SupabaseFlightService(backend: backend, airport: lookup),
                              airports: SupabaseAirportService(backend: backend, airport: lookup),
                              auth: SupabaseAuthService(backend: backend, push: push),
                              history: SupabaseHistoryService(backend: backend),
                              push: push, cache: cache, directory: directory,
                              recents: recents, requiresSignIn: true,
                              aircraftFacts: SupabaseAircraftFactsService(backend: backend),
                              brand: BundledSideViews(over: SupabaseBrandAssetService(backend: backend)),
                              insights: insights ? SupabaseInsightsService(backend: backend) : UnavailableInsightsService(),
                              notificationPreferences: SupabaseNotificationPreferencesService(backend: backend),
                              security: SupabaseSecurityWaitService(backend: backend))
        .withAlternates(insights ? SupabaseAlternateFlightsService(backend: backend) : UnavailableAlternateFlightsService())
    }

    /// The environment an app launch runs on: `-useFakes` on the command line gives the seeded fakes
    /// over an in-memory cache (screenshot runs), anything else the backend (`live()`). Both shells call this.
    /// With fakes in DEBUG builds, `-fakePast <n>` keeps the newest n past flights (a sparse Passport).
    public static func forLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) async throws -> AppEnvironment {
        HistoryExport.removeTemporaryFiles()
        guard arguments.contains("-useFakes") else { return try await live() }
        #if DEBUG
        let limit = arguments.firstIndex(of: "-fakePast").flatMap { i in
            arguments.indices.contains(i + 1) ? Int(arguments[i + 1]) : nil
        }
        let env = try await fake(pastLimit: limit)
        if arguments.contains("-fakeConnection") { await env.addFakeConnection() }
        return env
        #else
        return try await fake()
        #endif
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
        guard await !cache.isOwned(by: user) else { return }
        recentsDefaults?.removeObject(forKey: SearchStore.recentKey)
        HistoryExport.removeTemporaryFiles()
        // The previous account's boarding passes leave the device with its cache.
        passes.keepOnly(user)
        try await cache.claim(for: user)
    }

    // MARK: Stores

    /// The stores read and write the cache through a scope for `owner`, the user signed in now (nil:
    /// nobody). It reads as empty while the cache belongs to someone else, and a wipe closes it, so a
    /// load still running for the previous account cannot refill the cache.
    @MainActor public func makeMyFlightsStore(owner: UUID?) -> MyFlightsStore {
        MyFlightsStore(flights: flights, cache: cache.scoped(for: owner))
    }
    @MainActor public func makePassportStore(owner: UUID?) -> PassportStore {
        PassportStore(history: history, cache: cache.scoped(for: owner), reference: reference, facts: aircraftFacts,
                      airports: directory.lookup)
    }
    @MainActor public func makeSearchStore() -> SearchStore { SearchStore(flights: flights, defaults: recentsDefaults) }
    @MainActor public func makeAirportStore(code: String) -> AirportStore {
        AirportStore(code: code, airports: airports, security: security)
    }

    @MainActor public func makeFlightDetailStore(id: Flight.ID, owner: UUID?) -> FlightDetailStore {
        let store = FlightDetailStore(id: id, flights: flights, airports: airports, history: detailHistory, insights: insights,
                          security: security, cache: cache.scoped(for: owner), passes: passes.vault(for: owner),
                          lookup: directory.lookup, simulatesWallet: simulatesWallet)
        store.connections = ConnectionStore(id: id, flights: flights, airports: airports, alternates: alternates,
                                            lookup: directory.lookup)
        return store
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
