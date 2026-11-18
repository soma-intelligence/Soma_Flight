import SwiftUI

/// What a refined control does when tapped: run an action, or open a menu.
enum RefinedControlBehavior {
    case action(() -> Void)
    case menu(AnyView)
}

/// One item of a `GlassActionBar`: a symbol over a short label, running an action or opening a menu.
public struct GlassActionItem: Identifiable {
    public var id: String { label }
    var label: String
    var systemImage: String
    var tint: Color?
    var behavior: RefinedControlBehavior

    /// - Parameter tint: the symbol and label colour (an alert that is on); primary when nil.
    public init(_ label: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.label = label; self.systemImage = systemImage; self.tint = tint; behavior = .action(action)
    }

    private init(_ label: String, systemImage: String, tint: Color?, behavior: RefinedControlBehavior) {
        self.label = label; self.systemImage = systemImage; self.tint = tint; self.behavior = behavior
    }

    /// An item that opens a menu (More). A static factory, so a trailing closure can never be taken for the
    /// action of `init(_:systemImage:tint:action:)`.
    public static func menu<MenuContent: View>(_ label: String, systemImage: String, tint: Color? = nil,
                                               @ViewBuilder content: () -> MenuContent) -> GlassActionItem {
        GlassActionItem(label, systemImage: systemImage, tint: tint, behavior: .menu(AnyView(content())))
    }
}

// Contract
// - Name: the action bar family (A9). `GlassActionBar` (items), `GlassActionBarContainer` (view builder, for a
//   `ShareLink` or any custom control), `GlassActionLabel` (one item's face), `refinedActionBar(_:)` and
//   `detailActionBar(shown:_:)` (pin it), `refinedActionBarInset()` (pad the scroll content).
// - Variants: 2 to 5 items, each an action, a menu, or (container only) any view whose label is a
//   `GlassActionLabel`.
// - States: an item's `tint` (an alert that is on); pressed = `CardPressStyle`; disabled = `.disabled` dims it.
// - Tokens: GlassActionBar.height 64, itemWidth 92, Theme.gutter, Theme.primary.
// - A11y: each item is labelled with its title. At accessibility text sizes the labels drop and only the
//   symbols show, with the large content viewer (long press) giving the title back (A12).
// - Reduce Motion: `detailActionBar(shown:)` fades in place instead of rising.
// - Previews: below.

/// The Liquid Glass action bar pinned above the home indicator (R4): one capsule of 64 pt tall items, a
/// symbol over a label. Place it with `refinedActionBar(_:)` and pad the scroll content with
/// `refinedActionBarInset()` so the last card ends above it. For items that are not plain actions or
/// menus (a `ShareLink`), build the bar with `GlassActionBarContainer` and `GlassActionLabel`.
/// Penpot: Action bar
public struct GlassActionBar: View {
    /// The bar's height in reference points, before Dynamic Type and `metricsScale`.
    public static let height: CGFloat = 64
    /// The width each item gets, in reference points; the bar never grows past the sheet's card width.
    static let itemWidth: CGFloat = 92

    var items: [GlassActionItem]

    public init(_ items: [GlassActionItem]) { self.items = items }

    public var body: some View {
        GlassActionBarContainer(count: items.count) {
            ForEach(items) { item in
                control(item)
            }
        }
    }

    @ViewBuilder private func control(_ item: GlassActionItem) -> some View {
        let face = GlassActionLabel(title: item.label, systemImage: item.systemImage, tint: item.tint)
        switch item.behavior {
        case .action(let action):
            Button(action: action) { face }
        case .menu(let content):
            Menu { content } label: { face }
                .menuStyle(.button)
        }
    }
}

/// The action bar's capsule around any controls (A9): the same 64 pt Liquid Glass capsule and 92 pt item
/// share as `GlassActionBar`, built from views so an item can be a `ShareLink`. Give each control a
/// `GlassActionLabel` as its label; buttons inside get `CardPressStyle`.
/// Penpot: Action bar
public struct GlassActionBarContainer<Content: View>: View {
    /// How many items the bar holds, for its width.
    var count: Int
    var content: Content
    @Environment(\.metricsScale) private var scale
    @ScaledMetric(relativeTo: .caption2) private var barHeight = GlassActionBar.height

    public init(count: Int, @ViewBuilder content: () -> Content) {
        self.count = count; self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(CardPressStyle(cornerRadius: GlassActionBar.height / 2))
            .scaledPadding(.horizontal, 6)
            .frame(height: Theme.metric(barHeight, scale))
            .frame(maxWidth: Theme.metric(CGFloat(count) * GlassActionBar.itemWidth + 12, scale))
            .glassEffect(.regular.interactive(), in: .capsule)
            .scaledPadding(.horizontal, Theme.gutter)
    }
}

/// One item's face in an action bar: the symbol over its short label, filling its share of the bar. At
/// accessibility text sizes only the symbol shows, and a long press opens the large content viewer with
/// the title (A6, A12).
public struct GlassActionLabel: View {
    var title: String
    var systemImage: String
    var tint: Color?
    @Environment(\.metricsScale) private var scale
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameter tint: the symbol and label colour (an alert that is on); primary when nil.
    public init(title: String, systemImage: String, tint: Color? = nil) {
        self.title = title; self.systemImage = systemImage; self.tint = tint
    }

    public var body: some View {
        let iconOnly = typeSize.isAccessibilitySize
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .scaledFont(19, weight: .semibold)
                .frame(height: Theme.metric(24, scale))
            if !iconOnly {
                Text(ui: title)
                    .scaledFont(11, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(tint ?? Theme.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ui: title))
        .accessibilityShowsLargeContentViewer {
            Label { Text(ui: title) } icon: { Image(systemName: systemImage) }
        }
    }
}

/// The page-coloured fade behind an action bar (Penpot "Bar fade"): content scrolling under the glass
/// dissolves into the page instead of reading through it. It takes no taps.
public struct ActionBarFade: View {
    @Environment(\.metricsScale) private var scale
    @ScaledMetric(relativeTo: .caption2) private var barHeight = GlassActionBar.height

    public init() {}

    public var body: some View {
        LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0),
                               .init(color: Theme.background.opacity(0.85), location: 0.45),
                               .init(color: Theme.background, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Theme.metric(barHeight + 48, scale))
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The scroll content's bottom padding under a `GlassActionBar`: the bar's height plus 16 pt.
struct RefinedActionBarInset: ViewModifier {
    @Environment(\.metricsScale) private var scale
    @ScaledMetric(relativeTo: .caption2) private var barHeight = GlassActionBar.height

    func body(content: Content) -> some View {
        content.padding(.bottom, Theme.metric(barHeight + 16, scale))
    }
}

public extension View {
    /// Pads this content (the inside of the scroll view) by the action bar's height plus 16 pt, so the last
    /// card ends above the bar (R4).
    func refinedActionBarInset() -> some View {
        modifier(RefinedActionBarInset())
    }

    /// Pins a `GlassActionBar` with `items` at the bottom, above the home indicator.
    func refinedActionBar(_ items: [GlassActionItem]) -> some View {
        overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                ActionBarFade()
                GlassActionBar(items)
            }
        }
    }

    /// Pins a custom bar (a `GlassActionBarContainer`) at the bottom, above the home indicator, while
    /// `shown`. It rises in, or fades in place under Reduce Motion (A5).
    func detailActionBar<Bar: View>(shown: Bool, @ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(PinnedActionBar(shown: shown, bar: bar()))
    }
}

/// `detailActionBar(shown:_:)`: the fade and the bar, rising in unless Reduce Motion is on.
private struct PinnedActionBar<Bar: View>: ViewModifier {
    var shown: Bool
    var bar: Bar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if shown {
                ZStack(alignment: .bottom) {
                    ActionBarFade()
                    bar
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

/// The flight and airport sheets' names for the container and the label, from before the merge (A9).
typealias DetailActionBar<Content: View> = GlassActionBarContainer<Content>
typealias DetailActionLabel = GlassActionLabel

#Preview("Action bar") {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(0..<8) { i in
                RefinedCard { Text("Card \(i + 1)").themeFont(.body) }
            }
        }
        .padding(.horizontal, 20)
        .refinedActionBarInset()
    }
    .background(Theme.background)
    .refinedActionBar([
        .menu("More", systemImage: "ellipsis.circle") {
            Button("Copy flight number") {}
            Button("Remove flight", role: .destructive) {}
        },
        GlassActionItem("Alerts", systemImage: "bell", action: {}),
        GlassActionItem("Share", systemImage: "square.and.arrow.up", action: {}),
    ])
}

#Preview("Action bar, view builder") {
    Theme.background
        .detailActionBar(shown: true) {
            GlassActionBarContainer(count: 3) {
                Menu { Button("Copy") {} } label: { GlassActionLabel(title: "More", systemImage: "ellipsis.circle") }
                Button {} label: { GlassActionLabel(title: "Alerts", systemImage: "bell.fill", tint: Theme.accent) }
                ShareLink(item: "AF 84") { GlassActionLabel(title: "Share", systemImage: "square.and.arrow.up") }
            }
        }
}
