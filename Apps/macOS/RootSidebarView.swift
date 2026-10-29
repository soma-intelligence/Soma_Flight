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
    /// The Mac reference draws its iPhone-sized screens at 77%.
    static let panelScale: CGFloat = 0.77
    static let minimumSize = CGSize(width: 900, height: 600)
    static let defaultSize = CGSize(width: 1180, height: 800)

    init(home: HomeModel) {
        self.home = home
        _search = State(initialValue: home.env.makeSearchStore())
    }

    private var env: AppEnvironment { home.env }

    var body: some View {
        let content = home.globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports, selection: $selection,
                 focus: home.focus, recenter: home.shell.recenter, labels: labels)
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
                home.select(picked)
            }
            .onChange(of: home.owner) { home.userChanged() }
            .task {
                await home.start()
                #if DEBUG
                home.applyLaunchArguments()
                #endif
            }
            .environment(\.units, units)
    }

    // MARK: Panel

    private var panel: some View {
        @Bindable var shell = home.shell
        return NavigationStack(path: $shell.path) {
            panelRoot
                .searchable(text: $search.text, placement: .toolbar, prompt: Text("Flight, route, or airport"))
                .onSubmit(of: .search) {
                    showSearch = true
                    Task { await search.search() }
                }
                .navigationDestination(for: SheetRoute.self) { route in
                    HomeDestination(home: home, route: route)
                        .navigationBarBackButtonHidden()
                }
        }
        .background(Theme.background)
        // The screens are drawn at their iPhone sizes and scaled down as a whole, the way an iPad app
        // runs on the Mac: type, spacing and controls keep their proportions and match the Mac reference.
        .scaledPanel(Self.panelScale, width: Self.panelWidth)
        .clipShape(.rect(cornerRadius: Self.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .padding([.leading, .bottom], Self.panelInset)
    }

    @ViewBuilder private var panelRoot: some View {
        @Bindable var home = home
        Group {
            if showSearch {
                SearchView(store: search, onFollowed: { _ in Task { await home.myFlights.load() } }, lookup: env.lookup,
                           followedIDs: Set(home.followed.map(\.id)))
                    .overlay(alignment: .topTrailing) { CloseButton { showSearch = false } }
            } else {
                switch home.tab {
                case .flights:
                    MyFlightsView(store: home.myFlights, onSelect: home.open(flight:), onSearch: { showSearch = true },
                                  lookup: env.lookup)
                case .passport:
                    PassportView(store: home.passport, lookup: env.lookup)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !showSearch {
                RoundButton(systemImage: "gearshape", label: "Settings") { openSettings() }
                    .padding(.top, 19)
                    .padding(.trailing, 16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeTabPill(tab: Binding(get: { home.tab }, set: { home.tab = $0; showSearch = false }), bottom: 14,
                        onSearch: { showSearch = true })
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

private extension View {
    /// Lays the view out `1 / scale` times larger, then draws it at `scale`, filling `width` and the height
    /// it is offered.
    func scaledPanel(_ scale: CGFloat, width: CGFloat) -> some View {
        ScaledFrame(scale: scale, width: width) {
            scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// Offers its one subview `1 / scale` of its own size and takes `width` by the height it is offered. A
/// layout rather than a GeometryReader, so the panel's scroll views get their real height from the first
/// pass and do not open scrolled.
private struct ScaledFrame: Layout {
    var scale: CGFloat
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? (subviews.first?.sizeThatFits(ProposedViewSize(width: width / scale, height: nil)).height ?? 0) * scale
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: width / scale, height: bounds.height / scale))
    }
}
