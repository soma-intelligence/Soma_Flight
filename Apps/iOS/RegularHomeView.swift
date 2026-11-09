import FlightKit
import MapKit
import SwiftUI

/// The panels home: the iPad in a regular width window (full screen, the larger side of Split View, Stage
/// Manager, and the iPad app on Apple Vision Pro), and the unfolded iPhone Duo held sideways. There is no
/// `TabView`: the iPhone's tab pill and search button sit at the panel's foot, centred on the panel (owner's
/// call, 2026-11-08, no system sidebar on the iPad), so the globe is drawn once. The globe
/// across the whole window and the tab's screen in a floating panel on the left; an open flight, airport or
/// friend opens over the tab in that same panel, as in the Mac's panel, so the globe keeps the rest.
/// Compact iPad widths and narrow iPhone windows keep `RootTabView`'s sheet.
///
/// The panels are the Mac's (`RootSidebarView`) at the iPhone's metrics: the shared screens get the
/// width they were drawn for.
struct RegularHomeView<TabScreen: View, MapControls: View>: View {
    let home: HomeModel
    @Binding var selection: GlobeSelection?
    var labels: Bool
    var threeD: Bool
    var mapScope: Namespace.ID
    var onSearch: () -> Void
    var onSettings: () -> Void
    var tabScreen: TabScreen
    var mapControls: MapControls
    /// The tab pill's height, where the list is masked off.
    @State private var pillHeight = SheetGeometry.tabBarHeight
    /// The window and its safe areas, which place the panel's three heights, as the iPhone sheet's.
    @State private var geometry = SheetGeometry.standard
    /// How far the grabber is being dragged, in points (positive downward).
    @State private var drag: CGFloat = 0

    /// The iPhone 17 Pro's width: every shared screen was laid out for it.
    static var panelWidth: CGFloat { 402 }
    /// Space between a panel and the window's edges.
    static var panelInset: CGFloat { 16 }
    static var panelRadius: CGFloat { 30 }

    init(home: HomeModel, selection: Binding<GlobeSelection?>, labels: Bool, threeD: Bool, mapScope: Namespace.ID,
         onSearch: @escaping () -> Void, onSettings: @escaping () -> Void,
         @ViewBuilder tabScreen: () -> TabScreen, @ViewBuilder mapControls: () -> MapControls) {
        self.home = home; _selection = selection; self.labels = labels; self.threeD = threeD
        self.mapScope = mapScope; self.onSearch = onSearch; self.onSettings = onSettings
        self.tabScreen = tabScreen(); self.mapControls = mapControls()
    }

    /// A panel and its margin: the part of the globe it covers.
    private var panelSide: CGFloat { Self.panelWidth + Self.panelInset }

    var body: some View {
        canvas
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
            .ignoresSafeArea()
            .background(Color.black)
            // The whole window, with the safe areas it ignores still reported: the panel heights' frame.
            .background {
                Color.clear
                    .onGeometryChange(for: SheetGeometry.self) { proxy in
                        SheetGeometry(screenHeight: proxy.size.height, safeTop: proxy.safeAreaInsets.top,
                                      safeBottom: proxy.safeAreaInsets.bottom)
                    } action: { geometry = $0 }
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topLeading) { listPanel }
            .overlay(alignment: .topTrailing) {
                mapControls
            }
            .mapScope(mapScope)
    }

    // MARK: Panels

    /// The tab's screen; the open cards stack over it, as in the iPhone sheet.
    private var listPanel: some View {
        let shell = home.shell
        return CardStack(path: shell.path, onPop: shell.close, zoomID: \.zoomID) {
            listRoot
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .environment(\.sheetDetent, shell.detent)
        .overlay(alignment: .top) { grabber }
        // A Passport page rises over the list in the same panel, never full screen (owner's call, 2026-11-08).
        .overlay {
            if let page = home.fullPage {
                FullPageView(page: page, store: home.passport, lookup: home.env.lookup) { home.fullPage = nil }
                    .transition(CardMotion.transition)
            }
        }
        .animation(CardMotion.animation, value: home.fullPage)
        .modifier(PanelChrome())
        .padding(.leading, Self.panelInset)
        .padding(.top, panelTop - geometry.safeTop + 8)
    }

    /// The panel's top edge: its detent's, as on the iPhone (collapsed, medium, expanded; owner's call,
    /// 2026-11-08), followed by the finger while the grabber is dragged.
    private var panelTop: CGFloat {
        let detent = geometry.top(of: home.shell.detent)
        let highest = geometry.top(of: .expanded)
        let lowest = geometry.top(of: .collapsed)
        let top = detent + drag
        // Past either end the panel follows at a third of the finger, like a rubber band.
        if top < highest { return highest - (highest - top) / 3 }
        if top > lowest { return lowest + (top - lowest) / 3 }
        return top
    }

    /// The handle at the panel's top: dragging it moves the panel between its three heights, a tap steps
    /// it up (or back to collapsed from the top).
    private var grabber: some View {
        let shell = home.shell
        return Capsule()
            .fill(Theme.secondary.opacity(0.45))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 22, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        let top = geometry.top(of: shell.detent) + value.translation.height
                        let to = geometry.snap(top: top, velocity: value.velocity.height)
                        withAnimation(.spring(duration: 0.38, bounce: 0)) {
                            shell.detent = to
                            drag = 0
                        }
                    })
            .onTapGesture {
                withAnimation(.spring(duration: 0.38, bounce: 0)) {
                    shell.detent = shell.detent.raised ?? .collapsed
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Panel height")
            .accessibilityAdjustableAction { direction in
                withAnimation(.spring(duration: 0.38, bounce: 0)) {
                    switch direction {
                    case .increment: if let up = shell.detent.raised { shell.detent = up }
                    case .decrement: if let down = shell.detent.lowered { shell.detent = down }
                    @unknown default: break
                    }
                }
            }
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

    /// The pill carries both the tabs and the search button. The list ends above it and fades out there, as
    /// in the iPhone sheet: no row draws under the glass.
    private var listRoot: some View {
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

/// The panel over the globe, a sheet that rises from the window's bottom edge as on the iPhone (owner's call,
/// 2026-11-08): the sheet's colour, rounded at the top only, running down under the home indicator. The
/// content keeps the bottom safe area; only the sheet's surface reaches the edge.
private struct PanelChrome: ViewModifier {
    private static var shape: UnevenRoundedRectangle {
        let r = RegularHomeView<EmptyView, EmptyView>.panelRadius
        return UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .frame(width: RegularHomeView<EmptyView, EmptyView>.panelWidth)
            .frame(maxHeight: .infinity)
            .clipShape(Self.shape)
            .background {
                Self.shape.fill(Theme.background)
                    .overlay { Self.shape.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
    }
}
