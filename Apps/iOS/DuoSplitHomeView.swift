import FlightKit
import MapKit
import SwiftUI

/// The home of the unfolded iPhone Duo held upright (about 626 x 890 pt): the globe across the top and,
/// below it, a fixed pane with the tab's screen, the open cards and the tab pill. The sheet that
/// `RootTabView` uses would cover most of a screen this size and hide the globe, so the pane has a fixed
/// height instead and the globe keeps the rest of the screen to itself.
///
/// The pane has no detents, so nothing here sets the sheet's environment values: the screens in it must
/// not offer Expand or Collapse without a sheet.
struct DuoSplitHomeView<TabScreen: View, MapControls: View>: View {
    let home: HomeModel
    @Binding var selection: GlobeSelection?
    var labels: Bool
    var threeD: Bool
    var mapScope: Namespace.ID
    var onSearch: () -> Void
    var onSettings: () -> Void
    var tabScreen: TabScreen
    var mapControls: MapControls
    /// The screen's height and safe areas, measured on a background that ignores them (as in `RootTabView`).
    @State private var metrics = Metrics()

    /// The pane's share of the height between the safe areas.
    static var paneFraction: CGFloat { 0.55 }

    init(home: HomeModel, selection: Binding<GlobeSelection?>, labels: Bool, threeD: Bool, mapScope: Namespace.ID,
         onSearch: @escaping () -> Void, onSettings: @escaping () -> Void,
         @ViewBuilder tabScreen: () -> TabScreen, @ViewBuilder mapControls: () -> MapControls) {
        self.home = home; _selection = selection; self.labels = labels; self.threeD = threeD
        self.mapScope = mapScope; self.onSearch = onSearch; self.onSettings = onSettings
        self.tabScreen = tabScreen(); self.mapControls = mapControls()
    }

    /// The pane's height, with the bottom safe area inside it so the tab pill clears the home indicator.
    private var paneHeight: CGFloat {
        Self.paneFraction * (metrics.height - metrics.safeTop - metrics.safeBottom) + metrics.safeBottom
    }

    var body: some View {
        let content = home.globe
        GlobeMap(routes: content.routes, planes: content.planes, airports: content.airports,
                 selection: $selection, focus: home.focus, recenter: home.shell.recenter, labels: labels,
                 threeD: threeD, isolation: home.isolation, controlsScope: mapScope,
                 airportStatus: content.status)
            // The pane counts as covered, so the camera frames arcs and airports in the globe left above it.
            .safeAreaPadding(.bottom, paneHeight)
            .ignoresSafeArea()
            .background(Color.black)
            .background {
                Color.clear
                    .onGeometryChange(for: Metrics.self) { proxy in
                        Metrics(height: proxy.size.height, safeTop: proxy.safeAreaInsets.top,
                                safeBottom: proxy.safeAreaInsets.bottom)
                    } action: { metrics = $0 }
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) { mapControls }
            .overlay(alignment: .bottom) { pane }
            .mapScope(mapScope)
    }

    /// The tab's screen, with the open cards stacked over it as in the iPhone sheet.
    private var pane: some View {
        let shell = home.shell
        return CardStack(path: shell.path, onPop: shell.close, zoomID: \.zoomID) {
            root
        } card: { route in
            HomeDestination(home: home, route: route)
        }
        .frame(maxWidth: .infinity)
        // The content stops at the bottom safe area, so the tab pill clears the home indicator exactly as
        // it does in the sheet; the background below runs on to the screen's edge.
        .frame(height: paneHeight - metrics.safeBottom)
        .background { paneShape.fill(Theme.background).ignoresSafeArea(edges: .bottom) }
        .mask { paneShape.ignoresSafeArea(edges: .bottom) }
    }

    private var paneShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Theme.sheetRadius, topTrailingRadius: Theme.sheetRadius,
                               style: .continuous)
    }

    private var root: some View {
        tabScreen
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topTrailing) {
                ProfileButton(profile: home.profile, action: onSettings)
                    .padding(.top, 19)
                    .padding(.trailing, 16)
            }
            // `$home` is not available outside `body`, so the pill gets an explicit binding.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    ToastSlot(text: home.toast, isError: home.toastIsError)
                    HomeTabPill(tab: Binding(get: { home.tab }, set: { home.tab = $0 }), bottom: 14,
                                onSearch: onSearch)
                }
            }
    }

    /// What `paneHeight` needs from the screen.
    private struct Metrics: Equatable {
        var height: CGFloat = 0
        var safeTop: CGFloat = 0
        var safeBottom: CGFloat = 0
    }
}

/// Loads the seed-backed fake environment, which is built asynchronously, then shows the Duo home on it.
private struct DuoSplitHomePreview: View {
    @State private var home: HomeModel?
    @State private var selection: GlobeSelection?
    @Namespace private var scope

    var body: some View {
        Group {
            if let home {
                DuoSplitHomeView(home: home, selection: $selection, labels: true, threeD: false, mapScope: scope,
                                 onSearch: {}, onSettings: {}, tabScreen: { Color.clear }, mapControls: { EmptyView() })
            } else {
                Color.black
            }
        }
        .task { home = HomeModel(env: try! await AppEnvironment.fake()) }
    }
}

#Preview("Duo upright") {
    DuoSplitHomePreview().frame(width: 626, height: 890)
}
