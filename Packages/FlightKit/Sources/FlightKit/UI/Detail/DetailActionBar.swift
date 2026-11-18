import SwiftUI

/// The flight and airport sheets' Liquid Glass action bar (R4), drawn like the kit's `GlassActionBar` (the
/// same 64 pt capsule, 92 pt items, symbol over label) but built from views, so an item can be a `ShareLink`.
/// The kit's `GlassActionItem` only runs an action or opens a menu, and Share must hand over a Transferable.
/// Pin it with `detailActionBar(shown:_:)` and pad the scroll content with `refinedActionBarInset()`.
/// Penpot: Action bar
struct DetailActionBar<Content: View>: View {
    /// How many items the bar holds, for its width.
    var count: Int
    @ViewBuilder var content: Content
    @Environment(\.metricsScale) private var scale
    // The same scaled height as `GlassActionBar`, so `refinedActionBarInset()` clears this bar too.
    @ScaledMetric(relativeTo: .caption2) private var barHeight = GlassActionBar.height

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(.plain)
            .scaledPadding(.horizontal, 6)
            .frame(height: Theme.metric(barHeight, scale))
            .frame(maxWidth: Theme.metric(CGFloat(count) * GlassActionBar.itemWidth + 12, scale))
            .glassEffect(.regular.interactive(), in: .capsule)
            .scaledPadding(.horizontal, Theme.gutter)
    }
}

/// One item's face in a `DetailActionBar`: the symbol over its short label, filling its share of the bar.
struct DetailActionLabel: View {
    var title: String
    var systemImage: String
    var tint: Color? = nil
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .scaledFont(19, weight: .semibold)
                .frame(height: Theme.metric(24, scale))
            Text(ui: title)
                .scaledFont(11, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint ?? Theme.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

extension View {
    /// Pins a `DetailActionBar` at the bottom, above the home indicator, while `shown`.
    func detailActionBar<Bar: View>(shown: Bool, @ViewBuilder _ bar: () -> Bar) -> some View {
        overlay(alignment: .bottom) {
            if shown {
                ZStack(alignment: .bottom) {
                    ActionBarFade()
                    bar()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
