import Charts
import SwiftUI

// The pieces the Airports feature adds to the airport card: the calm status card, the provider's delay
// trend, the day's traffic, Runway Regulars, the user's own history here and the bottom bar.

// MARK: - Status

/// How the airport is doing, in one card: the overall level, departures and arrivals, and the weather in
/// plain words. Shown on calm days, when the red issues card is not.
struct AirportStatusCard: View {
    var status: AirportStatus
    var live: AirportLiveStats?
    var weather: AirportConditions?

    private var title: String {
        switch status.level {
        case .normal: "Running normally"
        case .minor: "Some delays"
        case .major: "Major disruption"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AirportStatusDot(level: status.level, size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                    if let line = status.line {
                        Text(line).scaledFont(13.5).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if live?.available == true {
                HStack(spacing: 0) {
                    direction("Departures", "airplane.departure", live?.departures?.brief)
                    direction("Arrivals", "airplane.arrival", live?.arrivals?.brief)
                }
            }
            if let weather {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(weather))
                        .symbolRenderingMode(.multicolor)
                        .scaledFont(15)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(weather.summary)
                        .scaledFont(14.5)
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .scaledPadding(.all, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
    }

    private func direction(_ title: String, _ icon: String, _ brief: AirportBrief?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.secondary)
            if let brief {
                Text(brief.onTimePercent.map { "\($0)% on time" } ?? "No flights yet")
                    .scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary)
                Text(brief.avgDelayMinutes > 0 ? "\(Format.minutes(brief.avgDelayMinutes)) average delay" : "No delays")
                    .scaledFont(12.5).foregroundStyle(Theme.secondary)
            } else {
                Text("-").scaledFont(15, weight: .semibold).foregroundStyle(Theme.secondary)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A weather glyph from the METAR's present weather, else its sky.
    static func symbol(_ w: AirportConditions) -> String {
        let wx = w.wx ?? ""
        if wx.contains("TS") { return "cloud.bolt.rain.fill" }
        if wx.contains("SN") { return "cloud.snow.fill" }
        if wx.contains("RA") || wx.contains("DZ") { return "cloud.rain.fill" }
        if wx.contains("FG") || wx.contains("BR") || wx.contains("HZ") { return "cloud.fog.fill" }
        switch w.condition {
        case "Clear skies": return "sun.max.fill"
        case "A few clouds", "Partly cloudy": return "cloud.sun.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Provider trend

/// The provider's hourly average delay: flown hours solid, the hours ahead lighter (estimated), and a
/// "Now" line between them.
struct LiveTrendChart: View {
    var trend: [AirportTrendHour]
    var timeZone: TimeZone
    var now: Date

    private func color(_ h: AirportTrendHour) -> Color {
        if h.estimated { return Theme.trendFuture }
        if h.avgDelayMinutes >= AirportStatus.majorDelay { return Theme.splitRed }
        if h.avgDelayMinutes >= AirportStatus.minorDelay { return Theme.trendAmber }
        return Theme.trendCalm
    }

    var body: some View {
        Chart {
            ForEach(trend) { h in
                BarMark(x: .value("Hour", h.hour, unit: .hour), y: .value("Average delay", h.avgDelayMinutes))
                    .foregroundStyle(color(h))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Theme.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    Text("Now").scaledFont(11, weight: .semibold).foregroundStyle(Theme.primary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(Self.hour(d, timeZone)).scaledFont(11) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let m = value.as(Int.self) { Text("\(m)m").scaledFont(11) }
                }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Average delay by hour")
    }

    static func hour(_ d: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return String(format: "%02d", cal.component(.hour, from: d))
    }
}

// MARK: - Traffic

/// Our own airline mark: the code in a rounded square, coloured from the code. Never a real logo.
struct AirlineMonogram: View {
    var code: String
    var size: CGFloat = 30
    /// nil picks a colour from the code.
    var color: Color?

    static let palette: [Color] = [Theme.accent, Theme.friend, Theme.diverted, Theme.mvfr, Theme.vfr, Theme.lifr, Theme.trendAmber]

    static func color(_ code: String) -> Color {
        palette[code.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
    }

    var body: some View {
        Text(code)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color ?? Self.color(code)))
            .accessibilityHidden(true)
    }
}

enum TrafficSpan: Hashable { case today, week }

/// Airport Stats from the provider: the counts, the busiest airlines as one split bar and the busiest
/// routes, for today or the next seven days.
struct LiveTrafficSection: View {
    var today: AirportTraffic?
    var week: AirportTraffic?
    var lookup: (String) -> Airport?
    @State private var span: TrafficSpan = .today

    private var traffic: AirportTraffic? { span == .today ? today : week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Airport Stats", subtitle: span == .today ? "Today in numbers" : "The next seven days, scheduled",
                          large: true)
                .scaledPadding(.bottom, 14)
            PillPicker(options: [(TrafficSpan.today, "Today"), (.week, "Next 7 Days")], selection: $span)
                .scaledPadding(.bottom, 18)
            if let traffic {
                AirportCountsGrid(counts: .init(departures: traffic.departures, airlines: traffic.airlines,
                                                airportsServed: traffic.airportsServed, countries: traffic.countriesServed))
                if !traffic.busiestAirlines.isEmpty {
                    Text("Busiest airlines").themeFont(.sectionTitle).foregroundStyle(Theme.primary)
                        .scaledPadding(.top, 26).scaledPadding(.bottom, 10)
                    AirlineSplitBar(airlines: traffic.busiestAirlines)
                }
                if !traffic.busiestRoutes.isEmpty {
                    Text("Busiest routes").themeFont(.sectionTitle).foregroundStyle(Theme.primary)
                        .scaledPadding(.top, 26).scaledPadding(.bottom, 6)
                    routes(traffic.busiestRoutes)
                }
            } else {
                Text("The next seven days come with a schedules feed, not switched on yet.")
                    .scaledFont(14).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func routes(_ routes: [AirportTraffic.Route]) -> some View {
        let peak = max(1, routes.map(\.flights).max() ?? 1)
        return VStack(spacing: 0) {
            ForEach(routes, id: \.icao) { r in
                let a = lookup(r.icao)
                HStack(spacing: 12) {
                    Text(a?.iata ?? r.icao)
                        .scaledFont(15, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a?.city ?? r.icao).scaledFont(14).foregroundStyle(Theme.primary).lineLimit(1)
                        GeometryReader { g in
                            Capsule().fill(Theme.accent.opacity(0.75))
                                .frame(width: max(4, g.size.width * CGFloat(r.flights) / CGFloat(peak)), height: 5)
                        }
                        .frame(height: 5)
                    }
                    Text("\(r.flights)").scaledFont(15, weight: .medium).foregroundStyle(Theme.primary)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .scaledPadding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The busiest airlines' shares of departures as one bar, with a legend of monograms under it.
struct AirlineSplitBar: View {
    var airlines: [AirportTraffic.Airline]

    private var total: Int { max(1, airlines.reduce(0) { $0 + $1.flights }) }

    private func code(_ op: String) -> String { AirportFacts.airlineCode(op) }

    /// One colour per place in the ranking, so neighbours never share one.
    static func color(_ i: Int) -> Color { AirlineMonogram.palette[i % AirlineMonogram.palette.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(airlines.enumerated()), id: \.element.operator) { i, a in
                        Rectangle().fill(Self.color(i))
                            .frame(width: max(3, (g.size.width - CGFloat(airlines.count - 1) * 2) * CGFloat(a.flights) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                ForEach(Array(airlines.enumerated()), id: \.element.operator) { i, a in
                    HStack(spacing: 8) {
                        AirlineMonogram(code: code(a.operator), size: 28, color: Self.color(i))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(code(a.operator)).scaledFont(14, weight: .semibold).foregroundStyle(Theme.primary)
                            Text("\(a.flights) · \(Int((Double(a.flights) / Double(total) * 100).rounded()))%")
                                .scaledFont(12.5).foregroundStyle(Theme.secondary)
                        }
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Runway Regulars

/// The user and friends who share their Passport, ranked by flights through this airport: the top three
/// on a podium, the rest in a list.
struct RunwayRegularsSection: View {
    var regulars: [RunwayRegular]
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Runway Regulars", subtitle: "You and friends sharing their Passport, by flights through \(code)",
                          large: true)
                .scaledPadding(.bottom, 18)
            podium
            let rest = Array(regulars.dropFirst(3))
            ForEach(Array(rest.enumerated()), id: \.element.id) { i, r in
                HStack(spacing: 12) {
                    Text("\(i + 4)").scaledFont(14, weight: .semibold).foregroundStyle(Theme.secondary).frame(width: 22)
                    avatar(r, size: 30)
                    Text(r.name).scaledFont(15).foregroundStyle(Theme.primary)
                    Spacer()
                    Text(visits(r)).scaledFont(14).foregroundStyle(Theme.secondary)
                }
                .monospacedDigit()
                .scaledPadding(.vertical, 8)
            }
        }
    }

    /// Second, first, third, left to right.
    private var podium: some View {
        let top = Array(regulars.prefix(3))
        let order = [1, 0, 2].filter { $0 < top.count }
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(order, id: \.self) { rank in
                let r = top[rank]
                VStack(spacing: 6) {
                    avatar(r, size: rank == 0 ? 56 : 46)
                    Text(r.name).scaledFont(14, weight: .semibold).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(visits(r)).scaledFont(12.5).foregroundStyle(Theme.secondary).monospacedDigit()
                    ZStack(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
                            .fill(rank == 0 ? Theme.accent.opacity(0.22) : Theme.pill)
                        Text("\(rank + 1)")
                            .scaledFont(22, weight: .bold, design: .rounded)
                            .foregroundStyle(rank == 0 ? Theme.accent : Theme.secondary)
                            .scaledPadding(.top, 8)
                    }
                    .frame(height: [92, 66, 50][rank])
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rank + 1), \(r.name), \(visits(r))")
            }
        }
    }

    private func visits(_ r: RunwayRegular) -> String { r.visits == 1 ? "1 flight" : "\(r.visits) flights" }

    private func avatar(_ r: RunwayRegular, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(r.isMe ? Theme.accent.opacity(0.18) : Theme.friend.opacity(0.18))
            if let e = r.emoji, !e.isEmpty {
                Text(e).font(.system(size: size * 0.5))
            } else {
                Text(String(r.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(r.isMe ? Theme.accent : Theme.friend)
            }
        }
        .frame(width: size, height: size)
        .overlay { if r.isMe { Circle().stroke(Theme.accent, lineWidth: 2) } }
        .accessibilityHidden(true)
    }
}

// MARK: - Your history

/// What the user's own Passport says about this airport: flights through it, the last one and where to.
struct AirportHistory: Equatable {
    var flights: Int
    var departures: Int
    var arrivals: Int
    var last: PastFlight?
    /// The far ends flown most from or to here, most first (ICAO and count), at most three.
    var topEnds: [(icao: String, flights: Int)]

    static func == (a: Self, b: Self) -> Bool {
        a.flights == b.flights && a.departures == b.departures && a.last?.id == b.last?.id
            && a.topEnds.map(\.icao) == b.topEnds.map(\.icao)
    }

    /// nil when the user never flew through `icao` (canceled flights do not count).
    static func of(_ past: [PastFlight], icao: String) -> AirportHistory? {
        let here = past.filter { $0.status != .canceled && ($0.originIcao == icao || $0.destinationIcao == icao) }
        guard !here.isEmpty else { return nil }
        var ends: [String: Int] = [:]
        for f in here { ends[f.originIcao == icao ? f.destinationIcao : f.originIcao, default: 0] += 1 }
        let top = ends.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
        return AirportHistory(flights: here.count, departures: here.filter { $0.originIcao == icao }.count,
                              arrivals: here.filter { $0.destinationIcao == icao }.count,
                              last: here.max { $0.date < $1.date }, topEnds: top.map { ($0.key, $0.value) })
    }
}

struct AirportHistorySection: View {
    var history: AirportHistory
    var code: String
    var lookup: (String) -> Airport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your History Here", subtitle: "From your Passport", large: true)
                .scaledPadding(.bottom, 16)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    number(history.flights, history.flights == 1 ? "Flight" : "Flights")
                    number(history.departures, "From \(code)")
                    number(history.arrivals, "To \(code)")
                }
            }
            if let last = history.last {
                let other = last.originIcao == lookup(code)?.id ?? "" ? last.destinationIcao : last.originIcao
                let from = last.destinationIcao != other
                Text("Last time: \(Format.ident(last.ident)) \(from ? "to" : "from") \(lookup(other)?.city ?? other), \(last.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .scaledFont(14).foregroundStyle(Theme.secondary)
                    .scaledPadding(.top, 14)
            }
            if !history.topEnds.isEmpty {
                Text("Most flown with \(code)")
                    .themeFont(.sectionTitle).foregroundStyle(Theme.primary)
                    .scaledPadding(.top, 20).scaledPadding(.bottom, 6)
                ForEach(history.topEnds, id: \.icao) { end in
                    HStack {
                        Text(lookup(end.icao)?.iata ?? end.icao)
                            .scaledFont(15, weight: .semibold, design: .monospaced).foregroundStyle(Theme.primary)
                            .frame(width: 46, alignment: .leading)
                        Text(lookup(end.icao)?.city ?? end.icao).scaledFont(14).foregroundStyle(Theme.primary)
                        Spacer()
                        Text("\(end.flights)").scaledFont(14, weight: .medium).foregroundStyle(Theme.secondary)
                    }
                    .monospacedDigit()
                    .scaledPadding(.vertical, 6)
                }
            }
        }
    }

    private func number(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").scaledFont(22, weight: .semibold).foregroundStyle(Theme.primary)
            Text(label).scaledFont(13).foregroundStyle(Theme.secondary)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom bar

/// The airport card's actions: jump to the boards, keep as a favourite, more, and share as an image.
struct AirportBottomBar: View {
    var isFavorite: Bool
    var hasBoards: Bool
    var shareImage: Image?
    var shareTitle: String
    var onDepartures: () -> Void
    var onArrivals: () -> Void
    var onFavorite: () -> Void
    var copyCode: String

    var body: some View {
        HStack(spacing: 0) {
            if hasBoards {
                item("Departures", "airplane.departure", action: onDepartures)
                item("Arrivals", "airplane.arrival", action: onArrivals)
            }
            item(isFavorite ? "Favorite" : "Favorite", isFavorite ? "star.fill" : "star", tint: isFavorite ? Theme.late : nil,
                 action: onFavorite)
                .accessibilityValue(isFavorite ? "On" : "Off")
            Menu {
                Button("Copy Code", systemImage: "doc.on.doc") { Self.copy(copyCode) }
            } label: { label("More", "ellipsis.circle", tint: nil) }
            .buttonStyle(.plain)
            Group {
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview(shareTitle, image: shareImage)) {
                        label("Share", "square.and.arrow.up", tint: nil)
                    }
                } else {
                    label("Share", "square.and.arrow.up", tint: nil).opacity(0.4)
                }
            }
            .buttonStyle(.plain)
        }
        .scaledPadding(.horizontal, 6)
        .scaledPadding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .scaledPadding(.horizontal, 16)
    }

    private func item(_ title: String, _ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(title, icon, tint: tint) }.buttonStyle(.plain)
    }

    private func label(_ title: String, _ icon: String, tint: Color?) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).scaledFont(18, weight: .medium).frame(height: 22)
            Text(title).scaledFont(10.5, weight: .semibold)
        }
        .foregroundStyle(tint ?? Theme.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// The picture the Share button sends: the airport, its status and weather, at phone width.
struct AirportShareCard: View {
    var airport: Airport
    var status: AirportStatus
    var weather: AirportConditions?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(airport.iata ?? airport.id).scaledFont(40, weight: .bold, design: .rounded)
                Spacer()
                Text("Soma Flight").scaledFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
            }
            Text(airport.name).scaledFont(18, weight: .semibold)
            Text("\(airport.city), \(airport.country)").scaledFont(14).foregroundStyle(Theme.secondary)
            AirportStatusCard(status: status, live: nil, weather: weather)
        }
        .foregroundStyle(Theme.primary)
        .scaledPadding(.all, 24)
        .frame(width: 393, alignment: .leading)
        .background(Theme.background)
    }
}
