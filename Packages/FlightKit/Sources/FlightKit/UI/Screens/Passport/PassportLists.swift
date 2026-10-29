import SwiftUI
import FlightCore

/// One row of a ranked bar list: what it stands for (an airport or route code, or an airline's mark), the
/// figure its bar is drawn to and the text beside the bar.
struct RankedBar: Identifiable, Equatable {
    enum Label: Equatable {
        /// "SFO" or "CDG-SFO".
        case code(String)
        /// The airline key the core tallied (ICAO as the store maps it); drawn as its mark.
        case airline(String)
    }

    var id: String
    var label: Label
    var value: Int
    var caption: String
}

/// Rows and wording for the Passport's rankings, countries and regions, over the core's tallies
/// (`PassportDetail`). Nothing here counts: it picks the core's list, labels and formats it.
enum PassportLists {
    /// Rows a list shows before "Show more".
    static let barLimit = 8
    static let countryLimit = 3

    enum Metric: String, CaseIterable, Identifiable {
        case flights = "Flights", distance = "Distance"
        var id: String { rawValue }
    }

    /// The first `limit` rows, or all of them once expanded.
    static func visible<T>(_ rows: [T], limit: Int, expanded: Bool) -> [T] {
        expanded ? rows : Array(rows.prefix(limit))
    }

    /// "Show more" only when something is hidden.
    static func hasMore<T>(_ rows: [T], limit: Int) -> Bool { rows.count > limit }

    // MARK: Airports

    static func airportBars(_ d: PassportDetail, lookup: (String) -> Airport?) -> [RankedBar] {
        d.airports.map { a in
            RankedBar(id: a.icao, label: .code(code(a.icao, lookup: lookup)), value: Int(a.visits),
                      caption: PassportFacts.count(a.visits))
        }
    }

    // MARK: Airlines and routes

    static func airlineBars(_ d: PassportDetail, metric: Metric, units: DistanceUnit) -> [RankedBar] {
        let tallies = metric == .flights ? d.airlinesByFlights : d.airlinesByDistance
        return tallies.map { bar($0, label: .airline($0.key), metric: metric, units: units) }
    }

    static func routeBars(_ d: PassportDetail, metric: Metric, units: DistanceUnit,
                          lookup: (String) -> Airport?) -> [RankedBar] {
        let tallies = metric == .flights ? d.routesByFlights : d.routesByDistance
        return tallies.map { bar($0, label: .code(routeLabel($0.key, lookup: lookup)), metric: metric, units: units) }
    }

    private static func bar(_ t: Tally, label: RankedBar.Label, metric: Metric, units: DistanceUnit) -> RankedBar {
        switch metric {
        case .flights:
            RankedBar(id: t.key, label: label, value: Int(t.flights), caption: PassportFacts.count(t.flights))
        case .distance:
            RankedBar(id: t.key, label: label, value: Int(t.distanceKm),
                      caption: TravelFacts.distance(Int(t.distanceKm), units))
        }
    }

    /// The airport's IATA code, else the ICAO code the core used.
    static func code(_ icao: String, lookup: (String) -> Airport?) -> String {
        lookup(icao)?.iata.flatMap { $0.isEmpty ? nil : $0 } ?? icao
    }

    /// "CDG-SFO" from the core's `LFPG-KSFO`, each side in IATA when known, else as given.
    static func routeLabel(_ key: String, lookup: (String) -> Airport?) -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return key }
        return code(parts[0], lookup: lookup) + "-" + code(parts[1], lookup: lookup)
    }

    // MARK: Headlines

    /// ("22", " total airports"); singular for one.
    static func total(_ n: Int, _ singular: String, _ plural: String) -> (number: String, unit: String) {
        (PassportFacts.count(n), " total " + (n == 1 ? singular : plural))
    }

    /// "37 flights", "1 flight".
    static func flights(_ n: UInt32) -> String { "\(PassportFacts.count(n)) \(n == 1 ? "flight" : "flights")" }

    // MARK: Regions

    /// Share of a region's countries visited, in whole percent rounded half up; 0 for an empty region.
    static func regionPercent(visited: UInt32, total: UInt32) -> Int {
        guard total > 0 else { return 0 }
        return Int((200 * UInt64(visited) + UInt64(total)) / (2 * UInt64(total)))
    }

    /// The core's region rows in the grid's order (`WorldRegion.gridOrder`), a missing region as 0 of 0.
    static func regions(_ d: PassportDetail) -> [(region: WorldRegion, visited: UInt32, percent: Int)] {
        WorldRegion.gridOrder.map { r in
            let row = d.regions.first { $0.region == r.core }
            let visited = row?.visited ?? 0
            return (r, visited, regionPercent(visited: visited, total: row?.total ?? 0))
        }
    }
}

// MARK: - Views

/// The airline's mark at `size`. For now the monogram badge in the brand colour; real logos replace it here.
struct AirlineMark: View {
    var airline: String
    var size: CGFloat
    @Environment(\.reference) private var reference

    var body: some View {
        let known = reference.airline(airline)
        let code = known?.iata ?? known?.id ?? airline
        AirlineBadge(code: String(code.prefix(3)), key: airline, diameter: size)
    }
}

/// Horizontal violet bars, longest first: a label column, the bar sized to the largest value, the
/// caption at the bar's end. Shows `PassportLists.barLimit` rows, then all after "Show more".
/// Codes sit a little above their bar, so each bar runs between its code and the next one.
struct RankedBars: View {
    var items: [RankedBar]
    @Binding var showMore: Bool
    @ScaledMetric(relativeTo: .body) private var codeRow: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var markRow: CGFloat = 35
    @Environment(\.reference) private var reference

    var body: some View {
        let rows = PassportLists.visible(items, limit: PassportLists.barLimit, expanded: showMore)
        let top = max(items.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                ForEach(rows) { item in row(item, top: top) }
            }
            // The last code's bar hangs below its row.
            .padding(.bottom, rows.contains { if case .code = $0.label { true } else { false } } ? codeRow * 0.5 : 0)
            if PassportLists.hasMore(items, limit: PassportLists.barLimit) {
                ShowMoreButton(expanded: $showMore).scaledPadding(.top, 8)
            }
        }
    }

    @ViewBuilder private func row(_ item: RankedBar, top: Int) -> some View {
        switch item.label {
        case .code(let code):
            GridRow {
                Text(code)
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: codeRow, alignment: .center)
                    .accessibilityLabel("\(code), \(item.caption)")
                bar(item, top: top, height: codeRow * 0.7)
                    .offset(y: codeRow * 0.5)
                    .frame(height: codeRow)
                    .accessibilityHidden(true)
            }
        case .airline(let key):
            GridRow {
                AirlineMark(airline: key, size: markRow * 0.72)
                    .frame(height: markRow)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reference.airline(key)?.name ?? key), \(item.caption)")
                bar(item, top: top, height: markRow * 0.68)
                    .accessibilityHidden(true)
            }
        }
    }

    private func bar(_ item: RankedBar, top: Int, height: CGFloat) -> some View {
        BarTrack(fraction: Double(item.value) / Double(top), caption: item.caption, height: height)
    }
}

/// A rounded violet bar `fraction` of the space left after its caption, the caption just past its end.
private struct BarTrack: View {
    var fraction: Double
    var caption: String
    var height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let reserve = CGFloat(caption.count) * 10 + 14
                    let width = max(height * 0.6, (geo.size.width - reserve) * min(max(fraction, 0), 1))
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
                            .fill(Theme.passportAccent)
                            .frame(width: width, height: height)
                        Text(caption)
                            .scaledFont(17)
                            .monospacedDigit()
                            .foregroundStyle(Theme.primary.opacity(0.75))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(height: geo.size.height)
                }
            }
    }
}

/// "Show more" in the link colour, "Show less" once open.
struct ShowMoreButton: View {
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Text(expanded ? "Show less" : "Show more")
                .scaledFont(17, weight: .medium)
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Flights" and "Distance" pills over a ranked list.
struct MetricToggle: View {
    @Binding var metric: PassportLists.Metric

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PassportLists.Metric.allCases) { m in
                Button { metric = m } label: {
                    Text(m.rawValue)
                        .scaledFont(16, weight: .medium)
                        .foregroundStyle(m == metric ? Theme.primary : Theme.secondary)
                        .scaledPadding(.horizontal, 17)
                        .frame(minHeight: 42)
                        .background(Capsule().fill(m == metric ? Theme.pill : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(m == metric ? .isSelected : [])
            }
        }
    }
}

/// The big "22 total airports" line.
private struct TotalLine: View {
    var parts: (number: String, unit: String)

    var body: some View {
        UnitNumber(parts: [parts], size: 46, unitSize: 34)
    }
}

/// Starts lists open on screenshot runs (`-passportShowMore YES`).
private var startsOpen: Bool {
    #if DEBUG
    UserDefaults.standard.bool(forKey: "passportShowMore")
    #else
    false
    #endif
}

// MARK: Airports

struct PassportAirportsSection: View {
    var detail: PassportDetail
    var lookup: (String) -> Airport?
    @State private var showMore = startsOpen

    var body: some View {
        let bars = PassportLists.airportBars(detail, lookup: lookup)
        PassportSection(title: "Top visited airports") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(detail.airports.count, "airport", "airports"))
                Text("A stop of less than 8 hours between two flights counts as one visit.")
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 2)
                    .scaledPadding(.bottom, 6)
                RankedBars(items: bars, showMore: $showMore)
            }
        }
    }
}

// MARK: Airlines

struct PassportAirlinesSection: View {
    var detail: PassportDetail
    @State private var metric: PassportLists.Metric = .flights
    @State private var showMore = startsOpen
    @Environment(\.units) private var units

    var body: some View {
        PassportSection(title: "Top airlines") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(detail.airlinesByFlights.count, "airline", "airlines"))
                MetricToggle(metric: $metric).scaledPadding(.top, 18).scaledPadding(.bottom, 14)
                RankedBars(items: PassportLists.airlineBars(detail, metric: metric, units: units.distance),
                           showMore: $showMore)
            }
        }
    }
}

// MARK: Routes

struct PassportRoutesSection: View {
    var detail: PassportDetail
    var lookup: (String) -> Airport?
    @State private var metric: PassportLists.Metric = .flights
    @State private var showMore = startsOpen
    @Environment(\.units) private var units

    var body: some View {
        PassportSection(title: "Top routes") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(detail.routesByFlights.count, "route", "routes"))
                MetricToggle(metric: $metric).scaledPadding(.top, 18).scaledPadding(.bottom, 12)
                RankedBars(items: PassportLists.routeBars(detail, metric: metric, units: units.distance, lookup: lookup),
                           showMore: $showMore)
            }
        }
    }
}

// MARK: Countries and regions

struct PassportCountriesSection: View {
    var detail: PassportDetail
    @State private var showMore = startsOpen
    @Environment(\.reference) private var reference
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 49

    var body: some View {
        let rows = PassportLists.visible(detail.countries, limit: PassportLists.countryLimit, expanded: showMore)
        PassportSection(title: "Countries and territories") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: (PassportFacts.count(detail.countries.count), " total"))
                    .scaledPadding(.bottom, 10)
                ForEach(Array(rows.enumerated()), id: \.element.iso2) { i, c in
                    countryRow(c, last: i == rows.count - 1)
                }
                if PassportLists.hasMore(detail.countries, limit: PassportLists.countryLimit) {
                    ShowMoreButton(expanded: $showMore).scaledPadding(.top, 10)
                }
                RegionGrid(regions: PassportLists.regions(detail)).scaledPadding(.top, 14)
            }
        }
    }

    private func countryRow(_ c: CountryCount, last: Bool) -> some View {
        let name = reference.country(c.iso2)?.name ?? c.iso2
        return HStack(spacing: 18) {
            CountryFlag(code: c.iso2, size: 25, decorative: true)
            VStack(spacing: 0) {
                HStack {
                    Text(name)
                        .scaledFont(18, weight: .medium)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(PassportLists.flights(c.flights))
                        .scaledFont(18)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(PassportLists.flights(c.flights))")
    }
}

/// Three by three outlined cells: region, countries visited, the share of the region's countries.
struct RegionGrid: View {
    var regions: [(region: WorldRegion, visited: UInt32, percent: Int)]

    var body: some View {
        Grid(horizontalSpacing: 9, verticalSpacing: 9) {
            ForEach(Array(stride(from: 0, to: regions.count, by: 3)), id: \.self) { i in
                GridRow {
                    ForEach(i..<min(i + 3, regions.count), id: \.self) { cell(regions[$0]) }
                }
            }
        }
    }

    private func cell(_ r: (region: WorldRegion, visited: UInt32, percent: Int)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(r.region.title)
                .scaledFont(14, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .lastTextBaseline) {
                Text(PassportFacts.count(r.visited))
                    .scaledFont(24, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 4)
                Text("\(r.percent)%")
                    .scaledFont(16)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
        }
        .scaledPadding(.horizontal, 11)
        .scaledPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.region.title), \(r.visited) visited, \(r.percent) percent")
    }
}
