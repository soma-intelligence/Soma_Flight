import SwiftUI

/// The flight sheet's "Along the way": up to eight landmarks the route passes (`Landmarks`, `LandmarkFacts`),
/// each with its side and time, "Mont Blanc on the left at 14:32 Geneva time". Hidden when there are none.
struct LandmarksCard: View {
    var lines: [LandmarkFacts.Line]

    var body: some View {
        DetailCard {
            CardTitle(LandmarkFacts.title, subtitle: LandmarkFacts.subtitle)
                .scaledPadding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: LandmarkFacts.symbol(line.kind))
                            .scaledFont(17, weight: .medium)
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(verbatim: line.text)
                            .scaledFont(17, weight: .medium)
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(ui: LandmarkFacts.caption)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Along the way") {
    LandmarksCard(lines: [
        .init(id: "1", kind: .mountain, side: .left, time: .now, text: "Mont Blanc on the left at 14:32 Geneva time"),
        .init(id: "2", kind: .lake, side: .right, time: .now, text: "Lake Geneva on the right at 14:36 Geneva time"),
        .init(id: "3", kind: .city, side: .below, time: .now, text: "Paris below at 15:02 London time"),
    ])
    .padding()
    .background(Theme.background)
}
#endif
