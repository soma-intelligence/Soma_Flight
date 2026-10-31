import SwiftUI

/// How a card moves in a sheet: up from the bottom over the screen below, and back down when it closes,
/// as a place card does in Maps. A spring with no bounce.
public enum CardMotion {
    public static let animation = Animation.spring(duration: 0.42, bounce: 0)
    @MainActor public static var transition: AnyTransition { .move(edge: .bottom) }
}

/// A stack of screens inside a sheet: the root, then one card per entry of `path`, each sliding up over
/// the one below and down again when it leaves. Cards below the top stay alive (their scroll position
/// and loaded data are kept for the way back) but are hidden from VoiceOver and taps. VoiceOver is told
/// the screen changed, and its escape gesture (two-finger scrub) closes the top card.
public struct CardStack<Route: Hashable, Root: View, Card: View>: View {
    var path: [Route]
    var onPop: () -> Void
    var root: Root
    var card: (Route) -> Card

    /// - Parameters:
    ///   - path: the cards above the root, the last on top.
    ///   - onPop: closes the top card (VoiceOver's escape gesture).
    public init(path: [Route], onPop: @escaping () -> Void, @ViewBuilder root: () -> Root,
                @ViewBuilder card: @escaping (Route) -> Card) {
        self.path = path; self.onPop = onPop; self.root = root(); self.card = card
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
            ForEach(Self.entries(path), id: \.self) { entry in
                card(entry.route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .covered(entry.depth < path.count)
                    .accessibilityAction(.escape) { onPop() }
                    // A leaving card stays above the one it uncovers until it is gone.
                    .zIndex(Double(entry.depth))
                    .transition(CardMotion.transition)
            }
        }
        .animation(CardMotion.animation, value: path)
        .onChange(of: path) {
            #if os(iOS)
            AccessibilityNotification.ScreenChanged().post()
            #endif
        }
    }
}

private extension View {
    /// A screen under another card: kept, but out of reach of taps and VoiceOver.
    func covered(_ covered: Bool) -> some View {
        allowsHitTesting(!covered)
            .accessibilityHidden(covered)
    }
}
