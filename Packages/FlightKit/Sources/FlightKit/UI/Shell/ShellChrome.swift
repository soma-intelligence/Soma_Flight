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
    ///   - seed: the flight as My Flights has it, shown at once while the detail loads.
    public init(env: AppEnvironment, id: Flight.ID, owner: UUID?, seed: Flight? = nil,
                onAirport: @escaping (String) -> Void,
                onClose: @escaping () -> Void, onStopTracking: ((Flight.ID) async -> APIError?)? = nil) {
        let store = env.makeFlightDetailStore(id: id, owner: owner)
        store.seed(seed)
        _store = State(initialValue: store)
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

/// A Passport flight in the flight sheet: no network call for the flight itself, read only, with the
/// account's travel journal for its photos.
public struct PastFlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void
    var journal: any TravelJournal

    /// - Parameter owner: the account signed in now, whose travel journal the sheet shows.
    public init(env: AppEnvironment, flight: PastFlight, owner: UUID? = nil, onAirport: @escaping (String) -> Void,
                onClose: @escaping () -> Void) {
        _store = State(initialValue: FlightDetailStore(past: flight, flights: env.flights, airports: env.airports,
                                                       history: env.history))
        self.onAirport = onAirport; self.onClose = onClose
        journal = env.journal.journal(for: owner)
    }

    public var body: some View {
        FlightDetailView(store: store, onAirport: onAirport, onClose: onClose)
            .environment(\.travelJournal, journal)
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
        // The bell and the close X sit in the airport's Detail header (R5).
        AirportView(store: store, lookup: lookup, favorites: favorites, pastFlights: pastFlights, onClose: onClose,
                    headerActions: AnyView(
                        FavoriteAirportToggle(service: favoriteAlerts, icao: store.airport?.id,
                                              country: store.airport?.country)
                            // The toggle keeps its own 16 pt top inset for an overlay; the header centres it.
                            .scaledPadding(.top, -16)))
            .environment(\.flightBrief, brief)
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
            FlightScreen(env: home.env, id: id, owner: home.owner, seed: home.followed.first { $0.id == id },
                         onAirport: home.open(airport:),
                         onClose: home.shell.close) { id in
                // Through the home's undoable removal (I1, E15): the detail closes at once, the list drops the
                // flight, and the toast offers Undo before the server hears of it.
                guard let flight = home.myFlights.flight(id) else {
                    do throws(APIError) { try await home.env.flights.unfollow(id); return nil } catch { return error }
                }
                home.unfollowWithUndo(flight)
                return nil
            }
            // The detail's Stop Following: the home's undoable removal, so the toast offers Undo (I1, E15).
            .onStopFollowing { flight in
                guard home.myFlights.contains(flight.id) else { return false }
                home.unfollowWithUndo(flight)
                return true
            }
            // A flight followed from the "Other flights" card: My Flights takes it and the sheet shows it.
            .onFollowedAlternate { flight in
                await home.didFollow(flight)
                home.open(flight: flight)
            }
        case .pastFlight(let flight):
            PastFlightScreen(env: home.env, flight: flight, owner: home.owner, onAirport: home.open(airport:),
                             onClose: home.shell.close)
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
    var onReselect: (() -> Void)?
    var bottom: CGFloat
    @Namespace private var selectionSpace
    @Environment(\.metricsScale) private var scale

    /// Darkens the glass so the cards scrolling under it stay quiet, as in the reference.
    public static let tint = Color(light: 0xFFFFFF, dark: 0x1C1C1E).opacity(0.55)

    /// - Parameters:
    ///   - bottom: space under the pill; negative reaches into a home indicator inset.
    ///   - onReselect: the selected tab was tapped again (I10): pop the open cards, else scroll to the top.
    public init(tab: Binding<HomeTab>, bottom: CGFloat = 0, onSearch: @escaping () -> Void,
                onReselect: (() -> Void)? = nil) {
        _tab = tab; self.bottom = bottom; self.onSearch = onSearch; self.onReselect = onReselect
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
            .pointerHighlight(Circle())
            .accessibilityLabel("Search")
            // Fixed size: a long press at accessibility text sizes shows it large (A6).
            .accessibilityShowsLargeContentViewer {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 8)
        .scaledPadding(.bottom, bottom)
    }

    private func item(_ value: HomeTab, title: String, systemImage: String) -> some View {
        let selected = tab == value
        return Button {
            if selected { onReselect?() } else { withAnimation(HomeTab.switchAnimation) { tab = value } }
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
            .pointerHighlight(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label { Text(ui: title) } icon: { Image(systemName: systemImage) }
        }
    }
}

/// Round Liquid Glass button for the panel header (Settings) and the close X, the same glass as the
/// map controls' capsule; it lights up and flexes under the finger.
public struct RoundButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    var tint: Color?
    var side: CGFloat
    @Environment(\.metricsScale) private var scale

    /// - Parameters:
    ///   - fill: tints the glass (a page in its own colour); plain glass when nil.
    ///   - side: the circle's diameter before Dynamic Type scaling (44, or 36 in a slim bar).
    public init(systemImage: String, label: String, fill: Color? = nil, side: CGFloat = 44, action: @escaping () -> Void) {
        self.systemImage = systemImage; self.label = label; self.action = action; self.tint = fill; self.side = side
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.metric(side * 0.41, scale), weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: Theme.metric(side, scale), height: Theme.metric(side, scale))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .roundGlass(tint: tint)
        .pointerHighlight(Circle())
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label { Text(ui: label) } icon: { Image(systemName: systemImage) }
        }
    }
}

public extension View {
    /// Lights the control up under an iPad pointer (and the Vision Pro's gaze), in `shape`. Nothing on the
    /// Mac, nothing on an iPhone, which has no pointer.
    @ViewBuilder func pointerHighlight(_ shape: some Shape) -> some View {
        #if os(iOS)
        contentShape(.hoverEffect, shape).hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// The interactive Liquid Glass circle of every round floating control (`RoundButton`, the close X,
    /// the round menus beside them), optionally tinted.
    func roundGlass(tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
    }
}

/// The one close control of the app (R5): a 44 pt Liquid Glass circle with the `xmark` symbol.
/// Penpot: Button/Close
public struct CloseButton: View {
    var action: () -> Void
    var inset: Bool

    /// - Parameter inset: keeps the 16 pt top and trailing margin for a `.overlay(alignment: .topTrailing)`
    ///   placement (the default, as before); false inside a laid out header such as `SheetHeader`.
    public init(inset: Bool = true, action: @escaping () -> Void) { self.action = action; self.inset = inset }

    public var body: some View {
        RoundButton(systemImage: "xmark", label: "Close", side: 44, action: action)
            .scaledPadding(.top, inset ? 16 : 0)
            .scaledPadding(.trailing, inset ? 16 : 0)
    }
}

/// What shows for the moment the environment takes to build, or the reason it could not.
public struct LaunchPlaceholder: View {
    var failure: String?
    var showsProgress: Bool
    var onRetry: (() -> Void)?
    /// The black screen has lasted `progressDelay`: the spinner shows (E16).
    @State private var waited = false

    /// How long the plain black screen lasts before a spinner says the app is still working (E16).
    public static let progressDelay: Duration = .seconds(1)

    /// - Parameters:
    ///   - showsProgress: a spinner at once while there is no failure. False (iOS) keeps the black screen
    ///     for `progressDelay`, then shows the spinner, so a slow launch never looks frozen (E16).
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
            } else if showsProgress || waited {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(Text(ui: "Loading"))
            }
        }
        .task {
            guard !showsProgress else { return }
            try? await Task.sleep(for: Self.progressDelay)
            waited = true
        }
    }
}

/// Sign In instead of the home while the backend needs an account and nobody is signed in; a launch
/// placeholder while the stored session is still being read. Starts following the session.
///
/// - Session expired (E3): once the home has shown, an expired session does not swap the whole tree for
///   Sign In. Sign In opens as a sheet over the current state, so open editors keep their text, and the
///   banners' "Sign In" (`EnvironmentValues.requestSignIn`) opens the same sheet.
/// - First launch (E16): the placeholder shows a spinner after a second, and the wait for the profile's
///   onboarding answer is capped at `profileWaitCap`; the home shows then.
/// - Background: removals still in their Undo window are sent before the app is suspended (I1).
public struct SignInGate<Home: View>: View {
    var home: HomeModel
    var showsProgress: Bool
    var content: () -> Home
    @Environment(\.scenePhase) private var scenePhase
    /// The home has been on screen in this run: an expiry from here on opens a sheet over it.
    @State private var homeShown = false
    @State private var signInSheet = false
    /// The profile's answer took longer than `profileWaitCap`.
    @State private var profileWaitOver = false

    /// The longest the launch waits for the profile before showing the home (E16).
    public static var profileWaitCap: Duration { .seconds(5) }

    public init(home: HomeModel, showsProgress: Bool = false, @ViewBuilder content: @escaping () -> Home) {
        self.home = home; self.showsProgress = showsProgress; self.content = content
    }

    /// What the gate shows (pure, for tests).
    public enum Screen: Equatable, Sendable { case signIn, placeholder, onboarding, home }

    public static func screen(needsSignIn: Bool, sessionExpired: Bool, homeShown: Bool, awaitingSession: Bool,
                              gate: ProfileStore.Gate, profileWaitOver: Bool) -> Screen {
        // An expiry over a home already shown keeps the home; the sign-in sheet covers it instead.
        if needsSignIn && !(sessionExpired && homeShown) { return .signIn }
        if awaitingSession { return .placeholder }
        switch gate {
        case .unknown: return profileWaitOver ? .home : .placeholder
        case .show: return .onboarding
        case .hidden: return .home
        }
    }

    private var screen: Screen {
        Self.screen(needsSignIn: home.needsSignIn, sessionExpired: home.isSessionExpired, homeShown: homeShown,
                    awaitingSession: home.awaitingSession, gate: home.profile.gate, profileWaitOver: profileWaitOver)
    }

    public var body: some View {
        Group {
            switch screen {
            case .signIn:
                signInView
            case .placeholder:
                LaunchPlaceholder(failure: nil, showsProgress: showsProgress)
            case .onboarding:
                // Once, after the first sign-in: the name and photo friends will see. Later skips it.
                ProfileOnboardingView(store: home.profile)
                    .transition(CardMotion.transition)
            case .home:
                content()
                    .transition(.opacity)
                    .onAppear { homeShown = true }
            }
        }
        .animation(CardMotion.animation, value: home.profile.gate)
        .environment(\.friendPhotos, home.profile.friendPhotos)
        .environment(\.requestSignIn, { signInSheet = true })
        .sheet(isPresented: Binding(get: { signInSheet && screen == .home }, set: { open in
            signInSheet = open
            // Closed without signing in: with the account still here the banners keep their Sign In
            // button for later; with nobody signed in the full Sign In screen takes over.
            if !open { home.session.clearSessionExpired() }
        })) {
            signInView
                .presentationDetents([.large])
                .presentationBackground(Theme.background)
                .presentationCornerRadius(Theme.sheetRadius)
        }
        .onChange(of: home.isSessionExpired) { _, expired in
            // Expired: the sheet rises over what is open. Signed in again: it goes.
            if expired, homeShown { signInSheet = true }
            if !expired { signInSheet = false }
        }
        .onChange(of: home.needsSignIn) { _, needs in if !needs, !home.isSessionExpired { signInSheet = false } }
        .task { home.session.startIfNeeded() }
        // Each account's profile: whether onboarding shows, the header's avatar.
        .task(id: home.profileOwner) { await home.prepareProfile() }
        // The profile's answer is waited for at most `profileWaitCap` (E16).
        .task(id: home.profile.gate == .unknown && !home.awaitingSession) {
            guard home.profile.gate == .unknown, !home.awaitingSession else { return }
            profileWaitOver = false
            try? await Task.sleep(for: Self.profileWaitCap)
            guard !Task.isCancelled else { return }
            profileWaitOver = true
        }
        // Above the gate, so it runs signed out too: an activity can only start in the foreground, and
        // one a previous account left must end even while Sign In is on screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await home.reconcileActivities() } }
            // The Undo timers may not run once suspended: send the waiting removals now (I1).
            if phase == .background { Task { await home.commitPendingUnfollows() } }
        }
    }

    private var signInView: some View {
        SignInView(session: home.session, onEmail: { await home.session.signInWithEmail($0) },
                   onGoogle: home.env.googleSignIn ? { await home.session.signInWithGoogle() } : nil)
    }
}
