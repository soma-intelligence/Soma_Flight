import SwiftUI

/// One button of a `MapControlCapsule`: a symbol (or a short word such as "3D"), its spoken label, and an
/// optional selected or live state drawn in the accent colour.
public struct MapControlItem: Identifiable {
    public var id: String { label }
    var label: String
    var systemImage: String?
    var glyph: String?
    var isSelected: Bool
    var behavior: RefinedControlBehavior

    /// A symbol button.
    public init(_ label: String, systemImage: String, isSelected: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.systemImage = systemImage; self.isSelected = isSelected; behavior = .action(action)
    }

    /// A word button, such as "3D" or "2D".
    public init(_ label: String, glyph: String, isSelected: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.glyph = glyph; self.isSelected = isSelected; behavior = .action(action)
    }

    /// A symbol button that opens a menu (the map style). A static factory, so a trailing closure can never
    /// be taken for the action of `init(_:systemImage:isSelected:action:)`.
    public static func menu<MenuContent: View>(_ label: String, systemImage: String, isSelected: Bool = false,
                                               @ViewBuilder content: () -> MenuContent) -> MapControlItem {
        var item = MapControlItem(label, systemImage: systemImage, isSelected: isSelected) {}
        item.behavior = .menu(AnyView(content()))
        return item
    }
}

/// The map's controls as one vertical Liquid Glass capsule of 44 pt buttons, top right (R2): 2D/3D, map
/// style, Live, location. Thin dividers separate the buttons.
/// Penpot: Map controls
public struct MapControlCapsule: View {
    var items: [MapControlItem]
    @Environment(\.metricsScale) private var scale

    public init(_ items: [MapControlItem]) { self.items = items }

    public var body: some View {
        let side = Theme.metric(44, scale)
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                control(item, side: side)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Theme.primary.opacity(0.12))
                        .frame(width: Theme.metric(24, scale), height: 0.5)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(Theme.metric(2, scale))
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder private func control(_ item: MapControlItem, side: CGFloat) -> some View {
        switch item.behavior {
        case .action(let action):
            Button(action: action) { face(item, side: side) }
                .buttonStyle(.plain)
                .pointerHighlight(Circle())
                .modifier(ControlAccessibility(item: item))
        case .menu(let content):
            Menu { content } label: { face(item, side: side) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .pointerHighlight(Circle())
                .modifier(ControlAccessibility(item: item))
        }
    }

    private func face(_ item: MapControlItem, side: CGFloat) -> some View {
        Group {
            if let glyph = item.glyph {
                Text(verbatim: glyph).font(.system(size: Theme.fontSize(15, scale), weight: .bold))
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage).font(.system(size: Theme.fontSize(17, scale), weight: .semibold))
            }
        }
        .foregroundStyle(item.isSelected ? Theme.accent : Theme.primary)
        .frame(width: side, height: side)
        .contentShape(Circle())
    }
}

private struct ControlAccessibility: ViewModifier {
    var item: MapControlItem

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text(ui: item.label))
            .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }
}

#Preview("Map controls") {
    ZStack(alignment: .topTrailing) {
        Theme.background.ignoresSafeArea()
        MapControlCapsule([
            MapControlItem("Switch to 2D", glyph: "3D", action: {}),
            .menu("Map style", systemImage: "map") {
                Button("Satellite") {}
                Button("Standard") {}
            },
            MapControlItem("Live", systemImage: "dot.radiowaves.left.and.right", isSelected: true, action: {}),
            MapControlItem("Location", systemImage: "location", action: {}),
        ])
        .padding(16)
    }
}
