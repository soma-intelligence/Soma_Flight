import SwiftUI

// MARK: - Where rows sit

/// The frames of the rows a card can zoom out of, by id, in the card stack's coordinate space. Written as
/// the rows lay out and read only when a card comes or goes, so it is a plain reference type: a scroll
/// writes frames without redrawing anything.
@MainActor
public final class CardZoomSources {
    private var frames: [AnyHashable: CGRect] = [:]

    public init() {}

    func set(_ id: AnyHashable, _ frame: CGRect?) { frames[id] = frame }
    func frame(_ id: AnyHashable) -> CGRect? { frames[id] }
}

public extension EnvironmentValues {
    /// The card stack's row frames; nil outside a stack that zooms (the rows then do nothing extra).
    @Entry var cardZoomSources: CardZoomSources?
}

extension View {
    /// Marks a row as where the card for `id` zooms out of and back into, inside a `CardStack` that zooms.
    func cardZoomSource(_ id: some Hashable) -> some View {
        modifier(CardZoomSource(id: AnyHashable(id)))
    }
}

private struct CardZoomSource: ViewModifier {
    var id: AnyHashable
    @Environment(\.cardZoomSources) private var sources

    func body(content: Content) -> some View {
        if let sources {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(CardZoomGeometry.space)) } action: {
                    sources.set(id, $0)
                }
                .onDisappear { sources.set(id, nil) }
        } else {
            content
        }
    }
}

// MARK: - The zoom

/// Where a zooming card sits at the row end of its zoom: scaled down to the row's width, its top laid on
/// the row's top, and cut to the row's height with the row's rounded corners. Pure numbers, so tests read them.
struct CardZoomGeometry: Equatable {
    /// The named coordinate space of the stack, which the rows measure their frames in.
    static let space = "cardZoomStack"
    /// The corner radius of the row end of the zoom, in screen points.
    static let rowRadius: CGFloat = 14

    /// The card's scale at the row: the row's width over the stack's.
    var scale: CGFloat
    /// The card's offset at the row, with the scale anchored at its top leading corner.
    var offset: CGSize
    /// The part of the unscaled card that shows at the row (its top, the row's height over the scale).
    var visible: CGRect
    /// The mask's corner radius in the card's own points, so it reads `rowRadius` once scaled.
    var radius: CGFloat

    init(row: CGRect, container: CGSize) {
        let scale = container.width > 0 ? max(row.width, 1) / container.width : 1
        self.scale = scale
        offset = CGSize(width: row.minX, height: row.minY)
        visible = CGRect(x: 0, y: 0, width: container.width, height: min(row.height / scale, container.height))
        radius = Self.rowRadius / scale
    }

    /// The card at full size: nothing moved or cut.
    init(identity container: CGSize) {
        scale = 1
        offset = .zero
        visible = CGRect(origin: .zero, size: container)
        radius = 0
    }
}

/// The card at one end of its zoom (`geometry`), faded by `opacity`: the transition runs between the row
/// end and the identity.
struct CardZoomEffect: ViewModifier {
    var geometry: CardZoomGeometry
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .clipShape(CardZoomMask(visible: geometry.visible, radius: geometry.radius))
            .scaleEffect(geometry.scale, anchor: .topLeading)
            .offset(geometry.offset)
            .opacity(opacity)
    }
}

/// The part of a zooming card that shows. At full size (the whole card, square corners) it cuts nothing,
/// so a card at rest still draws into the safe areas the way it did before it zoomed.
struct CardZoomMask: Shape {
    var visible: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(visible.height, radius), AnimatablePair(visible.width, visible.minY)) }
        set {
            visible = CGRect(x: visible.minX, y: newValue.second.second, width: newValue.second.first,
                             height: newValue.first.first)
            radius = newValue.first.second
        }
    }

    /// True when the mask is the whole card: nothing to cut.
    static func isOpen(visible: CGRect, radius: CGFloat, in rect: CGRect) -> Bool {
        radius < 0.5 && visible.height >= rect.height - 0.5 && visible.width >= rect.width - 0.5
    }

    func path(in rect: CGRect) -> Path {
        if Self.isOpen(visible: visible, radius: radius, in: rect) {
            return Path(rect.insetBy(dx: -10_000, dy: -10_000))
        }
        return Path(roundedRect: visible.offsetBy(dx: rect.minX, dy: rect.minY), cornerRadius: radius, style: .continuous)
    }
}

extension AnyTransition {
    /// The card's opacity at the row: a little of the row shows through as it grows, so the swap of
    /// the row for the card's header reads as one thing turning into the other.
    static let rowOpacity = 0.2

    /// The card grows out of `row` to fill `container`, and shrinks back into it when it leaves.
    @MainActor static func cardZoom(from row: CGRect, in container: CGSize) -> AnyTransition {
        .modifier(active: CardZoomEffect(geometry: CardZoomGeometry(row: row, container: container), opacity: Self.rowOpacity),
                  identity: CardZoomEffect(geometry: CardZoomGeometry(identity: container), opacity: 1))
    }
}

extension SheetRoute {
    /// The id of the row a card zooms out of: a Passport past flight's row. nil for cards that crossfade.
    public var zoomID: AnyHashable? {
        if case .pastFlight(let flight) = self { return AnyHashable(flight.id) }
        return nil
    }
}
