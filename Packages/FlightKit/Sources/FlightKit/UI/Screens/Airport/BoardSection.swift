import SwiftUI

/// Departures or arrivals board: filters (day, far end, airline), flights per hour for the
/// filtered set, then the rows with a "now" divider at the current local time.
struct BoardSection: View {
    @Environment(\.units) private var units
    var departures: AirportBoard?
    var arrivals: AirportBoard?
    var timeZone: TimeZone
    var now: Date
    var lookup: (String) -> Airport?
    var fetchedAt: [BoardKind: Date] = [:]
    /// Caps the rows drawn (snapshots); nil draws them all.
    var rowLimit: Int?
    /// Rows in a LazyVStack (inside a ScrollView). Off for ImageRenderer, which draws no lazy content.
    var lazy = true
    /// A board picked from outside (the airport card's bottom bar); a new `id` switches again.
    var request: BoardRequest?

    @State private var kind: BoardKind = .departures
    @State private var filter = AirportFacts.Filter()
    /// The day picked from the menu; until then the board shows today when it has flights today.
    @State private var pickedDay: Date??
    @State private var showEarlier = false
    @State private var chartCache: (key: ChartKey, perHour: [HourBucket])?

    /// What the per-hour chart depends on; the core runs again only when it changes.
    struct ChartKey: Hashable {
        var kind: BoardKind
        var fetchedAt: Date?
        var count: Int
        var filter: AirportFacts.Filter
    }

    private var board: AirportBoard? { kind == .departures ? departures : arrivals }
    private var flights: [Flight] { board?.flights ?? [] }
    private var today: Date { AirportFacts.calendar(timeZone).startOfDay(for: now) }
    private var days: [Date] { AirportFacts.days(flights, kind, tz: timeZone) }
    private var day: Date? { pickedDay ?? (days.contains(today) ? today : nil) }
    private var effectiveFilter: AirportFacts.Filter {
        var f = filter
        f.day = day
        return f
    }
    private var filtered: [Flight] { AirportFacts.apply(effectiveFilter, to: flights, kind: kind, tz: timeZone) }
    private var chartKey: ChartKey {
        ChartKey(kind: kind, fetchedAt: board?.fetchedAt, count: flights.count, filter: effectiveFilter)
    }

    var body: some View {
        let filtered = self.filtered
        let shown = showEarlier ? filtered : AirportFacts.current(filtered, kind: kind, now: now)
        let rows = rowLimit.map { Array(shown.prefix($0)) } ?? shown
        let divider = AirportFacts.nowIndex(rows, kind: kind, now: now)
        let key = chartKey
        let perHour = chartCache?.key == key ? chartCache!.perHour : DelayStats.compute(filtered, kind: kind).perHour
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionFreshness(fetchedAt: fetchedAt[kind], ttl: AirportFacts.boardTTL, now: now, bottom: 10)
                PillPicker(options: [(BoardKind.departures, "Departures"), (.arrivals, "Arrivals")], selection: $kind)
                    .scaledPadding(.bottom, 12)
                filters
                    .scaledPadding(.bottom, 22)
                SectionHeader(kind == .departures ? "Departures per hour" : "Arrivals per hour", info: true)
                    .scaledPadding(.bottom, 4)
                // The chart runs nearly edge to edge, as on the reference board.
                DelayChart(perHour: perHour, timeZone: timeZone, now: now)
                    .scaledPadding(.leading, 6 - Theme.gutter)
                    .scaledPadding(.trailing, 10 - Theme.gutter)
                    .scaledPadding(.bottom, 26)
                HStack(alignment: .firstTextBaseline) {
                    Text(kind == .departures ? "Departures" : "Arrivals")
                        .themeFont(.sheetTitle)
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    if shown.count < filtered.count || showEarlier {
                        Button(showEarlier ? "Hide Past Flights" : "Past Flights") { showEarlier.toggle() }
                            .buttonStyle(.plain)
                            .scaledFont(14, weight: .medium)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .scaledPadding(.bottom, 8)
            }
            .scaledPadding(.horizontal, Theme.gutter)
            if rows.isEmpty {
                Text(flights.isEmpty ? "No flights on this board yet." : "No flights match these filters.")
                    .scaledFont(15).foregroundStyle(Theme.secondary)
                    .scaledPadding(.horizontal, Theme.gutter).scaledPadding(.vertical, 20)
            }
            MaybeLazyVStack(lazy: lazy) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, f in
                    if i == divider { nowRow }
                    BoardRow(flight: f, kind: kind, airport: lookup(kind == .arrivals ? f.originIcao : f.destinationIcao),
                             timeZone: timeZone, now: now, striped: !i.isMultiple(of: 2))
                }
                if divider == nil, !rows.isEmpty, rowLimit == nil || rows.count == shown.count { nowRow }
            }
        }
        .onChange(of: kind) { filter.place = nil; showEarlier = false }
        .onChange(of: request) { if let request { kind = request.kind } }
        .onChange(of: key, initial: true) { chartCache = (key, DelayStats.compute(filtered, kind: kind).perHour) }
    }

    private var filters: some View {
        let days = self.days, today = self.today
        let cal = AirportFacts.calendar(timeZone)
        func dayName(_ d: Date) -> String {
            if d == today { return "Today" }
            if d == cal.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
            if d == cal.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }
            var style = AirportFacts.shortDay
            style.timeZone = timeZone
            return d.formatted(style)
        }
        let places = Set(flights.map { kind == .arrivals ? $0.originIcao : $0.destinationIcao })
            .map { ($0, lookup($0)?.city ?? $0) }.sorted { $0.1 < $1.1 }
        let airlines = Set(flights.compactMap(\.operator)).sorted()
        let placeTitle = filter.place.map { p in places.first { $0.0 == p }?.1 ?? p } ?? (kind == .departures ? "To" : "From")
        return HStack(spacing: 6) {
            FilterPill(icon: "calendar", title: day.map(dayName) ?? "All Days",
                       options: [(Date?.none, "All Days")] + days.map { (Optional($0), dayName($0)) },
                       selection: Binding(get: { day }, set: { pickedDay = .some($0) }))
            FilterPill(icon: kind == .departures ? "airplane.departure" : "airplane.arrival", title: placeTitle,
                       options: [(String?.none, "Anywhere")] + places.map { (Optional($0.0), $0.1) },
                       selection: $filter.place)
            FilterPill(icon: "airplane.circle", title: filter.airline.map(AirportFacts.airlineCode) ?? "Airlines",
                       options: [(String?.none, "All Airlines")] + airlines.map { (Optional($0), AirportFacts.airlineCode($0)) },
                       selection: $filter.airline)
        }
    }

    private var nowRow: some View {
        HStack {
            Text("\(Format.clock(now, timeZone, units.clock))  LOCAL TIME")
            Spacer()
            Text("NOW")
        }
        .scaledFont(11.5, weight: .medium)
        .foregroundStyle(Theme.secondary)
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.vertical, 3)
        .frame(minHeight: 24)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Asks the board to show departures or arrivals; `id` changes on each ask.
struct BoardRequest: Equatable {
    var kind: BoardKind
    var id: Int
}
