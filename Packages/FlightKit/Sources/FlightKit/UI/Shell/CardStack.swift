import SwiftUI

/// How a card replaces the screen below it in a sheet: a quick crossfade, the new screen settling from a
/// touch smaller and a few points lower, the old one fading out in place. Nothing slides across the sheet:
/// the sheet stays still and only its content changes, while the globe above does the travelling.
public enum CardMotion {
    public static let animation = Animation.smooth(duration: 0.28)
    @MainActor public static var transition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        .combined(with: .offset(y: 10)),
                    removal: .opacity)
    }
}

/// A stack of screens inside a sheet: the root, then one card per entry of `path`, each fading in over the
/// one below (which fades out) and fading back when it leaves. Cards below the top stay alive (their scroll position
/// and loaded data are kept for the way back) but are hidden from VoiceOver and taps. VoiceOver is told
/// the screen changed, and its escape gesture (two-finger scrub) closes the top card.
public struct CardStack<Route: Hashable, Root: View, Card: View>: View {
    var path: [Route]
    var onPop: () -> Void
    var root: Root
    var card: (Route) -> Card
    /// The row a card zooms out of (`cardZoomSource` with the same id), nil for a card that crossfades.
    var zoomID: (Route) -> AnyHashable?
    @State private var sources = CardZoomSources()
    @State private var size: CGSize = .zero
    /// How far the leading edge swipe has pulled a zoomed card, in points.
    @State private var pull: CGFloat = 0

    /// A swipe from the leading edge past this distance (or flung past twice it) closes a zoomed card.
    static var closeDistance: CGFloat { 90 }

    /// - Parameters:
    ///   - path: the cards above the root, the last on top.
    ///   - onPop: closes the top card (VoiceOver's escape gesture, the swipe back of a zoomed card).
    ///   - zoomID: the id of the row a route's card zooms out of and back into, like the iOS zoom
    ///     transition: the row grows into the card, and a swipe from the leading edge shrinks it back.
    ///     nil (the default) keeps the crossfade for that card.
    public init(path: [Route], onPop: @escaping () -> Void,
                zoomID: @escaping (Route) -> AnyHashable? = { _ in nil },
                @ViewBuilder root: () -> Root, @ViewBuilder card: @escaping (Route) -> Card) {
        self.path = path; self.onPop = onPop; self.zoomID = zoomID; self.root = root(); self.card = card
    }

    /// The transition of a card: the zoom from its row when the row has been laid out, else the crossfade.
    @MainActor func transition(for route: Route) -> AnyTransition {
        guard size.width > 0, let id = zoomID(route), let row = sources.frame(id) else { return CardMotion.transition }
        return .cardZoom(from: row, in: size)
    }

    /// A card's place in the stack: the same route at another depth is another card.
    struct Entry: Hashable {
        var depth: Int
        var route: Route
    }

    static func entries(_ path: [Route]) -> [Entry] {
        path.enumerated().map { Entry(depth: $0.offset + 1, route: $0.element) }
    }

    public var body: some View {
        ZStack {
            root
                .covered(!path.isEmpty)
                .opacity(path.isEmpty ? 1 : 0)
            ForEach(Self.entries(path), id: \.self) { entry in
                let top = entry.depth == path.count
                let zooms = zoomID(entry.route) != nil
                card(entry.route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .modifier(PullBack(pull: top && zooms ? pull : 0, width: size.width))
                    .overlay(alignment: .leading) {
                        if top && zooms { edgeSwipe }
                    }
                    .covered(entry.depth < path.count)
                    .opacity(entry.depth < path.count ? 0 : 1)
                    .accessibilityAction(.escape) { onPop() }
                    // A leaving card stays above the one it uncovers until it is gone.
                    .zIndex(Double(entry.depth))
                    .transition(transition(for: entry.route))
            }
        }
        .coordinateSpace(.named(CardZoomGeometry.space))
        .environment(\.cardZoomSources, sources)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .animation(CardMotion.animation, value: path)
        .onChange(of: path) {
            #if os(iOS)
            AccessibilityNotification.ScreenChanged().post()
            #endif
        }
    }
}

extension CardStack {
    /// A strip along the leading edge of a zoomed card: pulling it shrinks the card, letting go past
    /// `closeDistance` closes it (it then shrinks the rest of the way into its row).
    private var edgeSwipe: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { pull = max($0.translation.width, 0) }
                    .onEnded { value in
                        let close = value.translation.width > Self.closeDistance
                            || value.predictedEndTranslation.width > Self.closeDistance * 2
                        withAnimation(CardMotion.animation) {
                            pull = 0
                            if close { onPop() }
                        }
                    })
            .accessibilityHidden(true)
    }
}

/// A zoomed card while the edge swipe pulls it: a little smaller, nudged along, its corners rounding.
struct PullBack: ViewModifier {
    var pull: CGFloat
    var width: CGFloat

    /// How far along the pull is, 0 to 1 over the stack's width.
    static func progress(pull: CGFloat, width: CGFloat) -> CGFloat {
        width > 0 ? min(max(pull / width, 0), 1) : 0
    }

    func body(content: Content) -> some View {
        let p = Self.progress(pull: pull, width: width)
        content
            .clipShape(PullMask(radius: 28 * min(p * 4, 1)))
            .scaleEffect(1 - 0.25 * p)
            .offset(x: pull * 0.35)
    }
}

/// The card's outline under the pull: rounded while pulled, and cutting nothing at rest.
struct PullMask: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        radius < 0.5 ? Path(rect.insetBy(dx: -10_000, dy: -10_000))
            : Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

private extension View {
    /// A screen under another card: kept, but out of reach of taps and VoiceOver.
    func covered(_ covered: Bool) -> some View {
        allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}
