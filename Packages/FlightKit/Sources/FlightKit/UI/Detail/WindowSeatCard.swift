import SwiftUI

/// The flight sheet's "Window seat": which side to sit on for the sunrise or sunset, the landmarks and the
/// shade (`WindowAdvisor`, `WindowFacts`), with the seat letters as a hint and the traveller's own seat when
/// known. Hidden when neither side stands out.
struct WindowSeatCard: View {
    var card: WindowFacts.Card

    var body: some View {
        DetailCard {
            CardTitle(WindowFacts.title, subtitle: WindowFacts.subtitle)
                .scaledPadding(.bottom, 12)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: card.side == .left ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
                    .scaledFont(19, weight: .medium)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(verbatim: card.headline)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.lines, id: \.self) { line in
                    Text(verbatim: line)
                        .scaledFont(15)
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scaledPadding(.top, 10)
            Text(ui: WindowFacts.caption)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Window seat") {
    WindowSeatCard(card: .init(side: .left, headline: "Sit on the left for the sunset over the North Atlantic and Mont Blanc",
                               lines: ["Window seats on the left are lettered A on most aircraft.",
                                       "Your seat 23K is on the right. A seat on the left gets the better view."]))
    .padding()
    .background(Theme.background)
}
#endif
