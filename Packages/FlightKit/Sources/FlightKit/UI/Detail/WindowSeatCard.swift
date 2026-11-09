import SwiftUI

/// The flight sheet's "Window seat", minimal: which side to sit on and why, then the traveller's seat (or the
/// window letter on that side) in one grey line (`WindowAdvisor`, `WindowFacts`). Hidden when neither side
/// stands out.
struct WindowSeatCard: View {
    var card: WindowFacts.Card

    var body: some View {
        DetailCard {
            InfoRow(symbol: card.side == .left ? "arrow.left.circle.fill" : "arrow.right.circle.fill",
                    tint: Theme.accent, title: card.headline, text: card.short)
        }
    }
}

#if DEBUG
#Preview("Window seat") {
    WindowSeatCard(card: .init(side: .left, headline: "Sit on the left for the sunset over the North Atlantic and Mont Blanc",
                               lines: ["Window seats on the left are lettered A on most aircraft.",
                                       "Your seat 23K is on the right. A seat on the left gets the better view."],
                               short: "Your seat 23K is on the right"))
    .padding()
    .background(Theme.background)
}
#endif
