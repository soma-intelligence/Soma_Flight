import SwiftUI

/// The full Passport, opened from the passport card. For now the top bar, the year chips and the card
/// as its hero; the map, the flights, distance and time sections (plan Task 20) and the rankings,
/// countries and regions (Task 21) go under the hero, in `sections`.
struct FullPassportView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void
    @Environment(\.units) private var units

    /// The page colour behind the card.
    static let page = Color(red: 0.10, green: 0.05, blue: 0.36)

    var body: some View {
        FullPageChrome(title: FullPage.passport.title, year: $store.year, years: store.years, scheme: .dark,
                       page: Self.page, shareKey: store.revision, onClose: onClose) {
            PassportCard(stats: store.stats, year: store.year, units: units).face(row: false)
        } content: {
            sections
        }
    }

    /// Filled by plan Tasks 20 and 21.
    @ViewBuilder private var sections: some View {
        EmptyView()
    }
}
