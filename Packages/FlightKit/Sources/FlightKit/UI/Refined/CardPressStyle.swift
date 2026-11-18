import SwiftUI

// Contract
// - Name: CardPressStyle (ButtonStyle), `.cardPress(cornerRadius:)`.
// - Use: any tappable card or tile (Passport cards, `RefinedCard(action:)`, action bar items) (I15).
// - Variants: `cornerRadius` sets the hit shape (Theme.Radius.card by default, 20 for Passport cards).
// - States: rest; pressed = 0.98 scale and 6 % darker; disabled is the caller's `.disabled`, drawn dimmed.
// - Tokens: Theme.Radius.card.
// - A11y: changes nothing VoiceOver reads; the hit area is the whole rounded shape.
// - Reduce Motion: the press only darkens, no scale.
// - Previews: below.

/// A card as a button: it dims and sinks a little while pressed.
public struct CardPressStyle: ButtonStyle {
    var cornerRadius: CGFloat

    /// - Parameter cornerRadius: the card's corner radius in reference points, for the hit shape.
    public init(cornerRadius: CGFloat = Theme.Radius.card) { self.cornerRadius = cornerRadius }

    public func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Pressed: View {
        var configuration: Configuration
        var cornerRadius: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.metricsScale) private var scale

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .brightness(pressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: pressed)
                .contentShape(RoundedRectangle(cornerRadius: Theme.metric(cornerRadius, scale), style: .continuous))
        }
    }
}

public extension ButtonStyle where Self == CardPressStyle {
    /// `CardPressStyle` with the card radius.
    static var cardPress: CardPressStyle { CardPressStyle() }
}

#Preview("Card press") {
    VStack(spacing: 12) {
        Button {} label: {
            RefinedCard { Text("Press me").themeFont(.body) }
        }
        .buttonStyle(.cardPress)
        RefinedCard(action: {}) { Text("Tappable card").themeFont(.body) }
        Button {} label: {
            RefinedCard { Text("Disabled").themeFont(.body) }
        }
        .buttonStyle(.cardPress)
        .disabled(true)
    }
    .padding(20)
    .background(Theme.background)
}
