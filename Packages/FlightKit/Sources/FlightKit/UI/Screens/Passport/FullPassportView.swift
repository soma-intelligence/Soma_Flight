import SwiftUI

/// The full Passport, opened from the passport card: a violet top bar and year chips, then the header
/// panel (ticker, route map, flags, the passport card and its machine readable strip) and, on the dark
/// page, the Flights, Flight distance and Flight time sections, then the top airports, airlines and
/// routes, and the countries with the regions grid.
struct FullPassportView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void
    /// The traveller's name for the strip; none yet, so the strip says TRAVELLER.
    var name: String? = nil
    @Environment(\.units) private var units

    /// The page colour behind the header.
    static let page = Theme.passportPage

    var body: some View {
        FullPageChrome(title: "Soma Flight Passport", year: $store.year, years: store.years, scheme: .dark,
                       page: Self.page, shareKey: store.revision, onClose: onClose, bar: Theme.passportBar,
                       sectionBackground: Theme.background, heroInset: 0,
                       chipInk: Color(red: 0.64, green: 0.55, blue: 0.87), chipFill: Theme.passportChip,
                       buttonFill: Color(red: 0x49 / 255, green: 0x21 / 255, blue: 0xB0 / 255)) {
            header
        } content: {
            sections
        }
    }

    private var header: some View {
        let detail = store.detail
        return VStack(spacing: 0) {
            PassportMap(routes: PassportFacts.routes(detail, lookup: lookup),
                        airports: PassportFacts.airports(detail, lookup: lookup),
                        countries: detail.countries.map(\.iso2))
            DashedRule()
                .scaledPadding(.top, 26)
            PassportCard(stats: store.stats, year: store.year, units: units).face(row: false, framed: false)
            MRZStrip(lines: PassportFacts.mrz(name: name, year: store.year, flights: Int(detail.flights), issued: Date.now))
                .scaledPadding(.horizontal, 12)
                .scaledPadding(.bottom, 26)
        }
        // Every figure, date and MRZ character rolls as the year changes.
        .rollingDigits()
        .background(Self.panel)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }

    static var panel: some View {
        LinearGradient(stops: [.init(color: Color(red: 0x27 / 255, green: 0x02 / 255, blue: 0x83 / 255), location: 0),
                               .init(color: Theme.passportPage, location: 0.45),
                               .init(color: Color(red: 0x11 / 255, green: 0x00 / 255, blue: 0x3B / 255), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The sections in a lazy stack: an expanded list can run to a hundred rows or more, so sections off
    /// screen are not built. The rankings are built once per period (and unit) here, not in each section.
    @ViewBuilder private var sections: some View {
        let detail = store.detail
        if detail.flights > 0 {
            let rankings = PassportRankings(detail, units: units.distance, lookup: lookup)
            LazyVStack(alignment: .leading, spacing: 0) {
                PassportFlightsSection(detail: detail)
                PassportDistanceSection(detail: detail, lookup: lookup)
                PassportTimeSection(detail: detail, lookup: lookup)
                PassportAirportsSection(bars: rankings.airports, year: store.year)
                PassportAirlinesSection(rankings: rankings, year: store.year)
                PassportRoutesSection(rankings: rankings, year: store.year)
                PassportCountriesSection(detail: detail, year: store.year)
            }
            .rollingDigits()
        }
    }
}

/// The perforation between the map and the passport card.
private struct DashedRule: View {
    var body: some View {
        Line()
            .stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
            .frame(height: 1.5)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// The passport's machine readable zone under the card: a thin holographic band and the two lines.
struct MRZStrip: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.88, blue: 0.95), Color(red: 0.62, green: 0.45, blue: 0.95),
                                    Color(red: 0.96, green: 0.60, blue: 0.85)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 2)
                .opacity(0.7)
                .scaledPadding(.bottom, 6)
            ForEach(lines, id: \.self) { line in
                Text(ui: line)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.72, green: 0.70, blue: 0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
