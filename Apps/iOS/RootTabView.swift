import FlightKit
import MapKit
import SwiftUI

/// The iOS home: the satellite globe full screen, a resizable sheet over it holding My Flights or
/// Passport, a floating tab pill with a round search button, and a gear for Settings. Flights and
/// airports open as cards sliding up inside the sheet while the globe moves onto them; an open flight
/// is drawn alone on the globe. The state is FlightKit's `HomeModel`, shared with the Mac sidebar.
struct RootTabView: View {
    @State private var home: HomeModel
    @State private var selection: GlobeSelection?
    @State private var labels = true
    @State private var threeD = false
    @State private var showSearch = false
    /// Where a Passport card zooms into its full page.
    @Namespace private var pageZoom
    /// Ties the compass under the map buttons to the globe: the map's own safe area moves with the sheet,
    /// so MapKit's compass would move with it.
    @Namespace private var mapScope
    @State private var showSettings = false
    /// The screen and its safe areas, which place the sheet's three detents.
    @State private var geometry = SheetGeometry.standard
    @StoredUnits private var units: Units
    @Environment(\.scenePhase) private var scenePhase

    init(home: HomeModel) {
        _home = State(initialValue: home)
    }

    private var env: AppEnvironment { home.env }
    private var shell: ShellModel { home.shell }

    var body: some View {
        HomeGlobe(home: home, selection: $selection, labels: labels, threeD: threeD, geometry: geometry,
                  controlsScope: mapScope)
            .background { Color.black.ignoresSafeArea() }
            // The whole screen, with the safe areas it ignores still reported: the detents' frame.
            .background {
                Color.clear
                    .onGeometryChange(for: SheetGeometry.self) { proxy in
                        SheetGeometry(screenHeight: proxy.size.height, safeTop: proxy.safeAreaInsets.top,
                                      safeBottom: proxy.safeAreaInsets.bottom)
                    } action: { geometry = $0 }
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) { mapButtons }
            // Airports: its own round button under the map controls (kept apart from mapButtons).
            .overlay(alignment: .topTrailing) {
                AirportsMapButton { home.openAirports() }.padding(.trailing, 12).padding(.top, 8 + 89 + 10)
            }
            .mapScope(mapScope)
            .sheet(isPresented: .constant(true)) { sheet }
            .onChange(of: selection) { _, picked in
                guard let picked else { return }
                selection = nil
                home.select(picked)
            }
            // Account changes and the Live Activity rules run above this view (HomeModel's session watch
            // and SignInGate), so they still run once Sign In has replaced it.
            .task {
                await home.start()
                #if DEBUG
                home.applyLaunchArguments()
                // Screenshot runs: `-sheet settings` or `-sheet search` opens that sheet over the home.
                switch UserDefaults.standard.string(forKey: "sheet") {
                case "settings": showSettings = true
                case "search": showSearch = true
                default: break
                }
                await home.applyPushLaunchArguments()
                await home.applyLiveActivityLaunchArguments()
                #endif
            }
            .onChange(of: home.pushSerial) { Task { await home.processInbox() } }
            // A notification opens a flight under Search or Settings: they close so it shows.
            .onChange(of: shell.path) { _, path in
                if !path.isEmpty { showSearch = false; showSettings = false }
            }
            // The search sheet covers the tab pill: a follow's toast waits for it to close.
            .onChange(of: showSearch) { _, open in home.searchOpen = open }
            // A confirmation email shared to the app from Mail (the share extension's inbox).
            .onChange(of: scenePhase) { _, phase in if phase == .active { home.takeSharedEmails() } }
            .environment(\.units, units)
            .environment(\.connectivity, home.connectivity)
    }

    // MARK: Sheet

    private var sheet: some View {
        @Bindable var shell = home.shell
        // Each screen slides up over the one below as a card, and its X drops it back down.
        // A Passport past flight zooms out of its row and back into it; the other cards crossfade.
        return CardStack(path: shell.path, onPop: shell.close, zoomID: \.zoomID) {
            tabRoot
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .environment(\.fullPageZoom, pageZoom)
        .presentationDetents(geometry.presentationDetents, selection: Binding(
            get: { geometry.presentationDetent(for: shell.detent) },
            set: { shell.detent = geometry.detent(for: $0) }))
        // The grab handle shows the sheet can be dragged between its three heights (owner's call, 2026-11-01).
        .presentationDragIndicator(.visible)
        // Below the top height a swipe raises the sheet instead of scrolling its page; the page scrolls only
        // once the sheet is fully up (owner's call, 2026-11-01).
        .presentationContentInteraction(.resizes)
        .presentationBackgroundInteraction(.enabled)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSearch) {
            SearchSheet(env: env, alreadyFollowed: FollowedFlights(home.followed), frequent: home.frequent,
                        known: KnownFlight.list(followed: home.followed, past: home.passport.flights),
                        onFollowed: { flight in Task { await home.didFollow(flight) } },
                        onImport: { showSearch = false; home.showImport = true },
                        onAirport: { code in showSearch = false; home.open(airport: code) })
                .environment(\.units, units)
        }
        // A Passport card's page covers the whole screen, over the home sheet.
        .fullScreenCover(item: $home.fullPage) { page in
            FullPageView(page: page, store: home.passport, lookup: env.lookup) { home.fullPage = nil }
                .environment(\.units, units)
                .fullPageZoom(page, in: pageZoom)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: home.session, units: $units, history: home.env.history,
                          onDeleteAccount: { await home.session.deleteAccount() },
                          notifications: home.notificationSettings, calendar: home.calendar, friends: home.friends,
                          profile: home.profile)
                .environment(\.units, units)
        }
        // An invitation link the app was opened with: accept or decline.
        .sheet(item: $home.pendingInvite) { invite in
            FriendInviteSheet(invite: invite, onAnswer: { await home.answerInvite(accept: $0) },
                              onClose: { home.pendingInvite = nil })
                .presentationDetents([.medium])
        }
        // A boarding pass opened from Mail, Files or an airline app.
        .passImportSheet(home)
        // The Import screen, from the Passport's add menu, Add Flight or a shared email.
        .importSheet(home, suspended: showSearch)
        .environment(\.units, units)
    }

    /// VoiceOver's "Expand" and "Collapse" on the tab's title, one detent at a time.
    private var detentActions: SheetDetentActions {
        let shell = home.shell
        return SheetDetentActions(
            expand: shell.detent.raised.map { up in { withAnimation(.smooth) { shell.detent = up } } },
            collapse: shell.detent.lowered.map { down in { withAnimation(.smooth) { shell.detent = down } } })
    }

    private var tabRoot: some View {
        @Bindable var home = home
        return HomeSheetBody(tab: $home.tab, onSearch: { showSearch = true }) {
            tabScreen
                // Only on the tab roots: the modal sheets (Settings, Search) have titles of their own.
                .environment(\.sheetDetentActions, detentActions)
                .environment(\.sheetDetent, shell.detent)
                .overlay(alignment: .topTrailing) {
                    ProfileButton(profile: home.profile) { showSettings = true }
                        .padding(.top, 19)
                        .padding(.trailing, 16)
                }
        } toast: {
            ToastSlot(text: home.toast)
        }
    }

    @ViewBuilder private var tabScreen: some View {
        switch home.tab {
        case .flights:
            MyFlightsView(store: home.myFlights, onSelect: home.open(flight:), onSearch: { showSearch = true },
                          lookup: env.lookup)
        case .friends:
            FriendsView(store: home.friends, onOpenFriend: home.open(friend:), lookup: env.lookup)
        case .passport:
            PassportView(store: home.passport, lookup: env.lookup, onOpen: { home.fullPage = $0 },
                             onOpenFlight: home.open(past:), onImport: { home.showImport = true })
        }
    }

    // MARK: Map controls

    /// The 3D switch over the place-name switch in one glass capsule, as Maps groups its controls. MapKit's
    /// compass shows under it only while the globe is turned. Shown over the map in the medium and
    /// collapsed detents; expanded, the sheet covers the map and they fade out.
    private var mapButtons: some View {
        VStack(spacing: 0) {
            Button { threeD.toggle() } label: {
                Text(threeD ? "2D" : "3D")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(threeD ? "Flat View" : "3D View")
            Rectangle().fill(.white.opacity(0.18)).frame(width: 24, height: 1)
            Button { labels.toggle() } label: {
                Image(systemName: labels ? "map.fill" : "map")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(labels ? "Hide Place Names" : "Show Place Names")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        // MapKit's compass, only while the globe is turned, under the Airports button.
        .overlay(alignment: .top) {
            MapCompass(scope: mapScope)
                .mapControlVisibility(.automatic)
                .offset(y: 89 + 10 + 44 + 10)
        }
        .padding(.trailing, 12)
        .padding(.top, 8)
        .opacity(home.shell.detent == .expanded ? 0 : 1)
        .allowsHitTesting(home.shell.detent != .expanded)
        .accessibilityHidden(home.shell.detent == .expanded)
        .animation(.smooth(duration: 0.25), value: home.shell.detent)
    }
}

// MARK: - Globe

/// The globe under the sheet, in a view of its own so only what it reads redraws it: the arcs, the
/// focus, the isolated flight and the detent (for MapKit's logo). The camera frames the area above the
/// medium sheet in every detent (`ShellModel.mapInset(in:)`), so a detent change leaves the globe still
/// and the open flight stays framed above the sheet; the map's safe area ends under the collapsed sheet's
/// top, so the Apple Maps logo and Legal link stay behind the sheet and never move
/// (`ShellModel.globeInsets(in:detent:)`).
private struct HomeGlobe: View {
    var home: HomeModel
    @Binding var selection: GlobeSelection?
    var labels: Bool
    var threeD: Bool
    var geometry: SheetGeometry
    var controlsScope: Namespace.ID

    var body: some View {
        let content = home.globe
        let insets = ShellModel.globeInsets(in: geometry, detent: home.shell.detent)
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: home.focus, recenter: home.shell.recenter, labels: labels, threeD: threeD,
                 isolation: home.isolation,
                 insets: insets, controlsScope: controlsScope,
                 airportStatus: content.status)
            // The whole screen, its safe area entirely the map's own (`insets`), lifted so that safe area
            // can reach above the screen's top; the lift's strip at the bottom is always under the sheet.
            .ignoresSafeArea()
            .offset(y: -insets.lift)
    }
}

// MARK: - Modal sheets

/// Search in its own sheet over the home sheet.
private struct SearchSheet: View {
    @State private var store: SearchStore
    var lookup: (String) -> Airport?
    var alreadyFollowed: FollowedFlights
    var frequent: [FrequentItem]
    var known: [KnownFlight]
    var onFollowed: (Flight) -> Void
    var onImport: () -> Void
    var onAirport: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, alreadyFollowed: FollowedFlights, frequent: [FrequentItem], known: [KnownFlight],
         onFollowed: @escaping (Flight) -> Void, onImport: @escaping () -> Void, onAirport: @escaping (String) -> Void) {
        _store = State(initialValue: env.makeSearchStore())
        self.lookup = env.lookup; self.alreadyFollowed = alreadyFollowed; self.frequent = frequent; self.known = known
        self.onFollowed = onFollowed; self.onImport = onImport; self.onAirport = onAirport
    }

    var body: some View {
        SearchView(store: store, onFollowed: onFollowed, lookup: lookup, alreadyFollowed: alreadyFollowed,
                   frequent: frequent, onImport: onImport, onAirport: onAirport, known: known)
            .overlay(alignment: .topTrailing) { CloseButton { dismiss() } }
            #if DEBUG
            // Screenshot runs: `-searchText UA1527` runs that search when the sheet opens.
            .task {
                guard let query = UserDefaults.standard.string(forKey: "searchText"), store.text.isEmpty else { return }
                store.text = query
                await store.search()
            }
            #endif
            .presentationDetents([.large])
            .presentationBackground(Theme.background)
            .presentationCornerRadius(Theme.sheetRadius)
    }
}

private struct SettingsSheet: View {
    var session: SessionStore
    @Binding var units: Units
    var history: any HistoryService
    var onDeleteAccount: () async -> Bool
    var notifications: NotificationSettingsStore
    var calendar: CalendarSync?
    var friends: FriendsStore?
    var profile: ProfileStore?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Signed out, the gate shows Sign In instead of the home, so this sheet closes with it.
        // Notifications, Calendar and Acknowledgements slide up as cards inside this sheet, each with
        // its own X over this one.
        SettingsView(session: session, units: $units, history: history, onDeleteAccount: onDeleteAccount,
                     notifications: notifications, calendar: calendar, friends: friends, profile: profile,
                     onClose: { dismiss() })
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
    }
}
