import SwiftUI

/// Keeps a tab's list out from under the floating tab pill: the list gets a bottom inset of the pill's height
/// and a soft mask that starts `fade` above the pill and is gone by the pill's middle, so the last rows melt
/// away and nothing reads through the glass. Shared by the iPhone sheet, the Duo's upright pane and the
/// sideways panel.
public struct PillFadeMask: ViewModifier {
    /// The pill's measured height.
    public var pillHeight: CGFloat
    /// The pill reaches 14 pt into the bottom safe area (the sheet), so the clear part counts that inset.
    public var reachesIntoInset: Bool

    /// How far above the pill's top the list starts to fade.
    public static var fade: CGFloat { 44 }
    /// How far the sheet's pill reaches into the home indicator inset.
    public static var inset: CGFloat { 14 }

    /// The height of the gradient: the fade above the pill plus the pill's upper half.
    public static func fadeHeight(pillHeight: CGFloat) -> CGFloat { fade + pillHeight * 0.5 }

    /// The fully clear part at the bottom, from the pill's middle down.
    public static func clearHeight(pillHeight: CGFloat, bottomInset: CGFloat, reachesIntoInset: Bool) -> CGFloat {
        max(0, pillHeight * 0.5 + (reachesIntoInset ? bottomInset - inset : 0))
    }

    public init(pillHeight: CGFloat, reachesIntoInset: Bool) {
        self.pillHeight = pillHeight; self.reachesIntoInset = reachesIntoInset
    }

    public func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, pillHeight)
            .mask {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black.opacity(0.35), location: 0.55),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.fadeHeight(pillHeight: pillHeight))
                        Color.clear.frame(height: Self.clearHeight(pillHeight: pillHeight,
                                                                   bottomInset: geo.safeAreaInsets.bottom,
                                                                   reachesIntoInset: reachesIntoInset))
                    }
                }
            }
    }
}

public extension View {
    /// Insets the view's bottom by the pill's height and fades it out over the pill (see `PillFadeMask`).
    func pillFade(pillHeight: CGFloat, reachesIntoInset: Bool = false) -> some View {
        modifier(PillFadeMask(pillHeight: pillHeight, reachesIntoInset: reachesIntoInset))
    }
}
