import SwiftUI

/// Aircraft stats, opened from the most flown aircraft card. For now the top bar, the year chips and
/// the card as its hero; the blueprint panels, types, seats, tails and ages (plan Task 22) go under the
/// hero, in `sections`.
struct AircraftStatsView: View {
    @Bindable var store: PassportStore
    var onClose: () -> Void

    /// The light blue page.
    static let page = Color(red: 0.80, green: 0.87, blue: 0.96)

    var body: some View {
        FullPageChrome(title: FullPage.aircraftStats.title, year: $store.year, years: store.years, scheme: .light,
                       page: Self.page, onClose: onClose) {
            if let most = store.aircraft.mostFlown {
                AircraftCard(typeCode: most.icaoType, type: store.mostFlownType, airline: store.mostFlownAirline,
                             count: Int(most.flights)).face(row: false)
            } else {
                Text("No aircraft flown in this period")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .scaledPadding(.vertical, 60)
            }
        } content: {
            sections
        }
    }

    /// Filled by plan Task 22.
    @ViewBuilder private var sections: some View {
        EmptyView()
    }
}
