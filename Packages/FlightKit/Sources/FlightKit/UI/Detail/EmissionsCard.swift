import SwiftUI

/// The flight's CO2 for one passenger, minimal: the figure and the seat class it is for, in one row. The
/// method is in docs/co2-method.md. A plain estimate: nothing to buy, no comparison.
struct EmissionsCard: View {
    var kilograms: Double
    var seatClass: SeatClass?

    var body: some View {
        DetailCard {
            InfoRow(symbol: "leaf.fill", tint: Theme.onTime,
                    title: "\(EmissionsFacts.amount(kilograms)) CO2e", text: EmissionsFacts.basis(seatClass))
        }
    }
}
