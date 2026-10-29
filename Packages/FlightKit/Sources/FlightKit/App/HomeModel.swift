import Foundation
import Observation
import SwiftUI

/// The two sections of the home panel (the iOS sheet, the Mac sidebar).
public enum HomeTab: String, Hashable, Sendable {
    case flights, passport
}

/// What both shells share around the globe: the session, the My Flights and Passport stores, the
/// navigation of the panel, the tab, and what the globe draws and looks at. The iOS sheet and the Mac
/// sidebar only lay it out.
@MainActor @Observable
public final class HomeModel {
    /// The services, cache and airport list the stores are made from.
    public let env: AppEnvironment
    /// The signed-in account; the shells rebuild the stores (`userChanged()`) when its user changes.
    public let session: SessionStore
    /// Followed flights for the current owner, replaced on every account change.
    public private(set) var myFlights: MyFlightsStore
    /// Past flights for the current owner, replaced on every account change.
    public private(set) var passport: PassportStore
    /// What the panel shows on top of the tab and where the globe looks.
    public let shell = ShellModel()
    /// The section on show.
    public var tab: HomeTab = .flights
    /// The account the two stores were built for.
    @ObservationIgnored private var storesOwner: UUID?
    /// Notification permission and token registration; nil until the shell calls `attachPush`.
    @ObservationIgnored public private(set) var push: PushCoordinator?
    @ObservationIgnored private var pushInbox: PushInbox?

    public init(env: AppEnvironment) {
        self.env = env
        // Nobody is signed in until the session store publishes an account; the stores are rebuilt then.
        session = env.makeSessionStore()
        myFlights = env.makeMyFlightsStore(owner: nil)
        passport = env.makePassportStore(owner: nil)
    }

    /// The account the stores read and write for.
    public var owner: UUID? { session.session?.userId }

    /// The shells show Sign In instead of the home: the backend needs an account and nobody is signed in.
    public var needsSignIn: Bool { env.requiresSignIn && session.isResolved && session.session == nil }

    /// The backend needs an account and the stored session has not been read yet (a launch placeholder).
    public var awaitingSession: Bool { env.requiresSignIn && !session.isResolved }

    /// Followed flights, the ones in the air first.
    public var followed: [Flight] { myFlights.live + myFlights.upcoming }

    /// Arcs, planes and pins for the tab on show.
    public var globe: GlobeContent {
        switch tab {
        case .flights: .followed(followed, lookup: env.lookup)
        case .passport: .past(passport.flights, lookup: env.lookup)
        }
    }

    /// Where the camera looks: the screen on top of the panel, or the whole globe.
    public var focus: GlobeFocus? {
        shell.focus(route: route(for:), airport: env.lookup)
    }

    private func route(for id: Flight.ID) -> Route? {
        followed.first { $0.id == id }.flatMap { GlobeContent.route(for: $0, lookup: env.lookup) }
    }

    // MARK: Navigation

    /// Opens a flight's detail as the only screen, keeping its arc for the camera.
    public func open(flight: Flight) {
        shell.open(flight: flight.id, route: GlobeContent.route(for: flight, lookup: env.lookup))
    }

    /// Codes arrive as ICAO from the globe and as either code from the screens; the stack keys on ICAO.
    public func open(airport code: String) {
        shell.open(airport: env.lookup(code)?.id ?? code)
    }

    /// A pin or a plane tapped on the globe.
    public func select(_ picked: GlobeSelection) {
        switch picked {
        case .airport(let code): open(airport: code)
        case .flight(let id): if let f = followed.first(where: { $0.id == id }) { open(flight: f) }
        }
    }

    // MARK: Loading

    /// Starts following the session, then loads both lists and live updates. Call once, when the home
    /// appears.
    /// The home may first appear after a sign-in it did not see (Sign In was on screen): the stores are
    /// rebuilt then for the account signed in now.
    public func start() async {
        session.startIfNeeded()
        if storesOwner != owner { rebuildStores() }
        await load()
        await push?.refresh()
        await processInbox()
    }

    /// Loads both lists for the current owner and starts My Flights' live updates.
    public func load() async {
        await myFlights.load()
        myFlights.startUpdates()
        await passport.load()
    }

    /// Call when the session's user changes: clears the panel's stack and rebuilds both stores for the
    /// new owner, then loads them. The session store has already handed the device's saved data to the new user (or to nobody)
    /// before publishing it, so the rebuilt stores never read the previous account's.
    public func userChanged() {
        shell.reset()
        rebuildStores()
        Task {
            await load()
            await processInbox()
        }
    }

    private func rebuildStores() {
        storesOwner = owner
        myFlights = env.makeMyFlightsStore(owner: owner)
        passport = env.makePassportStore(owner: owner)
    }

    // MARK: Notifications

    /// Wires the shell's notification plumbing: the app delegate's inbox and the call that asks the OS for
    /// a device token. Call once, before `start()`.
    public func attachPush(inbox: PushInbox, authorizer: any NotificationAuthorizer = SystemNotificationAuthorizer(),
                           registerForRemote: @escaping @MainActor () -> Void) {
        pushInbox = inbox
        push = PushCoordinator(push: env.push, authorizer: authorizer, registerForRemote: registerForRemote)
    }

    /// Changes whenever the app delegate leaves something in the inbox; the shells watch it.
    public var pushSerial: Int { pushInbox?.serial ?? 0 }

    /// Nothing can be opened or registered before the account the backend needs is signed in.
    private var canHandlePush: Bool { !env.requiresSignIn || owner != nil }

    /// A follow went through: reload My Flights, then (the first time) ask for notifications.
    public func didFollow() async {
        await myFlights.load()
        await push?.didFollow()
    }

    /// Acts on what the app delegate left in the inbox: registers the device token, opens the flight a
    /// tapped notification names, and refreshes the one a foreground notification names. Items wait
    /// while nobody is signed in. Call after `start()` and whenever the inbox's `serial` changes.
    public func processInbox() async {
        guard let inbox = pushInbox, let push, canHandlePush else { return }
        push.accountChanged(owner: owner)
        if let token = inbox.deviceToken { await push.register(token: token) }
        if inbox.takeForegroundFlight() != nil { await myFlights.load() }
        if let id = inbox.takePendingFlight() { await open(flightID: id) }
    }

    /// Opens a flight's detail. One that is not in My Flights is fetched by id first, so a notification
    /// for a flight this device has not loaded yet still opens. False when it cannot be fetched.
    @discardableResult
    public func open(flightID id: Flight.ID) async -> Bool {
        if let f = followed.first(where: { $0.id == id }) {
            open(flight: f)
            return true
        }
        guard let f = try? await env.flights.flight(id) else { return false }
        open(flight: f)
        return true
    }

    // MARK: Screenshot runs

    #if DEBUG
    /// Debug launch arguments for the notification flow: `-pushFlight <uuid>` runs the handler a tap on a
    /// notification carrying `{"flightId": <uuid>}` runs, `-requestPushPermission YES` runs what the first
    /// follow runs. (A JSON argument does not survive UserDefaults' plist parsing of launch arguments.)
    public func applyPushLaunchArguments(_ args: UserDefaults = .standard) async {
        if args.bool(forKey: "requestPushPermission") { await push?.didFollow() }
        if let id = args.string(forKey: "pushFlight"), pushInbox?.receiveTap(["flightId": id]) == true {
            await processInbox()
        }
    }
    #endif

    /// Opens a screen without taps, for screenshot runs: `-tab passport`, `-open flight` (the first one
    /// in the air) or `-open airport:KAUS`, and on iOS `-detent large` or `-detent small`. Call after the
    /// first load, from DEBUG builds only.
    public func applyLaunchArguments(_ args: UserDefaults = .standard) {
        if let tab = args.string(forKey: "tab").flatMap(HomeTab.init(rawValue:)) { self.tab = tab }
        switch args.string(forKey: "detent") {
        case "large": shell.detent = .large
        case "small": shell.detent = ShellModel.collapsed
        default: break
        }
        guard let target = args.string(forKey: "open") else { return }
        if target == "flight", let f = myFlights.live.first ?? myFlights.upcoming.first {
            open(flight: f)
        } else if target.hasPrefix("airport:") {
            open(airport: String(target.dropFirst("airport:".count)))
        }
    }
}

/// Distance and clock units kept in the app's defaults, as one `Units` value for the screens and a
/// binding for Settings. The iOS app and both Mac scenes read the same keys, so they stay in step.
/// Main actor only: the setter writes through `@AppStorage`, which views read on the main actor.
@MainActor @propertyWrapper
public struct StoredUnits: DynamicProperty {
    @AppStorage("units.distance") private var distance: DistanceUnit = .km
    @AppStorage("units.clock24") private var clock24 = true

    public init() {}

    public var wrappedValue: Units {
        get { Units(distance: distance, clock: clock24 ? .h24 : .h12) }
        nonmutating set { distance = newValue.distance; clock24 = newValue.clock == .h24 }
    }

    public var projectedValue: Binding<Units> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
