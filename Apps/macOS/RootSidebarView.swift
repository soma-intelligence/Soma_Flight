import FlightKit
import SwiftUI

/// The Mac home: the satellite globe fills the window and a floating panel on the left holds My Flights
/// or Passport, the tab pill with its search button, and the flight and airport screens pushed over
/// them. The globe keeps what it looks at clear of the panel. Search is also in the toolbar. The state
/// is FlightKit's `HomeModel`, shared with the iOS sheet.
struct RootSidebarView: View {
    let home: HomeModel

    @State private var search: SearchStore
    @State private var showSearch = false
    @State private var selection: GlobeSelection?
    @State private var labels = true
    @StoredUnits private var units: Units
    @Environment(\.openSettings) private var openSettings

    static let panelWidth: CGFloat = 360
    /// Space between the panel and the window's left and bottom edges.
    static let panelInset: CGFloat = 12
    static let panelRadius: CGFloat = 26
    /// The shared screens' metrics in the panel (`metricsScale`): the Mac reference sets its type at about
    /// 77% of the iPhone's; 0.8 with the 10 pt floor keeps captions legible.
    static let metricsScale: CGFloat = 0.8
    static let minimumSize = CGSize(width: 900, height: 600)
    /// Tall enough for a full page sheet (`fullPageSize`) over the globe.
    static let defaultSize = CGSize(width: 1180, height: 900)
    /// The full Passport and Aircraft Stats open as sheets this size, at the iPhone's metrics
    /// (`metricsScale` 1.0): they get the width the 360 pt panel lacks.
    static let fullPageSize = CGSize(width: 720, height: 820)

    init(home: HomeModel) {
        self.home = home
        _search = State(initialValue: home.env.makeSearchStore())
    }

    private var env: AppEnvironment { home.env }

    var body: some View {
        let content = home.globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: home.focus, recenter: home.shell.recenter, labels: labels,
                 // An open flight alone on the globe, as on the phone.
                 isolation: home.isolation)
            // The map fills the window; the panel's side counts as covered, so the camera fits arcs and
            // centres airports in the part of the globe left in view.
            .safeAreaPadding(.leading, Self.panelWidth + Self.panelInset)
            .ignoresSafeArea(.container, edges: .top)
            .background(Color.black)
            .overlay(alignment: .topLeading) { panel }
            .overlay(alignment: .topTrailing) { labelsButton }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .onChange(of: selection) { _, picked in
                guard let picked else { return }
                selection = nil
                showSearch = false
                home.select(picked)
            }
            // HomeModel's session watch rebuilds the stores; this only closes the search.
            .onChange(of: home.owner) { showSearch = false }
            .task {
                await home.start()
                #if DEBUG
                home.applyLaunchArguments()
                await home.applyPushLaunchArguments()
                #endif
            }
            .onChange(of: home.pushSerial) { Task { await home.processInbox() } }
            // A Passport card's page (full Passport, Aircraft Stats, delays) opens as a sheet over the window,
            // 720 x 820 at full metrics; a shorter window shrinks it to fit.
            .sheet(item: Binding(get: { home.fullPage }, set: { home.fullPage = $0 })) { page in
                FullPageView(page: page, store: home.passport, lookup: env.lookup) { home.fullPage = nil }
                    .environment(\.units, units)
                    .environment(\.metricsScale, 1.0)
                    .frame(width: Self.fullPageSize.width)
                    .frame(minHeight: Self.minimumSize.height - 80, idealHeight: Self.fullPageSize.height,
                           maxHeight: Self.fullPageSize.height)
            }
            // A boarding pass opened with Open With, or dropped on the Dock icon.
            .passImportSheet(home)
            // An invitation link the app was opened with: accept or decline.
            .sheet(item: Binding(get: { home.pendingInvite }, set: { home.pendingInvite = $0 })) { invite in
                FriendInviteSheet(invite: invite, onAnswer: { await home.answerInvite(accept: $0) },
                                  onClose: { home.pendingInvite = nil })
                    .frame(width: 400, height: 460)
            }
            // The Import screen; a confirmation email dropped on it or opened with the app lands there too.
            .importSheet(home)
            .environment(\.units, units)
            .environment(\.connectivity, home.connectivity)
    }

    // MARK: Panel

    private var panel: some View {
        @Bindable var shell = home.shell
        return NavigationStack(path: $shell.path) {
            searchField(panelRoot)
                .navigationDestination(for: SheetRoute.self) { route in
                    searchField(HomeDestination(home: home, route: route).navigationBarBackButtonHidden())
                }
        }
        .environment(\.metricsScale, Self.metricsScale)
        .frame(width: Self.panelWidth)
        .background(Theme.background)
        .clipShape(.rect(cornerRadius: Self.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .padding([.leading, .bottom], Self.panelInset)
    }

    /// The toolbar search field. macOS draws only the field of the screen on top of the stack (one put on
    /// the stack itself does not show), so the root and every pushed screen carry the same field, bound
    /// to the one store: it stays in the toolbar while a flight or airport is open. Typing goes back to
    /// the panel's root and shows the suggestions there; return picks the top one.
    private func searchField(_ screen: some View) -> some View {
        screen
            .searchable(text: $search.text, placement: .toolbar, prompt: Text("Flight, route, or airport"))
            .onChange(of: search.text) { _, text in
                search.textChanged()
                if !text.isEmpty, !showSearch { home.shell.reset(); showSearch = true }
            }
            .onSubmit(of: .search) {
                home.shell.reset()
                showSearch = true
                if case .openAirport(let code) = search.submit() { openAirport(code) }
            }
    }

    private func openAirport(_ code: String) {
        showSearch = false
        home.open(airport: code)
    }

    @ViewBuilder private var panelRoot: some View {
        @Bindable var home = home
        Group {
            if showSearch {
                SearchView(store: search, onFollowed: { flight in Task { await home.didFollow(flight) } },
                           lookup: env.lookup, alreadyFollowed: FollowedFlights(home.followed), frequent: home.frequent,
                           onImport: { home.showImport = true }, onAirport: openAirport,
                           known: KnownFlight.list(followed: home.followed, past: home.passport.flights))
                    .overlay(alignment: .topTrailing) { CloseButton { showSearch = false } }
            } else {
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
        }
        .overlay(alignment: .topTrailing) {
            if !showSearch {
                RoundButton(systemImage: "gearshape", label: "Settings") { openSettings() }
                    .scaledPadding(.top, 19)
                    .scaledPadding(.trailing, 16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                ToastSlot(text: home.toast)
                HomeTabPill(tab: Binding(get: { home.tab }, set: { home.tab = $0; showSearch = false }), bottom: 14,
                            onSearch: { showSearch = true })
            }
        }
    }

    // MARK: Map controls

    /// MapKit puts its 3D toggle in the top right corner; the place-name button sits under it.
    static let mapControlStackHeight: CGFloat = 58

    private var labelsButton: some View {
        Button { labels.toggle() } label: {
            Image(systemName: labels ? "map.fill" : "map")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(labels ? "Hide Place Names" : "Show Place Names")
        .accessibilityLabel(labels ? "Hide Place Names" : "Show Place Names")
        .padding(.trailing, 12)
        .padding(.top, Self.mapControlStackHeight)
        .ignoresSafeArea(.container, edges: .top)
    }
}
