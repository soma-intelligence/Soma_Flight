import FlightKit
import SwiftUI

/// The two tabs of the home sheet.
enum RootTab: Hashable {
    case flights, passport
}

/// The iOS home: the satellite globe full screen, a resizable sheet over it holding My Flights or
/// Passport, a floating tab pill with a round search button, and a gear for Settings. Flights and
/// airports open inside the sheet while the globe moves onto them.
struct RootTabView: View {
    let env: AppEnvironment

    @State private var session: SessionStore
    @State private var myFlights: MyFlightsStore
    @State private var passport: PassportStore
    @State private var shell = ShellModel()
    @State private var tab: RootTab = .flights
    @State private var selection: GlobeSelection?
    @State private var labels = true
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var screenHeight: CGFloat = 874
    @AppStorage("units.distance") private var distance: DistanceUnit = .km
    @AppStorage("units.clock24") private var clock24 = true

    init(env: AppEnvironment) {
        self.env = env
        _session = State(initialValue: env.makeSessionStore())
        _myFlights = State(initialValue: env.makeMyFlightsStore())
        _passport = State(initialValue: env.makePassportStore())
    }

    private var units: Units { Units(distance: distance, clock: clock24 ? .h24 : .h12) }

    private var unitsBinding: Binding<Units> {
        Binding(get: { units }, set: { distance = $0.distance; clock24 = $0.clock == .h24 })
    }

    private var followed: [Flight] { myFlights.live + myFlights.upcoming }

    private var globe: GlobeContent {
        switch tab {
        case .flights: .followed(followed, lookup: env.lookup)
        case .passport: .past(passport.flights, lookup: env.lookup)
        }
    }

    private func route(for id: Flight.ID) -> Route? {
        followed.first { $0.id == id }.flatMap { GlobeContent.route(for: $0, lookup: env.lookup) }
    }

    var body: some View {
        let content = globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: shell.focus(route: route(for:), airport: env.lookup), recenter: shell.recenter, labels: labels)
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
                switch picked {
                case .airport(let code): open(airport: code)
                case .flight(let id): if let f = followed.first(where: { $0.id == id }) { open(flight: f) }
                }
            }
            .onChange(of: session.session?.userId) {
                // The session store has already handed the device's saved data to the new user (or to
                // nobody) before publishing it, so the rebuilt stores never read the previous account's.
                resetStores()
            }
            .task {
                session.start()
                await load()
                #if DEBUG
                applyLaunchRoute()
                #endif
            }
            .environment(\.units, units)
    }

    // MARK: Sheet

    private var sheet: some View {
        NavigationStack(path: $shell.path) {
            tabRoot
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: SheetRoute.self) { route in
                    destination(route)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .presentationDetents(ShellModel.detents, selection: $shell.detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSearch) {
            SearchSheet(env: env, followedIDs: Set(followed.map(\.id)), onFollowed: { _ in Task { await myFlights.load() } })
                .environment(\.units, units)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session, units: unitsBinding, onDeleteAccount: { Task { await session.deleteAccount() } })
                .environment(\.units, units)
        }
        .environment(\.units, units)
    }

    @ViewBuilder private var tabRoot: some View {
        Group {
            switch tab {
            case .flights:
                MyFlightsView(store: myFlights, onSelect: open(flight:), onSearch: { showSearch = true },
                              lookup: env.lookup)
            case .passport:
                PassportView(store: passport, lookup: env.lookup)
            }
        }
        .overlay(alignment: .topTrailing) {
            RoundButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
                .padding(.top, 19)
                .padding(.trailing, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabPill(tab: $tab, onSearch: { showSearch = true })
        }
    }

    @ViewBuilder private func destination(_ route: SheetRoute) -> some View {
        switch route {
        case .flight(let id):
            FlightScreen(env: env, id: id, onAirport: open(airport:), onClose: shell.close)
        case .airport(let code):
            AirportScreen(env: env, code: code, onClose: shell.close)
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

    // MARK: Actions

    private func open(flight: Flight) {
        shell.open(flight: flight.id, route: GlobeContent.route(for: flight, lookup: env.lookup))
    }

    /// Codes arrive as ICAO from the globe and as either code from the screens; the stack keys on ICAO.
    private func open(airport code: String) {
        shell.open(airport: env.lookup(code)?.id ?? code)
    }

    private func load() async {
        await myFlights.load()
        myFlights.startUpdates()
        await passport.load()
    }

    #if DEBUG
    /// Screenshot runs open a screen without taps: `-tab passport`, `-open flight` (the first one in the
    /// air) or `-open airport:KAUS`, and `-detent large` or `-detent small`.
    private func applyLaunchRoute() {
        let args = UserDefaults.standard
        if args.string(forKey: "tab") == "passport" { tab = .passport }
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
    #endif

    private func resetStores() {
        shell.reset()
        myFlights = env.makeMyFlightsStore()
        passport = env.makePassportStore()
        Task { await load() }
    }
}

// MARK: - Pushed screens

/// Flight detail with its own store, loaded on appear.
private struct FlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void

    init(env: AppEnvironment, id: Flight.ID, onAirport: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        _store = State(initialValue: env.makeFlightDetailStore(id: id))
        self.onAirport = onAirport; self.onClose = onClose
    }

    var body: some View {
        FlightDetailView(store: store, onAirport: onAirport)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .task { await store.load() }
    }
}

/// Airport sheet with its own store; far-end city names come from the shared airport list.
private struct AirportScreen: View {
    @State private var store: AirportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    init(env: AppEnvironment, code: String, onClose: @escaping () -> Void) {
        _store = State(initialValue: env.makeAirportStore(code: code))
        self.lookup = env.lookup; self.onClose = onClose
    }

    var body: some View {
        AirportView(store: store, lookup: lookup)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .task { await store.load() }
    }
}

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

// MARK: - Chrome

/// Floating pill with the two tabs and the round search button beside it.
private struct TabPill: View {
    @Binding var tab: RootTab
    var onSearch: () -> Void
    @Namespace private var selectionSpace

    /// Darkens the glass so the cards scrolling under it stay quiet, as in the reference.
    static let tint = Color(light: 0xFFFFFF, dark: 0x1C1C1E).opacity(0.55)

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                item(.flights, title: "My Flights", systemImage: "airplane.circle.fill")
                item(.passport, title: "Passport", systemImage: "person.text.rectangle.fill")
            }
            .padding(4)
            .glassEffect(.regular.tint(Self.tint), in: .capsule)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 59, height: 59)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Self.tint).interactive(), in: .circle)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, -Self.homeIndicatorOverlap)
    }

    /// How far the pill reaches into the home indicator inset (34 pt on Face ID iPhones), so it sits
    /// 20 pt above the sheet's bottom edge as in the reference.
    static let homeIndicatorOverlap: CGFloat = 14

    private func item(_ value: RootTab, title: String, systemImage: String) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.snappy) { tab = value }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 25)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 51)
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

/// Round grey button for the sheet header (Settings) and the close X, filled as in the reference.
private struct RoundButton: View {
    static let fill = Color(light: 0xE3E3E8, dark: 0x3A3A3C)

    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Self.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The circular X at the top right of a pushed screen or a modal sheet.
private struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        RoundButton(systemImage: "xmark", label: "Close", action: action)
            .padding(.top, 16)
            .padding(.trailing, 16)
    }
}
