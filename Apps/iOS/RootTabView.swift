import FlightKit
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
    @State private var showSettings = false
    @State private var screenHeight: CGFloat = 874
    @StoredUnits private var units: Units

    init(home: HomeModel) {
        _home = State(initialValue: home)
    }

    private var env: AppEnvironment { home.env }
    private var shell: ShellModel { home.shell }

    var body: some View {
        HomeGlobe(home: home, selection: $selection, labels: labels, threeD: threeD, screenHeight: screenHeight)
            .background {
                Color.black
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
            }
            .overlay(alignment: .topTrailing) { mapButtons }
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
            .environment(\.units, units)
    }

    // MARK: Sheet

    private var sheet: some View {
        @Bindable var shell = home.shell
        // Each screen slides up over the one below as a card, and its X drops it back down.
        return CardStack(path: shell.path, onPop: shell.close) {
            tabRoot
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .environment(\.fullPageZoom, pageZoom)
        .presentationDetents(ShellModel.detents, selection: $shell.detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSearch) {
            SearchSheet(env: env, alreadyFollowed: FollowedFlights(home.followed), frequent: home.frequent,
                        onFollowed: { flight in Task { await home.didFollow(flight) } })
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
                          notifications: home.notificationSettings, calendar: home.calendar, friends: home.friends)
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
        .environment(\.units, units)
    }

    @ViewBuilder private var tabRoot: some View {
        Group {
            switch home.tab {
            case .flights:
                MyFlightsView(store: home.myFlights, onSelect: home.open(flight:), onSearch: { showSearch = true },
                              lookup: env.lookup)
            case .friends:
                FriendsView(store: home.friends, onOpenFriend: home.open(friend:), lookup: env.lookup)
            case .passport:
                PassportView(store: home.passport, lookup: env.lookup, onOpen: { home.fullPage = $0 },
                                 onOpenFlight: home.open(past:))
            }
        }
        .overlay(alignment: .topTrailing) {
            RoundButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
                .padding(.top, 19)
                .padding(.trailing, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The pill reaches 14 pt into the home indicator inset (34 pt on Face ID iPhones), so it sits
            // 20 pt above the sheet's bottom edge as in the reference.
            VStack(spacing: 12) {
                ToastSlot(text: home.toast)
                HomeTabPill(tab: $home.tab, bottom: -14, onSearch: { showSearch = true })
            }
        }
    }

    // MARK: Map controls

    /// The 3D switch over the place-name switch in one glass capsule, as Maps groups its controls. MapKit's
    /// compass shows under it only while the globe is turned.
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
        .padding(.trailing, 12)
        .padding(.top, 8)
    }
}

// MARK: - Globe

/// The globe under the sheet, in a view of its own so only what it reads redraws it: the arcs, the
/// focus, the isolated flight and the settled detent, never the sheet's other state. The map keeps the
/// whole screen; the detent only moves its bottom safe area, which the globe glides to while the camera
/// springs onto the new fit.
private struct HomeGlobe: View {
    var home: HomeModel
    @Binding var selection: GlobeSelection?
    var labels: Bool
    var threeD: Bool
    var screenHeight: CGFloat

    var body: some View {
        let content = home.globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: home.focus, recenter: home.shell.recenter, labels: labels, threeD: threeD,
                 isolation: home.isolation,
                 bottomInset: ShellModel.mapInset(for: home.shell.detent, screenHeight: screenHeight))
            // Down to the screen's bottom edge; the status bar's inset stays, so MapKit keeps its compass clear.
            .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - Modal sheets

/// Search in its own sheet over the home sheet.
private struct SearchSheet: View {
    @State private var store: SearchStore
    var lookup: (String) -> Airport?
    var alreadyFollowed: FollowedFlights
    var frequent: [FrequentItem]
    var onFollowed: (Flight) -> Void
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, alreadyFollowed: FollowedFlights, frequent: [FrequentItem],
         onFollowed: @escaping (Flight) -> Void) {
        _store = State(initialValue: env.makeSearchStore())
        self.lookup = env.lookup; self.alreadyFollowed = alreadyFollowed; self.frequent = frequent
        self.onFollowed = onFollowed
    }

    var body: some View {
        SearchView(store: store, onFollowed: onFollowed, lookup: lookup, alreadyFollowed: alreadyFollowed,
                   frequent: frequent)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Signed out, the gate shows Sign In instead of the home, so this sheet closes with it.
        // Notifications, Calendar and Acknowledgements slide up as cards inside this sheet, each with
        // its own X over this one.
        SettingsView(session: session, units: $units, history: history, onDeleteAccount: onDeleteAccount,
                     notifications: notifications, calendar: calendar, friends: friends, onClose: { dismiss() })
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
    }
}
