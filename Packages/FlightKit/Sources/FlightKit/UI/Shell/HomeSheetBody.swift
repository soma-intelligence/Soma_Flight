import SwiftUI

/// A tab's screen in the iOS home sheet, over the floating tab pill: the screen's header stays pinned at
/// the sheet's top, its list ends above the pill and is masked there, so nothing draws under the glass in
/// any detent. The last points before the pill fade out instead of being cut.
public struct HomeSheetBody<Content: View, Toast: View>: View {
    @Binding var tab: HomeTab
    var onSearch: () -> Void
    var content: Content
    var toast: Toast
    /// The pill's height above the sheet's bottom safe area, where the list is masked off.
    @State private var pillHeight = SheetGeometry.tabBarHeight

    /// How far the list fades out before the pill.
    static var fade: CGFloat { 16 }

    /// - Parameters:
    ///   - content: the tab's screen, its header first.
    ///   - toast: floats 12 pt over the pill.
    public init(tab: Binding<HomeTab>, onSearch: @escaping () -> Void, @ViewBuilder content: () -> Content,
                @ViewBuilder toast: () -> Toast) {
        _tab = tab; self.onSearch = onSearch; self.content = content(); self.toast = toast()
    }

    public var body: some View {
        // Exactly the sheet's size, the screen hung from its top: a sheet too short for the screen cuts it
        // at the bottom, under the mask, never the header.
        Color.clear
            .overlay(alignment: .top) { content }
            .safeAreaPadding(.bottom, pillHeight)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Color.clear.frame(height: pillHeight)
                }
            }
            .overlay(alignment: .bottom) {
                // The pill reaches 14 pt into the home indicator inset (34 pt on Face ID iPhones), so it sits
                // 20 pt above the sheet's bottom edge as in the reference.
                HomeTabPill(tab: $tab, bottom: -14, onSearch: onSearch)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                    .overlay(alignment: .top) {
                        toast.alignmentGuide(.top) { $0[.bottom] + 12 }
                    }
            }
    }
}
