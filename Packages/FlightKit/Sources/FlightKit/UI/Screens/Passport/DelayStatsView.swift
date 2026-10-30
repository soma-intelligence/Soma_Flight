import SwiftUI

/// Delay stats, opened from the delays card: the hours lost as the hero, then how late the delayed
/// flights were, how many of the flights were delayed and the average over every flight, then the ten
/// flights that left latest. The figures are the core's (`PassportStats`); the list order is the store's.
struct DelayStatsView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    /// The dark red page.
    static let page = Color(red: 0.20, green: 0.05, blue: 0.06)
    static let tile = Color.white.opacity(0.08)
    static let late = Color(red: 1.0, green: 0.55, blue: 0.48)

    var body: some View {
        let stats = store.stats
        FullPageChrome(title: FullPage.delays.title, year: $store.year, years: store.years, scheme: .dark,
                       page: Self.page, shareKey: store.revision, onClose: onClose) {
            DelaysCard(stats: stats).face(row: false)
        } content: {
            figures(stats)
            mostDelayed
        }
    }

    // MARK: Figures

    private func figures(_ s: PassportStats) -> some View {
        HStack(alignment: .top, spacing: 8) {
            tile("Average delay", s.delayedFlights > 0 ? Format.minutes(s.avgDelayedMinutes) : "None",
                 caption: "of delayed flights")
            tile("Delayed", DelayFacts.share(delayed: s.delayedFlights, of: s.flights),
                 caption: DelayFacts.shareCaption(delayed: s.delayedFlights, of: s.flights))
            tile("Per flight", Format.minutes(s.avgDelayMinutes), caption: "on average")
        }
    }

    private func tile(_ label: String, _ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .scaledFont(26, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledPadding(.horizontal, 12)
        .scaledPadding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.tile))
        .accessibilityElement(children: .combine)
    }

    // MARK: Most delayed flights

    @ViewBuilder private var mostDelayed: some View {
        let flights = store.mostDelayed
        VStack(alignment: .leading, spacing: 0) {
            Text("Most delayed flights")
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
                .scaledPadding(.bottom, 6)
            if flights.isEmpty {
                Text(store.year.map { "No delayed flights in \(String($0))" } ?? "No delayed flights yet")
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
                    .scaledPadding(.vertical, 12)
            } else {
                ForEach(Array(flights.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Hairline() }
                    DelayedFlightRow(flight: f, origin: lookup(f.originIcao), destination: lookup(f.destinationIcao))
                }
            }
        }
        .scaledPadding(.top, 10)
    }
}

/// "UA 1882", "SFO → DEN", the date, and how late it left on the right.
struct DelayedFlightRow: View {
    var flight: PastFlight
    var origin: Airport?
    var destination: Airport?

    var body: some View {
        HStack(spacing: 12) {
            AirlineMark(code: TravelFacts.airlineCode(ident: flight.ident), key: flight.airline ?? flight.ident, decorative: true)
                // The page's own red, for the mark's contrast check.
                .environment(\.logoSurface, .fixed(0x330D0F))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(Format.ident(flight.ident)).scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary)
                    Text("\(origin?.iata ?? flight.originIcao) \u{2192} \(destination?.iata ?? flight.destinationIcao)")
                        .scaledFont(15)
                        .foregroundStyle(Theme.secondary)
                }
                Text(ScreenFormat.day(flight.date, origin?.timeZone ?? TimeZone(identifier: flight.originTz ?? "UTC") ?? .gmt))
                    .scaledFont(13)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Text("+\(Format.minutes(flight.delayMinutes))")
                .scaledFont(17, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(DelayStatsView.late)
        }
        .scaledPadding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Copy for the delay page's figures.
enum DelayFacts {
    /// "33%": delayed flights over all flights, rounded half up; "0%" with no flights.
    static func share(delayed: Int, of flights: Int) -> String {
        guard flights > 0 else { return "0%" }
        return "\((delayed * 200 + flights) / (flights * 2))%"
    }

    /// "14 of 42 flights".
    static func shareCaption(delayed: Int, of flights: Int) -> String {
        "\(delayed) of \(flights == 1 ? "1 flight" : "\(flights) flights")"
    }
}
