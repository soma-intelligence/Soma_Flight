import FlightKit
import SwiftUI

/// The iOS home: the satellite globe full screen, a resizable sheet over it holding My Flights or
/// Passport, a floating tab pill with a round search button, and a gear for Settings. Flights and
/// airports open inside the sheet while the globe moves onto them. The state is FlightKit's
/// `HomeModel`, shared with the Mac sidebar.
struct RootTabView: View {
    @State private var home: HomeModel
    @State private var selection: GlobeSelection?
    @State private var labels = true
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var screenHeight: CGFloat = 874
    @StoredUnits private var units: Units
    @Environment(\.scenePhase) private var scenePhase

    init(home: HomeModel) {
        _home = State(initialValue: home)
    }

    private var env: AppEnvironment { home.env }
    private var shell: ShellModel { home.shell }

    var body: some View {
        let content = home.globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: home.focus, recenter: shell.recenter, labels: labels)
            // The map draws under the status bar on its own and keeps its controls clear of it. It ends just
            // under the sheet's settled top (its rounded corners still show the globe), not at the screen's
            // bottom: MapKit scales the globe to the map's height, so a map no taller than what shows lets
            // a long-haul arc fit across a phone.
            .safeAreaPadding(.bottom, ShellModel.sheetOverlap)
            .padding(.bottom, ShellModel.mapInset(for: shell.detent, screenHeight: screenHeight) - ShellModel.sheetOverlap)
            .animation(.smooth, value: shell.detent)
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
            .onChange(of: home.owner) { home.userChanged() }
            // The Live Activity rules: once the stored session is read, and each time the app comes to
            // the front (an activity can only start in the foreground).
            .onChange(of: home.awaitingSession) { Task { await home.reconcileActivities() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await home.reconcileActivities() } }
            }
            .task {
                await home.start()
                #if DEBUG
                home.applyLaunchArguments()
                await home.applyPushLaunchArguments()
                await home.applyLiveActivityLaunchArguments()
                #endif
            }
            .onChange(of: home.pushSerial) { Task { await home.processInbox() } }
            // A notification opens a flight under Search or Settings: they close so it shows.
            .onChange(of: shell.path) { _, path in
                if !path.isEmpty { showSearch = false; showSettings = false }
            }
            .environment(\.units, units)
    }

    // MARK: Sheet

    private var sheet: some View {
        @Bindable var shell = home.shell
        return NavigationStack(path: $shell.path) {
            tabRoot
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SheetRoute.self) { route in
                    HomeDestination(home: home, route: route)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .presentationDetents(ShellModel.detents, selection: $shell.detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSearch) {
            SearchSheet(env: env, followedIDs: Set(home.followed.map(\.id)), onFollowed: { _ in Task { await home.didFollow() } })
                .environment(\.units, units)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: home.session, units: $units, onDeleteAccount: { Task { await home.session.deleteAccount() } })
                .environment(\.units, units)
        }
        .environment(\.units, units)
    }

    @ViewBuilder private var tabRoot: some View {
        Group {
            switch home.tab {
            case .flights:
                MyFlightsView(store: home.myFlights, onSelect: home.open(flight:), onSearch: { showSearch = true },
                              lookup: env.lookup)
            case .passport:
                PassportView(store: home.passport, lookup: env.lookup)
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
            HomeTabPill(tab: $home.tab, bottom: -14, onSearch: { showSearch = true })
        }
    }

    // MARK: Map controls

    /// MapKit stacks its compass and 3D toggle at the top right, one 44 pt control plus spacing below the
    /// safe area; the place-name button sits under that stack.
    static let mapControlStackHeight: CGFloat = 58

    private var mapButtons: some View {
        Button { labels.toggle() } label: {
            Image(systemName: labels ? "map.fill" : "map")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(labels ? "Hide Place Names" : "Show Place Names")
        .padding(.trailing, 12)
        .padding(.top, Self.mapControlStackHeight)
    }
}

// MARK: - Modal sheets

/// Search in its own sheet over the home sheet.
private struct SearchSheet: View {
    @State private var store: SearchStore
    var lookup: (String) -> Airport?
    var followedIDs: Set<Flight.ID>
    var onFollowed: (Flight) -> Void
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, followedIDs: Set<Flight.ID>, onFollowed: @escaping (Flight) -> Void) {
        _store = State(initialValue: env.makeSearchStore())
        self.lookup = env.lookup; self.followedIDs = followedIDs; self.onFollowed = onFollowed
    }

    var body: some View {
        SearchView(store: store, onFollowed: onFollowed, lookup: lookup, followedIDs: followedIDs)
            .overlay(alignment: .topTrailing) { CloseButton { dismiss() } }
            .presentationDetents([.large])
            .presentationBackground(Theme.background)
            .presentationCornerRadius(Theme.sheetRadius)
    }
}

private struct SettingsSheet: View {
    var session: SessionStore
    @Binding var units: Units
    var onDeleteAccount: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Export arrives with Task 12.
        SettingsView(session: session, units: $units, onDeleteAccount: onDeleteAccount)
            .overlay(alignment: .topTrailing) { CloseButton { dismiss() } }
            .presentationDetents([.large])
            .presentationBackground(Theme.background)
            .presentationCornerRadius(Theme.sheetRadius)
    }
}
