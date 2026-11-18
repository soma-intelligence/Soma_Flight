import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How a card opens over the screen below it (owner's call, 2026-11-08): it rises from the bottom like a
/// sheet on a critically damped spring, and the screen under it dims; closing, it drops back down. Only a
/// move and an opacity animate: no shadow, mask or scale, which would redraw the whole card every frame.
///
/// Under Reduce Motion the card crossfades instead of rising (A5).
public enum CardMotion {
    public static let animation = Animation.spring(duration: 0.42, bounce: 0)

    /// The card's transition for the system's current Reduce Motion setting. Views that already read
    /// `accessibilityReduceMotion` from the environment should prefer `transition(reduceMotion:)`.
    @MainActor public static var transition: AnyTransition {
        transition(reduceMotion: systemReduceMotion)
    }

    /// A rise from the bottom, or a plain crossfade when `reduceMotion`.
    public static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom)
    }

    /// The system's Reduce Motion setting, read at call time.
    @MainActor static var systemReduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
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
    /// How far the leading edge swipe has pulled the top card, in points.
    @State private var pull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A swipe from the leading edge past this distance (or flung past twice it) closes the top card.
    static var closeDistance: CGFloat { 90 }

    /// - Parameters:
    ///   - path: the cards above the root, the last on top.
    ///   - onPop: closes the top card (VoiceOver's escape gesture, the swipe back from the leading edge).
    ///   - zoomID: the id of the row a route's card zooms out of and back into, like the iOS zoom
    ///     transition: the row grows into the card, and a swipe from the leading edge shrinks it back.
    ///     nil (the default) keeps the crossfade for that card.
    public init(path: [Route], onPop: @escaping () -> Void,
                zoomID: @escaping (Route) -> AnyHashable? = { _ in nil },
                @ViewBuilder root: () -> Root, @ViewBuilder card: @escaping (Route) -> Card) {
        self.path = path; self.onPop = onPop; self.zoomID = zoomID; self.root = root(); self.card = card
    }

    /// The transition of a card: it rises from the bottom (the zoom out of its row is no longer used), or
    /// crossfades under Reduce Motion.
    @MainActor func transition(for route: Route) -> AnyTransition {
        CardMotion.transition(reduceMotion: reduceMotion)
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
                .modifier(EasedBack(on: !path.isEmpty))
            ForEach(Self.entries(path), id: \.self) { entry in
                let top = entry.depth == path.count
                card(entry.route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .modifier(PullBack(pull: top ? pull : 0, width: size.width))
                    // Every card on top closes with a swipe from the leading edge, as a pushed screen does (I10).
                    .overlay(alignment: .leading) {
                        if top { edgeSwipe }
                    }
                    .covered(entry.depth < path.count)
                    .modifier(EasedBack(on: entry.depth < path.count))
                    .accessibilityAction(.escape) { onPop() }
                    // A leaving card stays above the one it uncovers until it is gone.
                    .zIndex(Double(entry.depth))
                    // A leaving card takes no taps: they reach the screen it uncovers.
                    .transition(transition(for: entry.route)
                        .combined(with: .modifier(active: HitTesting(on: false), identity: HitTesting(on: true))))
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
    /// A strip along the leading edge of the top card: pulling it shrinks the card, letting go past
    /// `closeDistance` closes it. Only a mostly horizontal pull counts, so a scroll that starts at the
    /// edge still scrolls.
    private var edgeSwipe: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        guard value.translation.width > abs(value.translation.height) || pull > 0 else { return }
                        pull = max(value.translation.width, 0)
                    }
                    .onEnded { value in
                        let close = pull > 0 && (value.translation.width > Self.closeDistance
                            || value.predictedEndTranslation.width > Self.closeDistance * 2)
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

/// A screen with a card over it: dimmed, as under an iOS sheet. Only a flat overlay's opacity animates.
private struct EasedBack: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        content
            .overlay { Color.black.opacity(on ? 0.3 : 0).allowsHitTesting(false) }
    }
}

private extension View {
    /// A screen under another card: kept, but out of reach of taps and VoiceOver.
    func covered(_ covered: Bool) -> some View {
        allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}

/// Turns hit testing off on a card while a transition removes it.
private struct HitTesting: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View { content.allowsHitTesting(on) }
}
