import SwiftUI

/// The Year in Review: year chips (years with a flight only), the chosen year's cards one page at a time,
/// and Share for the card shown or for all of them. The cards are drawn on the phone; nothing is uploaded.
struct YearInReviewSheet: View {
    /// The history as the store maps it (`PassportStore.allFlights`).
    var flights: [PastFlight]
    var unit: DistanceUnit
    @State var year: Int?
    @Environment(\.dismiss) private var dismiss

    @State private var page: YearInReview.Card = .flights
    @State private var images: [YearInReviewImage] = []

    private var years: [Int] { YearInReview.years(flights) }
    private var review: YearInReview? { year.flatMap { YearInReview.make(flights, year: $0, now: .now) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if years.count > 1 {
                    YearChips(years: years, selection: $year, allTime: false)
                }
                if let review {
                    TabView(selection: $page) {
                        ForEach(review.cards) { card in
                            YearInReviewCard(card: card, review: review, unit: unit)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .scaleEffect(0.82)
                                .frame(width: YearInReviewCard.size.width * 0.82, height: YearInReviewCard.size.height * 0.82)
                                .accessibilityElement(children: .combine)
                                .tag(card)
                        }
                    }
                    #if os(iOS)
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    #endif
                    shareButtons(review)
                } else {
                    Spacer()
                    Text("No flights this year yet.").foregroundStyle(Theme.secondary)
                    Spacer()
                }
            }
            .scaledPadding(.bottom, 16)
            .background(Theme.background)
            .navigationTitle(Text("Year in Review"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: YearKey(year: year, unit: unit, flights: flights.count)) { render() }
        }
    }

    private struct YearKey: Hashable { var year: Int?; var unit: DistanceUnit; var flights: Int }

    @ViewBuilder private func shareButtons(_ review: YearInReview) -> some View {
        HStack(spacing: 10) {
            if let one = images.first(where: { $0.card == page }) {
                ShareLink(item: one, preview: SharePreview(Text("Year in Review"))) {
                    Label("Share Card", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            if images.count == review.cards.count, images.count > 1 {
                ShareLink(items: images, preview: { _ in SharePreview(Text("Year in Review")) }) {
                    Label("Share All \(images.count)", systemImage: "square.stack")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.passportAccent)
            }
            if images.isEmpty { ProgressView().frame(minHeight: 44) }
        }
        .scaledPadding(.horizontal, 20)
    }

    /// Draws the year's cards at story size, once per year and unit.
    @MainActor private func render() {
        images = []
        guard let review else { return }
        if !review.cards.contains(page) { page = review.cards.first ?? .flights }
        images = review.cards.compactMap { card in
            YearInReviewRender.image(card, review: review, unit: unit).flatMap(YearInReviewRender.png)
                .map { YearInReviewImage(card: card, year: review.year, png: $0) }
        }
    }
}

#if DEBUG
#Preview("Year in Review") {
    YearInReviewSheet(flights: FakeSeed.load("past_flights", as: [PastFlight].self), unit: .km, year: 2025)
}
#endif
