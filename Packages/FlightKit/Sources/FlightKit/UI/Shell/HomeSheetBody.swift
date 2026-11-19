import SwiftUI

/// A tab's screen in the iOS home sheet, over the floating tab pill: the screen's header stays pinned at
/// the sheet's top, its list ends above the pill and is masked there, so nothing draws under the glass in
/// any detent: it fades out softly into the sheet above the pill, with no edge and no band. Changing tab slides the screens sideways, in
/// the pill's order (My Flights, Friends, Passport), the way a pager turns. Each tab keeps its screen once
/// shown (`TabPager`), so its scroll position survives a trip to another tab (I10).
public struct HomeSheetBody<Content: View, Toast: View>: View {
    @Binding var tab: HomeTab
    var onSearch: () -> Void
    var onReselect: (() -> Void)?
    var scrollSignals: [HomeTab: Int]
    var content: (HomeTab) -> Content
    var toast: Toast
    /// The pill's height above the sheet's bottom safe area, where the list is masked off.
    @State private var pillHeight = SheetGeometry.tabBarHeight

    /// - Parameters:
    ///   - onReselect: the selected tab was tapped again (I10): the shell pops its cards or bumps
    ///     `scrollSignals` for that tab.
    ///   - scrollSignals: per tab, a counter whose change scrolls that tab's list to its top.
    ///   - content: a tab's screen, its header first.
    ///   - toast: floats 12 pt over the pill.
    public init(tab: Binding<HomeTab>, onSearch: @escaping () -> Void, onReselect: (() -> Void)? = nil,
                scrollSignals: [HomeTab: Int] = [:], @ViewBuilder content: @escaping (HomeTab) -> Content,
                @ViewBuilder toast: () -> Toast) {
        _tab = tab; self.onSearch = onSearch; self.onReselect = onReselect; self.scrollSignals = scrollSignals
        self.content = content; self.toast = toast()
    }

    /// One screen for the selected tab (snapshots, previews): the same view whatever the tab.
    public init(tab: Binding<HomeTab>, onSearch: @escaping () -> Void, @ViewBuilder content: () -> Content,
                @ViewBuilder toast: () -> Toast) {
        let screen = content()
        self.init(tab: tab, onSearch: onSearch, content: { _ in screen }, toast: toast)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Exactly the sheet's size down to its bottom edge, the screen hung from its top: a sheet too short
            // for the screen cuts it at the bottom, under the fade, never the header. The list keeps its insets
            // for the pill and the home indicator but draws on under them, fading out.
            Color.clear
                .overlay(alignment: .top) {
                    TabPager(tab: tab, scrollSignals: scrollSignals, content: content)
                }
                .clipped()
                // A long soft fade that starts above the pill and is gone by the pill's middle: the last rows
                // melt into the sheet, nothing reads through the glass, and no edge shows.
                .pillFade(pillHeight: pillHeight, reachesIntoInset: true)
                .ignoresSafeArea(.container, edges: .bottom)
            // The pill reaches 14 pt into the home indicator inset (34 pt on Face ID iPhones), so it sits
            // 20 pt above the sheet's bottom edge as in the reference.
            HomeTabPill(tab: $tab, bottom: -14, onSearch: onSearch, onReselect: onReselect)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                .overlay(alignment: .top) {
                    toast.alignmentGuide(.top) { $0[.bottom] + 12 }
                }
        }
    }
}

/// The three tab screens stacked, the selected one in view (I10). A tab's screen is built the first time it
/// is shown and then kept, so its scroll position and loaded state survive a trip to another tab;
/// `.id(tab)` used to rebuild it. Hidden tabs take no taps and are hidden from VoiceOver.
///
/// A tab change is a short slide and a crossfade in the pill's order: the screen leaving drifts a quarter of
/// the width away and fades, the one arriving drifts in from that side as it appears. The distance is the
/// same for a neighbour and for the far tab (My Flights to Passport), so every change looks alike; the sheet
/// keeps its height (`ShellModel.showTab`) and the headers sit at one height (`SheetHeader.rootTop`).
/// Reduce Motion keeps the crossfade only.
public struct TabPager<Content: View>: View {
    var tab: HomeTab
    var scrollSignals: [HomeTab: Int]
    var content: (HomeTab) -> Content
    @State private var shown: Set<HomeTab> = []
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tab: HomeTab, scrollSignals: [HomeTab: Int] = [:], @ViewBuilder content: @escaping (HomeTab) -> Content) {
        self.tab = tab; self.scrollSignals = scrollSignals; self.content = content
    }

    /// Where a tab sits against the selected one: -1 to its left, 0 in view, 1 to its right (the far tab
    /// counts as one away too, so it travels the same distance).
    static func slot(of t: HomeTab, selected: HomeTab) -> Int {
        let order = HomeTab.allCases
        let gap = (order.firstIndex(of: t) ?? 0) - (order.firstIndex(of: selected) ?? 0)
        return gap.signum()
    }

    /// How far a screen out of view sits, as a share of the width: a short drift, not a full page turn.
    static var drift: CGFloat { 0.25 }

    public var body: some View {
        ZStack(alignment: .top) {
            ForEach(HomeTab.allCases, id: \.self) { t in
                if t == tab || shown.contains(t) {
                    let current = t == tab
                    content(t)
                        .environment(\.scrollToTopSignal, scrollSignals[t, default: 0])
                        .offset(x: reduceMotion ? 0 : CGFloat(Self.slot(of: t, selected: tab)) * width * Self.drift)
                        .opacity(current ? 1 : 0)
                        .allowsHitTesting(current)
                        .accessibilityHidden(!current)
                        .zIndex(current ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : HomeTab.switchAnimation, value: tab)
        .onChange(of: tab, initial: true) { _, t in shown.insert(t) }
    }
}
