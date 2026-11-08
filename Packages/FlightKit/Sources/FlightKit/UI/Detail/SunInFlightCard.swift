import SwiftUI

/// The flight sheet's sunrises and sunsets as seen from the plane (`SunInFlight`, `SunFacts`): one line
/// each, "Sunset over the North Atlantic at 19:42 Paris time". Hidden when the trip has none.
struct SunInFlightCard: View {
    var lines: [SunFacts.Line]

    var body: some View {
        DetailCard {
            CardTitle(SunFacts.title, subtitle: SunFacts.subtitle)
                .scaledPadding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: line.kind == .sunrise ? "sunrise.fill" : "sunset.fill")
                            .symbolRenderingMode(.multicolor)
                            .scaledFont(19, weight: .medium)
                            .accessibilityHidden(true)
                        Text(verbatim: line.text)
                            .scaledFont(17, weight: .medium)
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(ui: SunFacts.caption)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Sun in flight") {
    SunInFlightCard(lines: [
        .init(kind: .sunset, time: .now, text: "Sunset over the North Atlantic at 21:41 New York time"),
        .init(kind: .sunrise, time: .now.addingTimeInterval(30_000), text: "Sunrise over Greece at 06:02 Tel Aviv time"),
    ])
    .padding()
    .background(Theme.background)
}
#endif
