import SwiftUI

/// The flight's CO2 for one passenger: the figure, the seat class it is for and where the factors come
/// from (docs/co2-method.md). A plain estimate: nothing to buy, no comparison.
struct EmissionsCard: View {
    var kilograms: Double
    var seatClass: SeatClass?

    var body: some View {
        DetailCard {
            CardTitle(EmissionsFacts.title, subtitle: "Estimate for this flight")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: EmissionsFacts.amount(kilograms))
                    .scaledFont(34, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                Text("CO2e")
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.secondary)
            }
            .scaledPadding(.top, 12)
            Text(verbatim: EmissionsFacts.basis(seatClass))
                .scaledFont(15)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 4)
            Text(ui: EmissionsFacts.source)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 6)
        }
        .accessibilityElement(children: .combine)
    }
}
