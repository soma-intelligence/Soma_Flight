import Foundation
import Observation
import SwiftUI

/// The three sections of the home panel (the iOS sheet, the Mac sidebar), in the tab pill's order.
public enum HomeTab: String, Hashable, Sendable, CaseIterable {
    case flights, friends, passport
}

/// A Passport page that opens over the whole home (full screen on iOS, a sheet on the Mac) from one of
/// the Passport tab's cards.
public enum FullPage: String, Identifiable, Hashable, Sendable, CaseIterable {
    /// Every flight figure, from the passport card.
    case passport
    /// Time lost to delays and the latest flights, from the delays card.
    case delays
    /// Types, tails, seats and ages, from the most flown aircraft card.
    case aircraftStats

    public var id: String { rawValue }

    /// The page's title in its top bar.
    public var title: String {
        switch self {
        case .passport: "Soma Flight Passport"
        case .delays: "Delay Report"
        case .aircraftStats: "Aircraft stats"
        }
    }
}

/// What both shells share around the globe: the session, the My Flights and Passport stores, the
/// navigation of the panel, the tab, and what the globe draws and looks at. The iOS sheet and the Mac
/// sidebar only lay it out.
@MainActor @Observable
public final class HomeModel {
    /// The services, cache and airport list the stores are made from.
    public let env: AppEnvironment
    /// The signed-in account. The home watches it itself (`watchSession()`), so a sign-out or an account
    /// deletion is handled even when the shell has swapped the home for Sign In.
    public let session: SessionStore
    /// Followed flights for the current owner, replaced on every account change.
    public private(set) var myFlights: MyFlightsStore
    /// Past flights for the current owner, replaced on every account change.
    public private(set) var passport: PassportStore
    /// The Import screen's state (the export file, the calendar, a confirmation email, a CSV), rebuilt on
    /// every account change with the Passport it adds to.
    public private(set) var imports: ImportStore
    /// Imported flights too far ahead to follow yet, for the current owner; followed by `load()` once
    /// they come within two days.
    public private(set) var followLater: FollowLaterQueue
    /// The Import screen is open (from the Passport's add menu, Add Flight, or a shared email).
    public var showImport = false
    /// Settings > Notifications for the current owner, replaced on every account change. Its Reminders
    /// switch turns the local reminders on and off.
    public private(set) var notificationSettings: NotificationSettingsStore
    /// Friends, their shared flights and the invitations for the current owner, replaced on every account change.
    public private(set) var friends: FriendsStore
    /// The user's name and photo (the header's avatar, Settings > Profile, the onboarding) and friends'
    /// photos. One store for the home's life, pointed at each account by `prepareProfile()`.
    public let profile: ProfileStore
    /// An invitation link the app was opened with, waiting for the user's answer (the shells show a sheet).
    public var pendingInvite: PendingFriendInvite?
    /// A link opened before anyone was signed in, previewed once someone is.
    @ObservationIgnored private var waitingInviteToken: String?
    /// What the panel shows on top of the tab and where the globe looks.
    public let shell = ShellModel()
    /// The Airports list (the map's control tower button) and the favourite airports it and the card share.
    public let airportsList: AirportsListStore
    /// The device's connection: offline, the globe and the flight sheet show estimates and the home its
    /// calm banner (the shells put it in `\.connectivity`).
    public let connectivity: Connectivity
    /// Moves once a minute while a followed flight is estimated, so its plane advances on the globe.
    public private(set) var estimateClock = Date.now
    /// The section on show. Each tab gets back the sheet detent it was left in this session (medium the
    /// first time).
    public var tab: HomeTab = .flights {
        didSet {
            shell.showTab(tab, from: oldValue)
            if tab == .passport { showLanded() }
        }
    }
    /// The Passport page open over the home, if any.
    public var fullPage: FullPage?
    /// A boarding pass opened in the app (from Mail, Files, an airline app) waiting on the user: looking
    /// up its flight, offering to follow it, or saying why it cannot be kept (`importPass`).
    public var passImport: PassImport?
    /// The confirmation over the tab pill after a follow ("Added UA 990"); clears after `toastDuration`.
    public private(set) var toast: String?
    /// The toast on show reports a failure: red mark and an error haptic.
    public private(set) var toastIsError = false
    /// How long the toast stays.
    public static let toastDuration: Duration = .seconds(3)
    /// Waits out the toast; tests replace it to move the clock by hand.
    @ObservationIgnored var toastSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Bumped by every toast, so an older timer never clears a newer one.
    @ObservationIgnored private var toastSerial = 0
    /// The running timer of the toast on show; a newer toast cancels it.
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    /// A toast waiting for the search sheet to close (iOS covers the tab pill with it).
    public private(set) var pendingToast: String?
    @ObservationIgnored private var pendingIsError = false
    /// A search Siri, Shortcuts or a link asked for (`FlightLink.searchURL`): the iOS home opens Search
    /// with it and sets it back to nil.
    public var searchRequest: String?

    /// True while a sheet covers the tab pill (the iOS search sheet). A toast raised meanwhile waits and
    /// shows, with its full time, once this turns false. The Mac's inline search never sets it.
    public var searchOpen = false {
        didSet {
            guard oldValue, !searchOpen, let text = pendingToast else { return }
            pendingToast = nil
            let isError = pendingIsError
            pendingIsError = false
            showToast(text, isError: isError)
        }
    }
    /// The account the two stores were built for.
    @ObservationIgnored private var storesOwner: UUID?
    /// Notification permission and token registration; nil until the shell calls `attachPush`.
    @ObservationIgnored public private(set) var push: PushCoordinator?
    @ObservationIgnored private var pushInbox: PushInbox?
    /// The flight Live Activity; nil until the iOS shell calls `attachLiveActivities` (never on the Mac).
    @ObservationIgnored public private(set) var activities: FlightActivityController?
    /// The home screen and lock screen widgets' snapshot; nil until the iOS shell calls `attachWidgets`
    /// (never on the Mac, which has no widget extension).
    @ObservationIgnored public private(set) var widgets: WidgetSnapshotWriter?
    /// The Apple Watch's snapshot; nil until the iOS shell calls `attachWatch` (never on the Mac).
    @ObservationIgnored public private(set) var watch: WatchSnapshotSender?
    /// Check-in, morning and leave reminders; nil until the iOS shell calls `attachReminders`.
    @ObservationIgnored public private(set) var reminders: ReminderScheduler?
    /// How a long import says it is done while the app is in the background (`attachImportNotifier`).
    @ObservationIgnored var importNotifier: (any ImportNotifier)?
    /// One calendar event per followed flight (Settings > Calendar); nil until a shell calls `attachCalendar`.
    @ObservationIgnored public private(set) var calendar: CalendarSync?
    /// The flight sheet's "Leave by" time and the leave reminder's; nil until a shell calls `attachLeaveTimes`.
    @ObservationIgnored public private(set) var leaveTimes: LeaveTimeEstimator?
    /// `start()` has run: the stores have been built for an owner and loaded once.
    @ObservationIgnored private var started = false
    /// The owner and session state the session watch last acted on.
    @ObservationIgnored private var seenOwner: UUID?
    @ObservationIgnored private var seenAwaiting = true

    public init(env: AppEnvironment) {
        self.env = env
        connectivity = env.fixedConnectivity.map { Connectivity(online: $0) } ?? .shared
        // Nobody is signed in until the session store publishes an account; the stores are rebuilt then.
        session = env.makeSessionStore()
        myFlights = env.makeMyFlightsStore(owner: nil)
        let history = env.makePassportStore(owner: nil)
        passport = history
        let queue = FollowLaterQueue(owner: nil, defaults: env.recentsDefaults)
        followLater = queue
        imports = ImportStore(passport: history, flights: env.flights, queue: queue, calendar: nil, airport: env.lookup,
                              reference: env.reference)
        notificationSettings = NotificationSettingsStore(service: env.notificationPreferences, texts: env.textAlerts)
        friends = env.makeFriendsStore()
        profile = env.makeProfileStore()
        airportsList = AirportsListStore(service: env.airportOverview, lookup: env.lookup, reference: env.reference,
                                         favorites: AirportFavorites(defaults: env.airportFavoritesPersist ? .standard : nil,
                                                                     seed: env.airportFavoritesPersist ? [] : ["EGLL"]))
        seenAwaiting = awaitingSession
        imports = makeImports()
        watchSession()
        // The airports of followed flights (in the air or upcoming) join the list's own group.
        airportsList.tripAirports = { [weak self] in
            self?.followed.flatMap { [$0.originIcao, $0.destinationIcao] } ?? []
        }
        wireListChange()
    }

    // MARK: Session watch

    /// Follows the account from the model, not from a view: the shells show Sign In instead of the home
    /// once nobody is signed in, so a modifier on the home would never see the sign-out. An account change
    /// after `start()` runs `userChanged()` (the previous account's Live Activity ends, the token moves);
    /// before it, `start()` builds the stores itself. The stored session being read runs the activity
    /// rules (a signed-out launch ends what a previous account left on the Lock Screen).
    private func watchSession() {
        withObservationTracking {
            _ = owner
            _ = awaitingSession
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.sessionDidChange() }
        }
    }

    func sessionDidChange() {
        watchSession()
        let now = owner, awaiting = awaitingSession
        let ownerChanged = now != seenOwner, resolved = awaiting != seenAwaiting
        seenOwner = now
        seenAwaiting = awaiting
        clearWidgetsIfSignedOut()
        if ownerChanged, started {
            userChanged()
        } else if ownerChanged || resolved {
            Task { await reconcileActivities() }
        }
    }

    /// Whose profile shows: the signed-in account, or with the fakes (no sign-in) the fake account.
    public var profileOwner: UUID? {
        owner ?? (env.requiresSignIn ? nil : FakeProfileService.userId)
    }

    /// Points the profile at the account now signed in and decides whether onboarding shows. After a save
    /// the Friends tab reads the user's own card again (it shows their name).
    public func prepareProfile() async {
        profile.onSaved = { [weak self] in await self?.friends.load() }
        await profile.prepare(owner: profileOwner, appleName: session.appleName)
        #if DEBUG
        if UserDefaults.standard.string(forKey: "onboarding") != nil { profile.forceOnboarding() }
        #endif
    }

    /// The account the stores read and write for.
    public var owner: UUID? { session.session?.userId }

    /// The shells show Sign In instead of the home: the backend needs an account and nobody is signed in.
    public var needsSignIn: Bool { env.requiresSignIn && session.isResolved && session.session == nil }

    /// The backend needs an account and the stored session has not been read yet (a launch placeholder).
    public var awaitingSession: Bool { env.requiresSignIn && !session.isResolved }

    /// Followed flights, the ones in the air first.
    public var followed: [Flight] { myFlights.live + myFlights.upcoming }

    /// Arcs, planes and pins for the tab on show. Built again only when the flights behind it change:
    /// each arc is a great circle from the Rust core, and the shell reads this on every layout pass
    /// (a detent settling, a toast), which must not rebuild the globe's overlays.
    public var globe: GlobeContent {
        // The Airports list (and an airport opened from it) shows the list's airports as status dots.
        if shell.path.first == .airports { return airportsList.globe }
        let key: GlobeKey = switch tab {
        case .flights: .flights(followed, estimating: estimateTick)
        case .friends: .friends(friends.flights)
        case .passport: .passport(passport.flights)
        }
        if let globeCache, globeCache.key == key { return globeCache.content }
        let content: GlobeContent = switch key {
        case .flights(let flights, _): .followed(flights, lookup: env.lookup, online: connectivity.isOnline, now: estimateClock)
        case .friends(let flights): .friends(flights, lookup: env.lookup)
        case .passport(let flights): .past(flights, lookup: env.lookup)
        }
        globeCache = (key, content)
        return content
    }

    private enum GlobeKey: Equatable {
        case flights([Flight], estimating: Date?)
        case friends([FriendFlight])
        case passport([PastFlight])
    }

    @ObservationIgnored private var globeCache: (key: GlobeKey, content: GlobeContent)?

    /// The minute the globe's estimated planes are drawn for, nil while every followed flight is live (so the
    /// globe is not rebuilt for nothing). Reading it starts the minute tick.
    private var estimateTick: Date? {
        let online = connectivity.isOnline, now = estimateClock
        guard followed.contains(where: { $0.estimate(online: online, now: now, lookup: env.lookup) != nil }) else { return nil }
        startEstimateClock()
        return now
    }

    @ObservationIgnored private var estimateTimer: Task<Void, Never>?

    private func startEstimateClock() {
        guard estimateTimer == nil else { return }
        estimateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.estimateClock = .now
            }
        }
    }

    /// One flight alone on the globe while it is the screen on top of the panel (followed or past): its
    /// arc, its two airports and its plane. Nil shows everything.
    public var isolation: GlobeIsolation? {
        guard case .route(let route) = focus else { return nil }
        let codes: [String]
        var plane: FlightAnnotationModel?
        switch shell.path.last {
        case .flight(let id):
            let flight = followed.first { $0.id == id }
            codes = flight.map { [$0.originIcao, $0.destinationIcao] } ?? []
            plane = flight.flatMap { GlobeContent.plane(for: $0, lookup: env.lookup, online: connectivity.isOnline, now: estimateClock) }
        case .friendFlight(let ff):
            codes = [ff.flight.originIcao, ff.flight.destinationIcao]
            plane = FlightAnnotationModel(flight: ff.flight, isFriend: true)
        case .pastFlight(let flight):
            codes = [flight.originIcao, flight.destinationIcao]
        default:
            return nil
        }
        var airports = codes.compactMap { env.lookup($0) }
        // A flight that left the list: its ends are found on the globe by their place.
        if airports.isEmpty {
            airports = globe.airports.filter { GlobeIsolation.same($0.coordinate, route.from) || GlobeIsolation.same($0.coordinate, route.to) }
        }
        return GlobeIsolation(route: route, airports: airports, plane: plane)
    }

    /// Where the camera looks: the screen on top of the panel, or the whole globe.
    public var focus: GlobeFocus? {
        shell.focus(route: route(for:), airport: env.lookup)
    }

    private func route(for id: Flight.ID) -> Route? {
        if let f = followed.first(where: { $0.id == id }) { return GlobeContent.route(for: f, lookup: env.lookup) }
        return friends.friendFlight(id).flatMap { Self.friendRoute($0, lookup: env.lookup) }
    }

    /// A friend's flight's arc, dashed in the friends colour.
    static func friendRoute(_ ff: FriendFlight, lookup: (String) -> Airport?) -> Route? {
        GlobeContent.route(for: ff.flight, lookup: lookup).map {
            Route(id: "friend-\($0.id)", from: $0.from, to: $0.to, level: $0.level, isPast: false, isFriend: true)
        }
    }

    // MARK: Navigation

    /// Opens a flight's detail as the only screen, keeping its arc for the camera.
    public func open(flight: Flight) {
        shell.open(flight: flight.id, route: GlobeContent.route(for: flight, lookup: env.lookup))
    }

    /// Opens a Passport flight with the flight sheet, its arc drawn as a past route.
    public func open(past flight: PastFlight) {
        let route = GlobeContent.route(for: flight.asFlight, lookup: env.lookup)
            .map { Route(id: $0.id, from: $0.from, to: $0.to, level: .onTime, isPast: true) }
        shell.open(past: flight, route: route)
    }

    /// Opens a friend's page.
    public func open(friend id: UUID) { shell.open(friend: id) }

    /// Opens a friend's flight in the flight sheet, read only, its arc drawn in the friends colour.
    public func open(friendFlight ff: FriendFlight) {
        shell.open(friendFlight: ff, route: Self.friendRoute(ff, lookup: env.lookup))
    }

    /// Opens the Airports list (the map's control tower button).
    public func openAirports() { shell.openAirports() }

    /// Codes arrive as ICAO from the globe and as either code from the screens; the stack keys on ICAO.
    public func open(airport code: String) {
        shell.open(airport: env.lookup(code)?.id ?? code)
    }

    /// A pin or a plane tapped on the globe.
    public func select(_ picked: GlobeSelection) {
        switch picked {
        case .airport(let code): open(airport: code)
        case .flight(let id):
            // The Friends tab draws friends' planes; the other tabs the user's own.
            if tab == .friends, let ff = friends.friendFlight(id) {
                open(friendFlight: ff)
            } else if let f = followed.first(where: { $0.id == id }) {
                open(flight: f)
            }
        }
    }

    // MARK: Loading

    /// Starts following the session, then loads both lists and live updates. Call once, when the home
    /// appears.
    /// The home may first appear after a sign-in it did not see (Sign In was on screen): the stores are
    /// rebuilt then for the account signed in now.
    public func start() async {
        // Search's suggestion lists fold some 5,000 names once: build them now, off the main thread, so the
        // first keystroke in Search does not wait for it.
        Task.detached(priority: .utility) { _ = SearchSuggester.bundled() }
        session.startIfNeeded()
        started = true
        seenOwner = owner
        if storesOwner != owner { rebuildStores() }
        // A tap that launched the app opens first, without waiting for the lists.
        await processInbox()
        await load()
        // The notification settings call can take long or never answer (seen on simulators): it runs on
        // its own and start never waits for it.
        if let push { Task { await push.refresh() } }
        await processInbox()
        // A confirmation email shared to the app while it was closed.
        takeSharedEmails()
        await reconcileActivities()
    }

    /// Loads both lists for the current owner and starts My Flights' live updates.
    public func load() async {
        await myFlights.load()
        myFlights.startUpdates()
        await passport.load()
        showLanded()
        if !env.requiresSignIn || owner != nil {
            await notificationSettings.load()
            await friends.load()
            await profile.loadFriendPhotos()
            await previewWaitingInvite()
            await followWaiting()
        }
    }

    /// Runs when the session's user changes (the session watch calls it): clears the panel's stack and
    /// rebuilds both stores for the new owner, then loads them. The session store has already handed the device's saved data to the new user (or to nobody)
    /// before publishing it, so the rebuilt stores never read the previous account's.
    public func userChanged() {
        shell.reset()
        fullPage = nil
        // The previous account's flights leave the widgets now; the new account's load writes its own.
        widgets?.clear()
        watch?.clear()
        rebuildStores()
        // Signed out too (nil): a sign-in as the same account later registers the token again.
        push?.accountChanged(owner: owner)
        // The previous account's reminders go; the new account's list schedules its own once loaded.
        reminders?.scheduleSync([])
        calendar?.scheduleSync([])
        Task {
            // The previous account's activity goes, whoever signs in next (nobody, at sign-out).
            await reconcileActivities()
            await load()
            await processInbox()
        }
    }

    private func rebuildStores() {
        storesOwner = owner
        // A pushed update still reaching the old store must not restart the previous account's activity.
        myFlights.onListChange = nil
        myFlights = env.makeMyFlightsStore(owner: owner)
        passport = env.makePassportStore(owner: owner)
        followLater.adopt(owner: owner)
        imports = makeImports()
        showImport = false
        notificationSettings = NotificationSettingsStore(service: env.notificationPreferences, texts: env.textAlerts)
        friends = env.makeFriendsStore()
        pendingInvite = nil
        wireListChange()
    }

    // MARK: Friends

    /// Handles an invitation link (`https://somalabs.me/i/<token>`, `somaflight://i/<token>`): opens the
    /// Friends tab and asks the user to accept or decline. Signed out, it waits for a sign-in. False for any
    /// other URL.
    @discardableResult
    public func handleInvite(url: URL) async -> Bool {
        guard let token = FriendLink.token(from: url) else { return false }
        waitingInviteToken = token
        await previewWaitingInvite()
        return true
    }

    private func previewWaitingInvite() async {
        guard let token = waitingInviteToken, !env.requiresSignIn || owner != nil else { return }
        waitingInviteToken = nil
        tab = .friends
        shell.reset()
        pendingInvite = PendingFriendInvite(token: token)
        let preview = await friends.preview(token: token)
        if pendingInvite?.token == token { pendingInvite = preview }
    }

    /// Answers the pending invitation. Returns the error, nil when it went through (the sheet closes then).
    public func answerInvite(accept: Bool) async -> APIError? {
        guard let invite = pendingInvite else { return nil }
        let error = await friends.respond(token: invite.token, accept: accept)
        if error == nil {
            pendingInvite = nil
            if accept, let name = invite.preview?.name { showToast("You and \(name) are friends") }
        }
        return error
    }

    /// The Import screen's store over the Passport and the calendar sync of now.
    private func makeImports() -> ImportStore {
        let store = ImportStore(passport: passport, flights: env.flights, queue: followLater, calendar: calendar,
                                followed: { [weak self] in self?.followed ?? [] }, airport: env.lookup, reference: env.reference,
                                onFollowed: { [weak self] _ in await self?.didFollow() })
        store.notifier = importNotifier
        return store
    }

    // MARK: Live Activity

    /// Hands the flight Live Activity to the home: from now on every trusted change of My Flights
    /// (load, pushed update, unfollow) re-runs its start and end rules. Call once, before `start()`.
    public func attachLiveActivities(_ controller: FlightActivityController) {
        activities = controller
        wireListChange()
    }

    /// Hands the widgets' snapshot to the home: from now on every trusted change of My Flights rewrites
    /// it. Call once, before `start()`.
    public func attachWidgets(_ writer: WidgetSnapshotWriter) {
        widgets = writer
        wireListChange()
    }

    /// Hands the Apple Watch's snapshot to the home: it follows the widgets (every trusted change of My
    /// Flights, cleared when signed out) and reads the boarding passes of the account signed in now.
    /// Call once, before `start()`.
    public func attachWatch(_ sender: WatchSnapshotSender) {
        watch = sender
        sender.passes = { [weak self] id in
            guard let self else { return nil }
            return await self.env.passes.vault(for: self.owner).pass(for: id)
        }
        wireListChange()
    }

    /// Hands the local reminders to the home: from now on every trusted change of My Flights schedules,
    /// rewrites or removes them, and the Reminders switch turns them on and off. Call once, before
    /// `start()`.
    public func attachReminders(_ scheduler: ReminderScheduler) {
        reminders = scheduler
        wireListChange()
    }

    /// Hands the calendar sync to the home: from now on every trusted change of My Flights adds, rewrites
    /// or removes its events. Call once, before `start()`.
    public func attachCalendar(_ sync: CalendarSync) {
        calendar = sync
        imports = makeImports()
        wireListChange()
    }

    /// Hands the leave time estimator to the home: the leave reminder uses its computed times, and a new
    /// measure re-runs the reminders. Call once, before `start()`.
    public func attachLeaveTimes(_ estimator: LeaveTimeEstimator) {
        leaveTimes = estimator
        wireListChange()
    }

    /// Points My Flights' change callback at the Live Activity, the widgets, the watch, the reminders and
    /// the calendar, whichever are attached, the Notifications screen at the reminders, and the leave times
    /// at the reminders.
    private func wireListChange() {
        let activities = activities, widgets = widgets, reminders = reminders, watch = watch, calendar = calendar
        if let reminders {
            notificationSettings.onChange = { prefs in reminders.enabled = prefs.reminders }
            if let leaveTimes {
                reminders.leaveTime = { leaveTimes.leaveTime(for: $0) }
                leaveTimes.onChange = { reminders.resync() }
            }
        }
        myFlights.onListChange = { [weak self] list in
            self?.passport.showLanded(list)
            // Scheduled synchronously, so each runs the lists in the order the store changed.
            activities?.scheduleSync(list)
            reminders?.scheduleSync(list)
            calendar?.scheduleSync(list)
            // Signed out, the widgets stay empty whatever a late load returns.
            guard let self, !(self.env.requiresSignIn && self.owner == nil) else { return }
            widgets?.write(list)
            watch?.write(list)
        }
    }

    /// Puts the followed flights that are over (`LandedFlights`) in Passport until the server archives
    /// them. Runs after each load, on every change of My Flights and when the Passport tab opens.
    public func showLanded(now: Date = .now) {
        passport.showLanded(myFlights.flights, now: now)
    }

    /// Signed out, the widgets and the watch show nothing: a later account must never see the previous
    /// one's flights.
    private func clearWidgetsIfSignedOut() {
        guard !awaitingSession, env.requiresSignIn, owner == nil else { return }
        widgets?.clear()
        watch?.clear()
    }

    /// Settles the activities for the account signed in now: signed out ends them all, otherwise the
    /// controller adopts the owner (ending any other account's) and re-runs its rules on the list when
    /// the list is trusted (loaded, not offline). Waits while the stored session is still being read.
    /// Called at start, on every account change, when the session resolves (the session watch) and when
    /// the app becomes active (`SignInGate`).
    public func reconcileActivities() async {
        guard let activities, !awaitingSession else { return }
        if env.requiresSignIn, owner == nil {
            await activities.endAll()
            return
        }
        await activities.adopt(owner: owner)
        if myFlights.hasLoaded, myFlights.error == nil { await activities.sync(followed) }
    }

    // MARK: Notifications

    /// Wires the shell's notification plumbing: the app delegate's inbox and the call that asks the OS for
    /// a device token. Call once, before `start()`.
    /// `enabled` defaults to the platform's (`PushCoordinator.platformSendsPushes`); tests force it.
    public func attachPush(inbox: PushInbox, authorizer: any NotificationAuthorizer = SystemNotificationAuthorizer(),
                           enabled: Bool = PushCoordinator.platformSendsPushes,
                           registerForRemote: @escaping @MainActor () -> Void) {
        pushInbox = inbox
        push = PushCoordinator(push: env.push, authorizer: authorizer, enabled: enabled, registerForRemote: registerForRemote)
    }

    /// Changes whenever the app delegate leaves something in the inbox; the shells watch it.
    public var pushSerial: Int { pushInbox?.serial ?? 0 }

    /// Nothing can be opened or registered before the account the backend needs is signed in.
    private var canHandlePush: Bool { !env.requiresSignIn || owner != nil }

    /// A follow went through: says so over the tab pill, reloads My Flights, then (the first time) asks
    /// for notifications.
    public func didFollow(_ flight: Flight? = nil) async {
        if let flight {
            showToast("Added \(Format.ident(flight.ident))")
            // Followed by hand while waiting in the queue: it is no longer planned.
            for u in followLater.items where PlannedFlight.matches(u, flight, reference: env.reference, airport: env.lookup) {
                followLater.remove(u.id)
            }
        }
        await myFlights.load()
        await push?.didFollow()
    }

    /// Shows `text` over the tab pill for `toastDuration` and has VoiceOver read it; a newer toast replaces
    /// it and restarts the wait. While `searchOpen`, it waits for the sheet to close instead.
    public func showToast(_ text: String, isError: Bool = false) {
        if searchOpen {
            pendingToast = text
            pendingIsError = isError
            return
        }
        toastIsError = isError
        toastSerial += 1
        let serial = toastSerial, sleep = toastSleep
        toast = text
        AccessibilityNotification.Announcement(text).post()
        toastTimer?.cancel()
        toastTimer = Task { [weak self] in
            do { try await sleep(Self.toastDuration) } catch { return }
            guard let self, self.toastSerial == serial else { return }
            self.toast = nil
        }
    }

    /// The airlines and airports the Add Flight sheet offers first, from the whole flight history (every
    /// year, whatever the Passport shows) and the followed flights.
    public var frequent: [FrequentItem] {
        FrequentlyUsed.compute(past: passport.allFlights, followed: followed, reference: env.reference,
                               lookup: env.lookup)
    }

    /// Acts on what the app delegate left in the inbox: registers the device token, opens the flight a
    /// tapped notification names, and refreshes the one a foreground notification names. Items wait
    /// while nobody is signed in. Call after `start()` and whenever the inbox's `serial` changes.
    public func processInbox() async {
        guard let inbox = pushInbox, let push else { return }
        push.accountChanged(owner: owner)
        guard canHandlePush else { return }
        if let token = inbox.deviceToken { await push.register(token: token) }
        if inbox.takeForegroundFlight() != nil { await myFlights.load() }
        if let id = inbox.takePendingFlight(), await open(flightID: id) == .failed {
            // Offline or a server error: the next start, sign-in or notification tries again.
            inbox.keepPending(id)
        }
    }

    public enum FlightOpenResult: Sendable { case opened, notFound, failed }

    /// Opens a flight's detail. One that is not in My Flights is fetched by id first, so a notification
    /// for a flight this device has not loaded yet still opens. `.notFound` is final; `.failed` is worth
    /// another try.
    @discardableResult
    public func open(flightID id: Flight.ID) async -> FlightOpenResult {
        if let f = followed.first(where: { $0.id == id }) {
            open(flight: f)
            return .opened
        }
        do {
            open(flight: try await env.flights.flight(id))
            return .opened
        } catch {
            return error == .notFound ? .notFound : .failed
        }
    }

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

    // MARK: Screenshot runs

    #if DEBUG
    /// `-liveActivityPush <path>`: once the activity rules have run on the loaded list, applies the
    /// Live Activity push in that file (push-sender's JSON) as ActivityKit would. `simctl push` only
    /// delivers alert pushes, so this stands in for it on the simulator.
    public func applyLiveActivityLaunchArguments(_ args: UserDefaults = .standard) async {
        guard let activities, let path = args.string(forKey: "liveActivityPush"),
              let data = FileManager.default.contents(atPath: path) else { return }
        await reconcileActivities()
        await activities.applyDebugPush(data)
    }
    #endif

    /// Opens a screen without taps, for screenshot runs: `-toast <text>`, `-tab passport`, `-open flight` (the first one
    /// in the air) or `-open airport:KAUS`, `-fullPage passport|delays|aircraftStats` (the Passport tab
    /// with that page over it), `-year 2025` (the Passport's year), and on iOS `-detent expanded`,
    /// `-detent medium` or `-detent collapsed` (`large` and `small` still work). Call after the first load, from DEBUG builds only.
    public func applyLaunchArguments(_ args: UserDefaults = .standard) {
        // `-toast "Added UA 990"` holds that toast on screen (no timer) for a capture.
        if let text = args.string(forKey: "toast") { toast = text }
        if let tab = args.string(forKey: "tab").flatMap(HomeTab.init(rawValue:)) { self.tab = tab }
        // `-open friend` opens the first friend's page, `-open friendFlight` their first flight.
        if args.string(forKey: "open") == "friend", let f = friends.friends.first {
            tab = .friends
            open(friend: f.id)
        } else if args.string(forKey: "open") == "friendFlight", let ff = friends.flights.first {
            tab = .friends
            open(friendFlight: ff)
        }
        if args.object(forKey: "year") != nil { passport.year = args.integer(forKey: "year") }
        if let page = args.string(forKey: "fullPage").flatMap(FullPage.init(rawValue:)) {
            tab = .passport
            fullPage = page
        }
        switch args.string(forKey: "detent") {
        case "large", "expanded": shell.detent = .expanded
        case "medium": shell.detent = .medium
        case "small", "collapsed": shell.detent = .collapsed
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
/// binding for Settings. The iOS app and both Mac scenes read the same keys, so they stay in step. The
/// clock lives in the App Group's defaults on iOS (`SharedSettings`), where the Live Activity reads it.
/// Main actor only: the setter writes through `@AppStorage`, which views read on the main actor.
@MainActor @propertyWrapper
public struct StoredUnits: DynamicProperty {
    @AppStorage("units.distance") private var distance: DistanceUnit = .km
    @AppStorage(SharedSettings.clock24Key, store: SharedSettings.defaults) private var clock24 = true

    public init() {}

    public var wrappedValue: Units {
        get { Units(distance: distance, clock: clock24 ? .h24 : .h12) }
        nonmutating set { distance = newValue.distance; clock24 = newValue.clock == .h24 }
    }

    public var projectedValue: Binding<Units> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
