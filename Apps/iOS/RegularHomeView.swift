import FlightKit
import MapKit
import SwiftUI

/// Which tab chrome the panel home carries.
enum HomeTabsStyle {
    /// The system's sidebar-adaptable tab bar, as on the iPad.
    case system
    /// The iPhone's floating tab pill at the panel's foot, for a window that is not an iPad's but is wide
    /// enough for panels (the unfolded Duo held sideways). There is no `TabView`, so the globe is drawn once.
    case pill
}

/// The iPad home in a regular width window (full screen, the larger side of Split View, Stage Manager, and
/// the iPad app on Apple Vision Pro): the three tabs in the system's sidebar-adaptable tab bar, the globe
/// across the whole window, the tab's screen in a floating panel on the left and, when the window is wide
/// enough, the open flight, airport or friend in a second panel on the right, the globe framed between the
/// two. In a narrower window the card opens over the tab in the left panel, as in the Mac's panel.
/// Compact widths keep `RootTabView`'s sheet, exactly as on the iPhone.
///
/// The panels are the Mac's (`RootSidebarView`) at the iPhone's metrics: the shared screens get the
/// width they were drawn for.
struct RegularHomeView<TabScreen: View, MapControls: View>: View {
    let home: HomeModel
    @Binding var selection: GlobeSelection?
    var labels: Bool
    var threeD: Bool
    var mapScope: Namespace.ID
    var tabs: HomeTabsStyle
    var onSearch: () -> Void
    var onSettings: () -> Void
    var tabScreen: TabScreen
    var mapControls: MapControls
    /// The tab page's width, which decides between one panel and two.
    @State private var width: CGFloat = 0
    /// The tab pill's height (with `.pill`), where the list is masked off.
    @State private var pillHeight = SheetGeometry.tabBarHeight

    /// The iPhone 17 Pro's width: every shared screen was laid out for it.
    static var panelWidth: CGFloat { 402 }
    /// Space between a panel and the window's edges.
    static var panelInset: CGFloat { 16 }
    static var panelRadius: CGFloat { 30 }
    /// Wide enough for both panels with a useful stretch of globe between them (a 13 inch iPad in
    /// landscape, not in portrait).
    static var twoPanelWidth: CGFloat { 1100 }

    init(home: HomeModel, selection: Binding<GlobeSelection?>, labels: Bool, threeD: Bool, mapScope: Namespace.ID,
         tabs: HomeTabsStyle = .system,
         onSearch: @escaping () -> Void, onSettings: @escaping () -> Void,
         @ViewBuilder tabScreen: () -> TabScreen, @ViewBuilder mapControls: () -> MapControls) {
        self.home = home; _selection = selection; self.labels = labels; self.threeD = threeD
        self.mapScope = mapScope; self.tabs = tabs; self.onSearch = onSearch; self.onSettings = onSettings
        self.tabScreen = tabScreen(); self.mapControls = mapControls()
    }

    private var twoPanels: Bool { width >= Self.twoPanelWidth }
    /// The card panel on the right is up.
    private var detailOpen: Bool { twoPanels && !home.shell.path.isEmpty }
    /// A panel and its margin: the part of the globe it covers.
    private var panelSide: CGFloat { Self.panelWidth + Self.panelInset }

    var body: some View {
        @Bindable var home = home
        switch tabs {
        case .system:
            TabView(selection: $home.tab) {
                Tab("My Flights", systemImage: "airplane.circle.fill", value: HomeTab.flights) { page(.flights) }
                Tab("Friends", systemImage: "person.2.fill", value: HomeTab.friends) { page(.friends) }
                Tab("Passport", systemImage: "person.text.rectangle.fill", value: HomeTab.passport) { page(.passport) }
            }
            .tabViewStyle(.sidebarAdaptable)
        case .pill:
            // The pill is in the list panel, so the one tab on show is the whole page.
            canvas
        }
    }

    /// Only the tab on show draws the globe: one MapKit view at a time, the camera following `home.focus`.
    @ViewBuilder private func page(_ tab: HomeTab) -> some View {
        if home.tab == tab {
            canvas
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var canvas: some View {
        let content = home.globe
        return GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports,
                        selection: $selection, focus: home.focus, recenter: home.shell.recenter, labels: labels,
                        threeD: threeD, isolation: home.isolation, controlsScope: mapScope,
                        airportStatus: content.status)
            // The panels' sides count as covered, so the camera frames arcs and airports in the globe
            // left in view between them, as on the Mac.
            .safeAreaPadding(.leading, panelSide)
            .safeAreaPadding(.trailing, detailOpen ? panelSide : 0)
            .ignoresSafeArea()
            .background(Color.black)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topLeading) { listPanel }
            .overlay(alignment: .topTrailing) {
                mapControls.padding(.trailing, detailOpen ? panelSide : 0)
            }
            .overlay(alignment: .topTrailing) {
                if detailOpen {
                    detailPanel.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(CardMotion.animation, value: detailOpen)
            .mapScope(mapScope)
    }

    // MARK: Panels

    /// The tab's screen; in one-panel windows the open cards stack over it, as in the iPhone sheet.
    private var listPanel: some View {
        let shell = home.shell
        return CardStack(path: twoPanels ? [] : shell.path, onPop: shell.close, zoomID: \.zoomID) {
            listRoot
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .modifier(PanelChrome())
        .padding([.leading, .bottom], Self.panelInset)
        .padding(.top, 8)
    }

    /// The open flight, airport or friend beside the list; its X closes it.
    private var detailPanel: some View {
        let shell = home.shell
        return CardStack(path: shell.path, onPop: shell.close) {
            Color.clear
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .modifier(PanelChrome())
        .padding([.trailing, .bottom], Self.panelInset)
        .padding(.top, 8)
    }

    private var listScreen: some View {
        tabScreen.frame(maxHeight: .infinity, alignment: .top)
    }

    private var profileButton: some View {
        ProfileButton(profile: home.profile, action: onSettings)
            .pointerHighlight(Circle())
            .padding(.top, 19)
            .padding(.trailing, 16)
    }

    @ViewBuilder private var listRoot: some View {
        switch tabs {
        case .system:
            // Search stays at the panel's foot, where the iPhone has it.
            listScreen
                .overlay(alignment: .topTrailing) { profileButton }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 12) {
                        ToastSlot(text: home.toast, isError: home.toastIsError)
                        SearchFieldButton(action: onSearch)
                    }
                }
        case .pill:
            // The pill carries both the tabs and the search button, as in the Mac's panel. The list ends
            // above it and fades out there, as in the iPhone sheet: no row draws under the glass.
            listScreen
                .pillFade(pillHeight: pillHeight)
                .overlay(alignment: .topTrailing) { profileButton }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 12) {
                        ToastSlot(text: home.toast, isError: home.toastIsError)
                        HomeTabPill(tab: Binding(get: { home.tab }, set: { home.tab = $0 }), bottom: 14,
                                    onSearch: onSearch)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                    }
                }
        }
    }
}

/// A panel floating over the globe: the sheet's colour and the Mac panel's corners, rim and shadow.
private struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: RegularHomeView<EmptyView, EmptyView>.panelWidth)
            .frame(maxHeight: .infinity)
            .background(Theme.background)
            .clipShape(.rect(cornerRadius: RegularHomeView<EmptyView, EmptyView>.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RegularHomeView<EmptyView, EmptyView>.panelRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

/// The search field at the foot of the iPad panel: a glass capsule that opens Search (Command F too).
private struct SearchFieldButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                Text("Flight, route, or airport")
                    .font(.system(size: 17))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(HomeTabPill.tint).interactive(), in: .capsule)
        .pointerHighlight(Capsule())
        .accessibilityLabel("Search")
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}
