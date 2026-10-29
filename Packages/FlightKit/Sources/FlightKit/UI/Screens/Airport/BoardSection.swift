import SwiftUI

/// Departures or arrivals board: filters (day, far end, airline), flights per hour for the
/// filtered set, then the rows with a "now" divider at the current local time.
struct BoardSection: View {
    var departures: AirportBoard?
    var arrivals: AirportBoard?
    var timeZone: TimeZone
    var now: Date
    var lookup: (String) -> Airport?
    /// Caps the rows drawn (snapshots); nil draws them all.
    var rowLimit: Int?

    @State private var kind: BoardKind = .departures
    @State private var filter = AirportFacts.Filter()
    /// The day picked from the menu; until then the board shows today when it has flights today.
    @State private var pickedDay: Date??
    @State private var showEarlier = false

    private var board: AirportBoard? { kind == .departures ? departures : arrivals }
    private var flights: [Flight] { board?.flights ?? [] }
    private var today: Date { AirportFacts.calendar(timeZone).startOfDay(for: now) }
    private var days: [Date] { AirportFacts.days(flights, kind, tz: timeZone) }
    private var day: Date? { pickedDay ?? (days.contains(today) ? today : nil) }
    private var filtered: [Flight] {
        var f = filter
        f.day = day
        return AirportFacts.apply(f, to: flights, kind: kind, tz: timeZone)
    }

    var body: some View {
        let filtered = self.filtered
        let shown = showEarlier ? filtered : AirportFacts.current(filtered, kind: kind, now: now)
        let rows = rowLimit.map { Array(shown.prefix($0)) } ?? shown
        let divider = AirportFacts.nowIndex(rows, kind: kind, now: now)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PillPicker(options: [(BoardKind.departures, "Departures"), (.arrivals, "Arrivals")], selection: $kind)
                    .padding(.bottom, 12)
                filters
                    .padding(.bottom, 22)
                SectionHeader(kind == .departures ? "Departures per hour" : "Arrivals per hour", info: true)
                    .padding(.bottom, 4)
                // The chart runs nearly edge to edge, as on the reference board.
                DelayChart(perHour: DelayStats.compute(filtered, kind: kind).perHour, timeZone: timeZone, now: now)
                    .padding(.leading, 6 - Theme.gutter)
                    .padding(.trailing, 10 - Theme.gutter)
                    .padding(.bottom, 26)
                HStack(alignment: .firstTextBaseline) {
                    Text(kind == .departures ? "Departures" : "Arrivals")
                        .font(Theme.Font.sheetTitle)
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    if shown.count < filtered.count || showEarlier {
                        Button(showEarlier ? "Hide Earlier Flights" : "Earlier Flights") { showEarlier.toggle() }
                            .buttonStyle(.plain)
                            .scaledFont(14, weight: .medium)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, Theme.gutter)
            if rows.isEmpty {
                Text(flights.isEmpty ? "No flights on this board yet." : "No flights match these filters.")
                    .scaledFont(15).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, Theme.gutter).padding(.vertical, 20)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, f in
                if i == divider { nowRow }
                BoardRow(flight: f, kind: kind, airport: lookup(kind == .arrivals ? f.originIcao : f.destinationIcao),
                         timeZone: timeZone, now: now, striped: !i.isMultiple(of: 2))
            }
            if divider == nil, !rows.isEmpty, rowLimit == nil || rows.count == shown.count { nowRow }
        }
        .onChange(of: kind) { filter.place = nil; showEarlier = false }
    }

    private var filters: some View {
        let days = self.days, today = self.today
        let cal = AirportFacts.calendar(timeZone)
        func dayName(_ d: Date) -> String {
            if d == today { return "Today" }
            if d == cal.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
            if d == cal.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.timeZone = timeZone; f.dateFormat = "EEE d"
            return f.string(from: d)
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
            Text("\(Format.clock(now, timeZone))  LOCAL TIME")
            Spacer()
            Text("NOW")
        }
        .scaledFont(11.5, weight: .medium)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 20)
        .frame(height: 24)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}
