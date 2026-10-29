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

    /// The toggle shows while something is hidden, and always while open, so an open list can be closed
    /// even after it shrank under the limit.
    static func showsToggle(count: Int, limit: Int, expanded: Bool) -> Bool { count > limit || expanded }

    /// Whether a list is open for `year`: a section keeps the years it was opened for (`opened`), so a list
    /// opened for one year starts closed on another. `startsOpen` (screenshot runs) flips every list.
    static func isOpen(_ opened: Set<Int>, year: Int?, startsOpen: Bool = false) -> Bool {
        opened.contains(yearKey(year)) != startsOpen
    }

    /// All-time as 0.
    static func yearKey(_ year: Int?) -> Int { year ?? 0 }

    /// Region grid columns: three, two at the first accessibility sizes, one beyond.
    static func regionColumns(_ size: DynamicTypeSize) -> Int {
        size >= .accessibility3 ? 1 : (size.isAccessibilitySize ? 2 : 3)
    }

    /// The footnote under the countries when some flights have an airport whose country is unknown, so
    /// the rows need not add up to the flights; nil when every flight is placed.
    static func unknownCountryNote(_ flights: UInt32) -> String? {
        guard flights > 0 else { return nil }
        return "\(Self.flights(flights)) with an airport in an unknown country \(flights == 1 ? "is" : "are") not counted here."
    }

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
        // Each airport asked once: a route list names the same airports many times.
        var codes: [String: String] = [:]
        func label(_ key: String) -> String {
            routeLabel(key, side: { icao in
                if let hit = codes[icao] { return hit }
                let c = code(icao, lookup: lookup)
                codes[icao] = c
                return c
            })
        }
        return tallies.map { bar($0, label: .code(label($0.key)), metric: metric, units: units) }
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
        routeLabel(key, side: { code($0, lookup: lookup) })
    }

    private static func routeLabel(_ key: String, side: (String) -> String) -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return key }
        return side(parts[0]) + "-" + side(parts[1])
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

/// The ranked lists of one period, built once when the period (or the distance unit) changes, so a
/// section redrawn for its toggle or "Show more" only picks rows.
struct PassportRankings: Equatable {
    var airports: [RankedBar]
    var airlinesByFlights: [RankedBar]
    var airlinesByDistance: [RankedBar]
    var routesByFlights: [RankedBar]
    var routesByDistance: [RankedBar]

    init(_ d: PassportDetail, units: DistanceUnit, lookup: (String) -> Airport?) {
        airports = PassportLists.airportBars(d, lookup: lookup)
        airlinesByFlights = PassportLists.airlineBars(d, metric: .flights, units: units)
        airlinesByDistance = PassportLists.airlineBars(d, metric: .distance, units: units)
        routesByFlights = PassportLists.routeBars(d, metric: .flights, units: units, lookup: lookup)
        routesByDistance = PassportLists.routeBars(d, metric: .distance, units: units, lookup: lookup)
    }

    func airlines(_ metric: PassportLists.Metric) -> [RankedBar] {
        metric == .flights ? airlinesByFlights : airlinesByDistance
    }

    func routes(_ metric: PassportLists.Metric) -> [RankedBar] {
        metric == .flights ? routesByFlights : routesByDistance
    }
}

// MARK: - Views

/// The airline's mark at `size`. For now the monogram badge in the brand colour (a three letter ICAO
/// monogram when the airline has no IATA code); real logos replace it here.
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
    /// What the rows are ("airports"), for VoiceOver.
    var noun: String
    @Binding var showMore: Bool
    @ScaledMetric(relativeTo: .body) private var codeRow: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var markRow: CGFloat = 35
    @Environment(\.reference) private var reference

    /// A code row's bar, as a share of the row's height.
    static let codeBar: CGFloat = 0.7
    /// How far a code row's bar sits under its code, as a share of the row's height.
    static let codeDrop: CGFloat = 0.5
    /// An airline row's mark and bar, as shares of the row's height.
    static let markSize: CGFloat = 0.72
    static let markBar: CGFloat = 0.68

    var body: some View {
        let rows = PassportLists.visible(items, limit: PassportLists.barLimit, expanded: showMore)
        let top = max(items.map(\.value).max() ?? 1, 1)
        let codes = rows.contains { if case .code = $0.label { true } else { false } }
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                ForEach(rows) { item in row(item, top: top) }
            }
            // The last code's bar hangs below its row.
            .padding(.bottom, codes ? codeRow * Self.codeDrop : 0)
            if PassportLists.showsToggle(count: items.count, limit: PassportLists.barLimit, expanded: showMore) {
                ShowMoreButton(expanded: $showMore, noun: noun, limit: PassportLists.barLimit)
                    .scaledPadding(.top, 8)
            }
        }
    }

    @ViewBuilder private func row(_ item: RankedBar, top: Int) -> some View {
        let fraction = Double(item.value) / Double(top)
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
                BarRow(fraction: fraction, caption: item.caption, height: codeRow * Self.codeBar)
                    .offset(y: codeRow * Self.codeDrop)
                    .frame(height: codeRow)
                    .accessibilityHidden(true)
            }
        case .airline(let key):
            GridRow {
                AirlineMark(airline: key, size: markRow * Self.markSize)
                    .frame(height: markRow)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reference.airline(key)?.name ?? key), \(item.caption)")
                BarRow(fraction: fraction, caption: item.caption, height: markRow * Self.markBar)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A rounded violet bar and its caption: the caption keeps its own width, the bar takes `fraction` of
/// what is left.
private struct BarRow: View {
    var fraction: Double
    var caption: String
    var height: CGFloat

    var body: some View {
        BarRowLayout(fraction: fraction, minBar: height * 0.6) {
            RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
                .fill(Theme.passportAccent)
                .frame(height: height)
            Text(caption)
                .scaledFont(17)
                .monospacedDigit()
                .foregroundStyle(Theme.primary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

/// Lays out [bar, caption]: the caption at its ideal width (shrunk only when the row cannot hold it next
/// to the shortest bar), the bar at `fraction` of the remaining width, never under `minBar`.
struct BarRowLayout: Layout {
    var fraction: Double
    var minBar: CGFloat
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let caption = subviews[1].sizeThatFits(.unspecified)
        let bar = subviews[0].sizeThatFits(ProposedViewSize(width: minBar, height: nil))
        let width = proposal.width ?? (minBar + spacing + caption.width)
        return CGSize(width: width, height: max(caption.height, bar.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let parts = Self.widths(total: bounds.width, caption: subviews[1].sizeThatFits(.unspecified).width,
                                fraction: fraction, minBar: minBar, spacing: spacing)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: parts.bar, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + parts.bar + spacing, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: parts.caption, height: nil))
    }

    /// The bar's and the caption's widths in a row `total` wide.
    static func widths(total: CGFloat, caption: CGFloat, fraction: Double, minBar: CGFloat,
                       spacing: CGFloat) -> (bar: CGFloat, caption: CGFloat) {
        let captionWidth = min(caption, max(total - minBar - spacing, 0))
        let room = max(total - captionWidth - spacing, 0)
        let bar = min(room, max(minBar, room * CGFloat(min(max(fraction, 0), 1))))
        return (bar, captionWidth)
    }
}

/// "Show more" in the link colour, "Show less" once open.
struct ShowMoreButton: View {
    @Binding var expanded: Bool
    /// What the list holds ("routes"), for VoiceOver.
    var noun: String
    var limit: Int

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Text(expanded ? "Show less" : "Show more")
                .scaledFont(17, weight: .medium)
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Shows the top \(limit) \(noun) only" : "Shows all \(noun)")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rank by")
    }
}

/// The big "22 total airports" line.
private struct TotalLine: View {
    var parts: (number: String, unit: String)

    var body: some View {
        UnitNumber(parts: [parts], size: 46, unitSize: 34)
    }
}

/// Lists start open on screenshot runs (`-passportShowMore YES`).
private enum ScreenshotRun {
    static let startsOpen: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "passportShowMore")
        #else
        false
        #endif
    }()
}

/// A section's "Show more" for `year`, over the set of years the section was opened for, so another
/// year starts closed.
private func openBinding(_ opened: Binding<Set<Int>>, year: Int?) -> Binding<Bool> {
    let key = PassportLists.yearKey(year)
    let flip = ScreenshotRun.startsOpen
    return Binding(
        get: { PassportLists.isOpen(opened.wrappedValue, year: year, startsOpen: flip) },
        set: { open in
            if open != flip { opened.wrappedValue.insert(key) } else { opened.wrappedValue.remove(key) }
        })
}

// MARK: Airports

struct PassportAirportsSection: View {
    var bars: [RankedBar]
    var year: Int?
    @State private var opened: Set<Int> = []

    var body: some View {
        PassportSection(title: "Top visited airports") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(bars.count, "airport", "airports"))
                Text("A stop of less than 8 hours between two flights counts as one visit.")
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 2)
                    .scaledPadding(.bottom, 6)
                RankedBars(items: bars, noun: "airports", showMore: openBinding($opened, year: year))
            }
        }
    }
}

// MARK: Airlines

struct PassportAirlinesSection: View {
    var rankings: PassportRankings
    var year: Int?
    @State private var metric: PassportLists.Metric = .flights
    @State private var opened: Set<Int> = []

    var body: some View {
        PassportSection(title: "Top airlines") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(rankings.airlinesByFlights.count, "airline", "airlines"))
                MetricToggle(metric: $metric).scaledPadding(.top, 18).scaledPadding(.bottom, 14)
                RankedBars(items: rankings.airlines(metric), noun: "airlines",
                           showMore: openBinding($opened, year: year))
            }
        }
    }
}

// MARK: Routes

struct PassportRoutesSection: View {
    var rankings: PassportRankings
    var year: Int?
    @State private var metric: PassportLists.Metric = .flights
    @State private var opened: Set<Int> = []

    var body: some View {
        PassportSection(title: "Top routes") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: PassportLists.total(rankings.routesByFlights.count, "route", "routes"))
                MetricToggle(metric: $metric).scaledPadding(.top, 18).scaledPadding(.bottom, 12)
                RankedBars(items: rankings.routes(metric), noun: "routes",
                           showMore: openBinding($opened, year: year))
            }
        }
    }
}

// MARK: Countries and regions

struct PassportCountriesSection: View {
    var detail: PassportDetail
    var year: Int?
    @State private var opened: Set<Int> = []
    @Environment(\.reference) private var reference
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 49

    var body: some View {
        let showMore = openBinding($opened, year: year)
        let rows = PassportLists.visible(detail.countries, limit: PassportLists.countryLimit, expanded: showMore.wrappedValue)
        PassportSection(title: "Countries and territories") {
            VStack(alignment: .leading, spacing: 0) {
                TotalLine(parts: (PassportFacts.count(detail.countries.count), " total"))
                    .scaledPadding(.bottom, 10)
                ForEach(rows, id: \.iso2) { c in countryRow(c) }
                if PassportLists.showsToggle(count: detail.countries.count, limit: PassportLists.countryLimit,
                                             expanded: showMore.wrappedValue) {
                    ShowMoreButton(expanded: showMore, noun: "countries", limit: PassportLists.countryLimit)
                        .scaledPadding(.top, 10)
                }
                if let note = PassportLists.unknownCountryNote(detail.unknownCountryFlights) {
                    Text(note)
                        .scaledFont(14)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .scaledPadding(.top, 6)
                }
                RegionGrid(regions: PassportLists.regions(detail)).scaledPadding(.top, 14)
            }
        }
    }

    private func countryRow(_ c: CountryCount) -> some View {
        let name = reference.country(c.iso2)?.name ?? c.iso2
        let flights = PassportLists.flights(c.flights)
        let nameText = Text(name).scaledFont(18, weight: .medium).foregroundStyle(Theme.primary).lineLimit(2)
        let flightsText = Text(flights).scaledFont(18).monospacedDigit().foregroundStyle(Theme.secondary)
        return HStack(spacing: 18) {
            CountryFlag(code: c.iso2, size: 25, decorative: true)
            VStack(spacing: 0) {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) { nameText; flightsText }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            nameText
                            Spacer(minLength: 8)
                            flightsText.fixedSize()
                        }
                    }
                }
                .scaledPadding(.vertical, 8)
                .frame(maxHeight: .infinity)
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .frame(minHeight: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(flights)")
    }
}

/// Outlined cells in `WorldRegion.gridOrder`: region, countries visited, the share of the region's
/// countries. Three columns, fewer at accessibility sizes, where the count sits over the percent.
struct RegionGrid: View {
    var regions: [(region: WorldRegion, visited: UInt32, percent: Int)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = PassportLists.regionColumns(typeSize)
        Grid(horizontalSpacing: 9, verticalSpacing: 9) {
            ForEach(Array(stride(from: 0, to: regions.count, by: columns)), id: \.self) { i in
                GridRow {
                    ForEach(i..<i + columns, id: \.self) { j in
                        if j < regions.count { cell(regions[j]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }

    private func cell(_ r: (region: WorldRegion, visited: UInt32, percent: Int)) -> some View {
        let count = Text(PassportFacts.count(r.visited))
            .scaledFont(24, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(Theme.primary)
        let percent = Text("\(r.percent)%")
            .scaledFont(16)
            .monospacedDigit()
            .foregroundStyle(Theme.secondary)
        return VStack(alignment: .leading, spacing: 0) {
            Text(r.region.title)
                .scaledFont(14, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if typeSize.isAccessibilitySize {
                count
                percent
            } else {
                HStack(alignment: .lastTextBaseline) {
                    count
                    Spacer(minLength: 4)
                    percent
                }
            }
        }
        .scaledPadding(.horizontal, 11)
        .scaledPadding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.region.title), \(r.visited) visited, \(r.percent) percent")
    }
}
