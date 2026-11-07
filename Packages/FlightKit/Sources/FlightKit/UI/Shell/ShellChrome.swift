import SwiftUI

// MARK: - Pushed screens

/// Flight detail with its own store, loaded on appear, and the circular X that pops it.
public struct FlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void
    var onStopTracking: ((Flight.ID) async -> APIError?)?
    var sharing: any FlightShareService
    var brief: any FlightBriefService
    /// The More menu's "Text Me Updates In Flight" for this flight.
    @State private var texts: FlightTextsModel

    /// - Parameter onStopTracking: unfollows the flight (the menu's "Stop Tracking") and returns the error, nil
    ///   on success; nil lets the store ask the service. The sheet closes once it worked.
    public init(env: AppEnvironment, id: Flight.ID, owner: UUID?, onAirport: @escaping (String) -> Void,
                onClose: @escaping () -> Void, onStopTracking: ((Flight.ID) async -> APIError?)? = nil) {
        _store = State(initialValue: env.makeFlightDetailStore(id: id, owner: owner))
        self.onAirport = onAirport; self.onClose = onClose; self.onStopTracking = onStopTracking
        sharing = env.sharing; brief = env.flightBrief
        _texts = State(initialValue: FlightTextsModel(flight: id, service: env.textAlerts))
    }

    public var body: some View {
        FlightDetailView(store: store, onAirport: onAirport, onClose: onClose, onStopTracking: onStopTracking)
            .environment(\.flightSharing, sharing)
            .environment(\.flightTexts, texts)
            .environment(\.flightBrief, brief)
            .task { await texts.load() }
            .task {
                await store.load()
                // The live position of a followed flight in the air; it also reaches the globe through
                // My Flights' live updates.
                await store.followPosition()
            }
    }
}

/// A Passport flight in the flight sheet: no network call for the flight itself, read only.
public struct PastFlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void

    public init(env: AppEnvironment, flight: PastFlight, onAirport: @escaping (String) -> Void,
                onClose: @escaping () -> Void) {
        _store = State(initialValue: FlightDetailStore(past: flight, flights: env.flights, airports: env.airports,
                                                       history: env.history))
        self.onAirport = onAirport; self.onClose = onClose
    }

    public var body: some View {
        FlightDetailView(store: store, onAirport: onAirport, onClose: onClose)
            .task { await store.load() }
    }
}

/// A friend's flight in the flight sheet, read only like a Passport flight: no follow, alerts, share link,
/// booking tiles or boarding pass, only what the friend shared.
public struct FriendFlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void

    public init(env: AppEnvironment, flight: Flight, onAirport: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        _store = State(initialValue: FlightDetailStore(friend: flight, flights: env.flights, airports: env.airports))
        self.onAirport = onAirport; self.onClose = onClose
    }

    public var body: some View {
        FlightDetailView(store: store, onAirport: onAirport, onClose: onClose)
            .task { await store.load() }
    }
}

/// Airport sheet with its own store; far-end city names come from the shared airport list.
public struct AirportScreen: View {
    @State private var store: AirportStore
    var lookup: (String) -> Airport?
    var favorites: AirportFavorites?
    var favoriteAlerts: any FavoriteAirportAlertsService
    var pastFlights: [PastFlight]
    var onClose: () -> Void
    var brief: any FlightBriefService

    public init(env: AppEnvironment, code: String, favorites: AirportFavorites? = nil, pastFlights: [PastFlight] = [],
                onClose: @escaping () -> Void) {
        _store = State(initialValue: env.makeAirportStore(code: code))
        self.lookup = env.lookup; self.favorites = favorites; self.pastFlights = pastFlights; self.onClose = onClose
        brief = env.flightBrief
        self.favoriteAlerts = env.favoriteAirportAlerts
    }

    public var body: some View {
        AirportView(store: store, lookup: lookup, favorites: favorites, pastFlights: pastFlights)
            .environment(\.flightBrief, brief)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .overlay(alignment: .topTrailing) {
                FavoriteAirportToggle(service: favoriteAlerts, icao: store.airport?.id, country: store.airport?.country)
                    .scaledPadding(.trailing, 68)
            }
            .task { await store.load() }
    }
}

/// The screen a route in the panel's stack opens.
public struct HomeDestination: View {
    var home: HomeModel
    var route: SheetRoute

    public init(home: HomeModel, route: SheetRoute) {
        self.home = home; self.route = route
    }

    public var body: some View {
        switch route {
        case .flight(let id):
            FlightScreen(env: home.env, id: id, owner: home.owner, onAirport: home.open(airport:),
                         onClose: home.shell.close) { id in
                // Through My Flights so its list drops the flight at once.
                guard let flight = home.followed.first(where: { $0.id == id }) else {
                    do throws(APIError) { try await home.env.flights.unfollow(id); return nil } catch { return error }
                }
                await home.myFlights.unfollow(flight)
                return home.myFlights.error
            }
            // A flight followed from the "Other flights" card: My Flights takes it and the sheet shows it.
            .onFollowedAlternate { flight in
                await home.didFollow(flight)
                home.open(flight: flight)
            }
        case .pastFlight(let flight):
            PastFlightScreen(env: home.env, flight: flight, onAirport: home.open(airport:), onClose: home.shell.close)
        case .airport(let code):
            AirportScreen(env: home.env, code: code, favorites: home.airportsList.favorites,
                          pastFlights: home.passport.allFlights, onClose: home.shell.close)
        case .friend(let id):
            FriendPageView(store: home.friends, friendID: id, lookup: home.env.lookup,
                           onOpenFlight: home.open(friendFlight:), onClose: home.shell.close)
        case .friendFlight(let ff):
            FriendFlightScreen(env: home.env, flight: ff.flight, onAirport: home.open(airport:), onClose: home.shell.close)
        case .airports:
            AirportsListView(store: home.airportsList, onOpen: home.open(airport:), onClose: home.shell.close)
                .task { await home.airportsList.load() }
        }
    }
}

// MARK: - Chrome

/// Floating pill with the three tabs (My Flights, Friends, Passport) and the round search button beside it.
public struct HomeTabPill: View {
    @Binding var tab: HomeTab
    var onSearch: () -> Void
    var bottom: CGFloat
    @Namespace private var selectionSpace
    @Environment(\.metricsScale) private var scale

    /// Darkens the glass so the cards scrolling under it stay quiet, as in the reference.
    static let tint = Color(light: 0xFFFFFF, dark: 0x1C1C1E).opacity(0.55)

    /// - Parameter bottom: space under the pill; negative reaches into a home indicator inset.
    public init(tab: Binding<HomeTab>, bottom: CGFloat = 0, onSearch: @escaping () -> Void) {
        _tab = tab; self.bottom = bottom; self.onSearch = onSearch
    }

    public var body: some View {
        HStack(spacing: Theme.metric(10, scale)) {
            HStack(spacing: 0) {
                item(.flights, title: "My Flights", systemImage: "airplane.circle.fill")
                item(.friends, title: "Friends", systemImage: "person.2.fill")
                item(.passport, title: "Passport", systemImage: "person.text.rectangle.fill")
            }
            .scaledPadding(.all, 4)
            .glassEffect(.regular.tint(Self.tint), in: .capsule)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.metric(22, scale), weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: Theme.metric(59, scale), height: Theme.metric(59, scale))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Self.tint).interactive(), in: .circle)
            .accessibilityLabel("Search")
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 8)
        .scaledPadding(.bottom, bottom)
    }

    private func item(_ value: HomeTab, title: String, systemImage: String) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.snappy) { tab = value }
        } label: {
            VStack(spacing: Theme.metric(2, scale)) {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.metric(21, scale), weight: .medium))
                    .frame(height: Theme.metric(25, scale))
                Text(ui: title)
                    .font(.system(size: Theme.fontSize(11, scale), weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.metric(51, scale))
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Round Liquid Glass button for the panel header (Settings) and the close X, the same glass as the
/// map controls' capsule; it lights up and flexes under the finger.
public struct RoundButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    var tint: Color?
    @Environment(\.metricsScale) private var scale

    /// - Parameter fill: tints the glass (a page in its own colour); plain glass when nil.
    public init(systemImage: String, label: String, fill: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage; self.label = label; self.action = action; self.tint = fill
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.metric(18, scale), weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: Theme.metric(44, scale), height: Theme.metric(44, scale))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .roundGlass(tint: tint)
        .accessibilityLabel(label)
    }
}

public extension View {
    /// The interactive Liquid Glass circle of every round floating control (`RoundButton`, the close X,
    /// the round menus beside them), optionally tinted.
    func roundGlass(tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
    }
}

/// The circular glass X at the top right of a card or a modal sheet.
public struct CloseButton: View {
    var action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        RoundButton(systemImage: "xmark", label: "Close", action: action)
            .scaledPadding(.top, 16)
            .scaledPadding(.trailing, 16)
    }
}

/// What shows for the moment the environment takes to build, or the reason it could not.
public struct LaunchPlaceholder: View {
    var failure: String?
    var showsProgress: Bool
    var onRetry: (() -> Void)?

    /// - Parameters:
    ///   - showsProgress: a spinner while there is no failure (iOS keeps the plain black screen).
    ///   - onRetry: adds a Try Again button under the failure.
    public init(failure: String?, showsProgress: Bool = false, onRetry: (() -> Void)? = nil) {
        self.failure = failure; self.showsProgress = showsProgress; self.onRetry = onRetry
    }

    /// The line shown when the cache cannot open.
    public static let storageFailure = "Soma Flight could not open its storage. Restart the app to try again."
    /// The line shown when the build carries no backend address (Config.xcconfig).
    public static let configFailure = "This build of Soma Flight has no server configured."

    /// The line for a launch that threw `error`.
    public static func failure(for error: any Error) -> String {
        error is SupabaseConfig.Failure ? configFailure : storageFailure
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                VStack(spacing: 16) {
                    Text(ui: failure)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let onRetry {
                        Button("Try Again", action: onRetry)
                    }
                }
                .padding(32)
            } else if showsProgress {
                ProgressView()
            }
        }
    }
}

/// Sign In instead of the home while the backend needs an account and nobody is signed in; a blank
/// launch screen while the stored session is still being read. Starts following the session.
public struct SignInGate<Home: View>: View {
    var home: HomeModel
    var showsProgress: Bool
    var content: () -> Home
    @Environment(\.scenePhase) private var scenePhase

    public init(home: HomeModel, showsProgress: Bool = false, @ViewBuilder content: @escaping () -> Home) {
        self.home = home; self.showsProgress = showsProgress; self.content = content
    }

    public var body: some View {
        Group {
            if home.needsSignIn {
                SignInView(session: home.session, onEmail: { await home.session.signInWithEmail($0) },
                           onGoogle: home.env.googleSignIn ? { await home.session.signInWithGoogle() } : nil)
            } else if home.awaitingSession || home.profile.gate == .unknown {
                LaunchPlaceholder(failure: nil, showsProgress: showsProgress)
            } else if home.profile.gate == .show {
                // Once, after the first sign-in: the name and photo friends will see. Later skips it.
                ProfileOnboardingView(store: home.profile)
                    .transition(CardMotion.transition)
            } else {
                content()
                    .transition(.opacity)
            }
        }
        .animation(CardMotion.animation, value: home.profile.gate)
        .environment(\.friendPhotos, home.profile.friendPhotos)
        .task { home.session.startIfNeeded() }
        // Each account's profile: whether onboarding shows, the header's avatar.
        .task(id: home.profileOwner) { await home.prepareProfile() }
        // Above the gate, so it runs signed out too: an activity can only start in the foreground, and
        // one a previous account left must end even while Sign In is on screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await home.reconcileActivities() } }
        }
    }
}
