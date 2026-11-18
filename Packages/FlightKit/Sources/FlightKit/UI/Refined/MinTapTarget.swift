import SwiftUI

// Contract
// - Name: `.minTapTarget(_:shape:)` (I8).
// - Use: any control whose drawn face is under 44 x 44 pt (a small "+", a text button, a 32 pt circle).
// - Variants: the side (44 by default) and the hit shape (a rectangle by default).
// - States: none; it only grows the frame and the hit area, never the drawing.
// - Tokens: 44 pt (Apple HIG), scaled by `metricsScale` for the Mac panel.
// - A11y: the larger frame is also the VoiceOver focus frame.
// - Reduce Motion: n/a.
// - Previews: below.

/// Grows a control's frame and hit area to at least `side` x `side` without changing how it looks.
struct MinTapTarget<S: Shape>: ViewModifier {
    var side: CGFloat
    var shape: S
    @Environment(\.metricsScale) private var scale

    func body(content: Content) -> some View {
        content
            .frame(minWidth: Theme.metric(side, scale), minHeight: Theme.metric(side, scale))
            .contentShape(shape)
    }
}

public extension View {
    /// At least 44 x 44 pt of frame and hit area (scaled for the Mac panel), the drawing unchanged.
    func minTapTarget(_ side: CGFloat = 44) -> some View {
        modifier(MinTapTarget(side: side, shape: Rectangle()))
    }

    /// `minTapTarget(_:)` with a hit shape (a `Circle()` for a round control).
    func minTapTarget<S: Shape>(_ side: CGFloat = 44, shape: S) -> some View {
        modifier(MinTapTarget(side: side, shape: shape))
    }
}

#Preview("Min tap target") {
    HStack(spacing: 20) {
        Button {} label: { Image(systemName: "plus").scaledFont(15, weight: .semibold) }
            .buttonStyle(.plain)
            .minTapTarget()
            .border(.red.opacity(0.4))
        Button("Change") {}
            .buttonStyle(.plain)
            .minTapTarget()
            .border(.red.opacity(0.4))
    }
    .padding()
}
