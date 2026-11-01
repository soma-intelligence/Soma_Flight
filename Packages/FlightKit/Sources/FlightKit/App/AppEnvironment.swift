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
    /// Recent departure gates for the flight sheet's gate prediction: the fakes with `-useFakes`,
    /// `gate_history` in live builds (free, so always on).
    public var gates: any GateHistoryService = UnavailableGateHistoryService()
    /// Other direct flights on a route, for the Connection Assistant (paid data, like `insights`): the fakes
    /// with `-useFakes`, `alternate-flights` when `INSIGHTS_ENABLED` is on, nothing otherwise.
    public var alternates: any AlternateFlightsService = UnavailableAlternateFlightsService()
    /// Live flight links for the flight sheet's Share (`share-flight`); `FlightScreen` puts it in
    /// `\.flightSharing`. None (text only) unless a builder sets it.
    public var sharing: any FlightShareService = UnavailableFlightShareService()
    /// FAA programs and decoded NOTAMs for Good to Know, the airport sheet and the Operations Report: the
    /// fakes with `-useFakes`, `faa-status` and `faa-notams` in live builds (free, so always on).
    public var faa: any FAAService = UnavailableFAAService()
    /// The Friends tab: friends, their shared flights, invitations. The fakes (two friends) with `-useFakes`,
    /// `friends` and the friend database functions in live builds (free, so always on).
    public var friends: any FriendsService = UnavailableFriendsService()
    /// The Airports list and the airport card's live layer: weather and FAA programs (free, always on), the
    /// board provider's numbers (answers "needs a data plan" without one) and Runway Regulars. The fakes with
    /// `-useFakes` (`-fakeNoProvider` answers like a backend without a board provider).
    public var airportOverview: any AirportOverviewService = UnavailableAirportOverviewService()
    /// Favourite airports; on this device only (no favourites table in Supabase yet).
    /// False keeps favourite airports in memory (fakes, tests), seeded with one airport.
    public var airportFavoritesPersist = true
    /// Text Me Too and in-flight texts (`sms-verify`): the fakes (nothing sent) with `-useFakes`, the backend in
    /// live builds, which answers "not available" until the owner turns texts on (docs/sms-alerts.md).
    public var textAlerts: any TextAlertsService = UnavailableTextAlertsService()
    /// The user's profile (names, photo, onboarding) and friends' photos: the fakes with `-useFakes`
    /// (`-onboarding apple|email|google` picks a first sign-in), the backend in live builds.
    public var profiles: any ProfileService = UnavailableProfileService()
    /// Shows "Continue with Google" on Sign In. Off until the owner turns Google on in Supabase and sets
    /// `GOOGLE_SIGN_IN_ENABLED = YES` (docs/profile-onboarding.md).
    public var googleSignIn = false
    /// A connection state that never changes (the fakes: online, offline with `-fakeOffline`); nil watches the
    /// device's own (`Connectivity.shared`).
    public var fixedConnectivity: Bool?
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
                faa: any FAAService = UnavailableFAAService(),
                passes: BoardingPassShelf = .inMemory(), simulatesWallet: Bool = false) {
        self.faa = faa
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
        var env = AppEnvironment(flights: flights, airports: FakeAirportService(now: now), auth: FakeAuthService(),
                                 history: FakeHistoryService(limit: pastLimit), push: FakePushService(),
                                 cache: try CacheStore.inMemory(), aircraftFacts: FakeAircraftFactsService(),
                                 brand: BundledSideViews(over: FakeBrandAssetService.bundled()), insights: FakeInsightsService(flights: flights),
                                 security: FakeSecurityWaitService(now: now),
                                 faa: FakeFAAService(now: now),
                                 passes: .inMemory(seed: [FakeBoardingPass.af84(now: now)]), simulatesWallet: true)
            .with(gates: FakeGateHistoryService())
            .withAlternates(FakeAlternateFlightsService(flights: flights))
        env.sharing = FakeFlightShareService(now: now)
        env.friends = FakeFriendsService(now: now)
        env.airportOverview = FakeAirportOverviewService(now: now)
        env.airportFavoritesPersist = false
        env.textAlerts = FakeTextAlertsService()
        env.profiles = FakeProfileService(now: now)
        env.fixedConnectivity = true
        return env
    }

    /// The configuration a normal launch uses: the Supabase services, the on-disk cache and persisted
    /// recent searches. The backend is the one in Info.plist (`SupabaseConfig.fromBundle()`).
    @concurrent public static func live() async throws -> AppEnvironment {
        var env = try supabase(config: SupabaseConfig.fromBundle(), cache: CacheStore.onDisk(), recents: .standard,
                               insights: SupabaseInsightsService.isEnabled())
        env.passes = .onDisk()
        env.googleSignIn = (Bundle.main.object(forInfoDictionaryKey: "GoogleSignInEnabled") as? String)?.uppercased() == "YES"
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
        var env = AppEnvironment(flights: SupabaseFlightService(backend: backend, airport: lookup),
                              airports: SupabaseAirportService(backend: backend, airport: lookup),
                              auth: SupabaseAuthService(backend: backend, push: push),
                              history: SupabaseHistoryService(backend: backend),
                              push: push, cache: cache, directory: directory,
                              recents: recents, requiresSignIn: true,
                              aircraftFacts: SupabaseAircraftFactsService(backend: backend),
                              brand: BundledSideViews(over: SupabaseBrandAssetService(backend: backend)),
                              insights: insights ? SupabaseInsightsService(backend: backend) : UnavailableInsightsService(),
                              notificationPreferences: SupabaseNotificationPreferencesService(backend: backend),
                              security: SupabaseSecurityWaitService(backend: backend),
                              faa: SupabaseFAAService(backend: backend))
            .with(gates: SupabaseGateHistoryService(backend: backend))
            .withAlternates(insights ? SupabaseAlternateFlightsService(backend: backend) : UnavailableAlternateFlightsService())
        env.sharing = SupabaseFlightShareService(backend: backend)
        env.friends = SupabaseFriendsService(backend: backend)
        env.airportOverview = SupabaseAirportOverviewService(backend: backend)
        env.textAlerts = SupabaseTextAlertsService(backend: backend)
        env.profiles = SupabaseProfileService(backend: backend)
        return env
    }

    /// A copy with `gates` set.
    func with(gates: any GateHistoryService) -> AppEnvironment {
        var env = self
        env.gates = gates
        return env
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
        var env = try await fake(pastLimit: limit)
        env.fixedConnectivity = !arguments.contains("-fakeOffline")
        if arguments.contains("-fakeConnection") { await env.addFakeConnection() }
        // The Airports screens as a backend without a board provider shows them.
        if arguments.contains("-fakeNoProvider") { env.airportOverview = FakeAirportOverviewService(live: false) }
        if let i = arguments.firstIndex(of: "-onboarding"), arguments.indices.contains(i + 1),
           let scenario = FakeProfileService.Scenario(rawValue: arguments[i + 1]) {
            env.profiles = FakeProfileService(scenario)
        }
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
    @MainActor public func makeFriendsStore() -> FriendsStore { FriendsStore(service: friends) }
    @MainActor public func makeProfileStore() -> ProfileStore {
        ProfileStore(service: profiles, defaults: recentsDefaults)
    }
    @MainActor public func makeSearchStore() -> SearchStore { SearchStore(flights: flights, defaults: recentsDefaults) }
    @MainActor public func makeAirportStore(code: String) -> AirportStore {
        AirportStore(code: code, airports: airports, security: security, faa: faa, overview: airportOverview)
    }

    @MainActor public func makeFlightDetailStore(id: Flight.ID, owner: UUID?) -> FlightDetailStore {
        let store = FlightDetailStore(id: id, flights: flights, airports: airports, history: detailHistory, insights: insights,
                          security: security, gates: gates, faa: faa, cache: cache.scoped(for: owner), passes: passes.vault(for: owner),
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
