import SwiftUI

/// A tab's screen in the iOS home sheet, over the floating tab pill: the screen's header stays pinned at
/// the sheet's top, its list ends above the pill and is masked there, so nothing draws under the glass in
/// any detent: it fades out softly into the sheet above the pill, with no edge and no band. Changing tab slides the screens sideways, in
/// the pill's order (My Flights, Friends, Passport), the way a pager turns.
public struct HomeSheetBody<Content: View, Toast: View>: View {
    @Binding var tab: HomeTab
    var onSearch: () -> Void
    var content: Content
    var toast: Toast
    /// The pill's height above the sheet's bottom safe area, where the list is masked off.
    @State private var pillHeight = SheetGeometry.tabBarHeight
    /// The last tab change went right (to a later tab in the pill): the new screen comes in from the trailing edge.
    @State private var forward = true

    /// How far above the pill's top the list starts to fade; it is fully clear at the sheet's bottom.
    static var fade: CGFloat { 44 }

    /// - Parameters:
    ///   - content: the tab's screen, its header first.
    ///   - toast: floats 12 pt over the pill.
    public init(tab: Binding<HomeTab>, onSearch: @escaping () -> Void, @ViewBuilder content: () -> Content,
                @ViewBuilder toast: () -> Toast) {
        _tab = tab; self.onSearch = onSearch; self.content = content(); self.toast = toast()
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Exactly the sheet's size down to its bottom edge, the screen hung from its top: a sheet too short
            // for the screen cuts it at the bottom, under the fade, never the header. The list keeps its insets
            // for the pill and the home indicator but draws on under them, fading out.
            Color.clear
                .overlay(alignment: .top) {
                    content
                        .id(tab)
                        .transition(.push(from: forward ? .trailing : .leading))
                }
                .clipped()
                .safeAreaPadding(.bottom, pillHeight)
                .mask {
                    // A long soft fade that starts above the pill and is gone by the pill's middle: the last rows
                    // melt into the sheet, nothing reads through the glass, and no edge shows.
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(stops: [.init(color: .black, location: 0),
                                                   .init(color: .black.opacity(0.35), location: 0.55),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.fade + pillHeight * 0.5)
                            Color.clear.frame(height: max(0, pillHeight * 0.5 + geo.safeAreaInsets.bottom - 14))
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            // The pill reaches 14 pt into the home indicator inset (34 pt on Face ID iPhones), so it sits
            // 20 pt above the sheet's bottom edge as in the reference.
            HomeTabPill(tab: Binding(get: { tab }, set: { new in
                let order = HomeTab.allCases
                forward = (order.firstIndex(of: new) ?? 0) >= (order.firstIndex(of: tab) ?? 0)
                tab = new
            }), bottom: -14, onSearch: onSearch)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                .overlay(alignment: .top) {
                    toast.alignmentGuide(.top) { $0[.bottom] + 12 }
                }
        }
    }
}
