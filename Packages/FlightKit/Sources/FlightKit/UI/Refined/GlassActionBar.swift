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

/// The Liquid Glass action bar pinned above the home indicator (R4): one capsule of 64 pt tall items, a
/// symbol over a label. Place it with `refinedActionBar(_:)` and pad the scroll content with
/// `refinedActionBarInset()` so the last card ends above it.
/// Penpot: Action bar
public struct GlassActionBar: View {
    /// The bar's height in reference points, before Dynamic Type and `metricsScale`.
    public static let height: CGFloat = 64
    /// The width each item gets, in reference points; the bar never grows past the sheet's card width.
    static let itemWidth: CGFloat = 92

    var items: [GlassActionItem]
    @Environment(\.metricsScale) private var scale
    @ScaledMetric(relativeTo: .caption2) private var barHeight = GlassActionBar.height

    public init(_ items: [GlassActionItem]) { self.items = items }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                control(item)
            }
        }
        .scaledPadding(.horizontal, 6)
        .frame(height: Theme.metric(barHeight, scale))
        .frame(maxWidth: Theme.metric(CGFloat(items.count) * Self.itemWidth + 12, scale))
        .glassEffect(.regular.interactive(), in: .capsule)
        .scaledPadding(.horizontal, Theme.gutter)
    }

    @ViewBuilder private func control(_ item: GlassActionItem) -> some View {
        switch item.behavior {
        case .action(let action):
            Button(action: action) { label(item) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ui: item.label))
        case .menu(let content):
            Menu { content } label: { label(item) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ui: item.label))
        }
    }

    private func label(_ item: GlassActionItem) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.systemImage)
                .scaledFont(19, weight: .semibold)
                .frame(height: Theme.metric(24, scale))
            Text(ui: item.label)
                .scaledFont(11, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(item.tint ?? Theme.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
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
}

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
