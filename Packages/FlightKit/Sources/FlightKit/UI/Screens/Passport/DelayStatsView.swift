import SwiftUI

/// The Delay Report, opened from the delays card. A red hero (the share of flights that landed late, the
/// hours lost on a split-flap board, the longest wait on a dot-matrix strip, the airlines that lost the
/// most time), then the sections on a dark ground: my performance, airlines, airports and every late
/// arrival. Each section shares itself as an image; the top bar's share hands over the hero. The figures
/// are `DelayReport`'s (definitions there); the year chips filter all of them.
struct DelayStatsView: View {
    @Bindable var store: PassportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    var body: some View {
        FullPageChrome(title: FullPage.delays.title, year: $store.year, years: store.years, scheme: .dark,
                       page: DelayInk.page, shareKey: store.revision, onClose: onClose,
                       sectionBackground: DelayInk.sections, heroInset: 0,
                       chipFill: .white.opacity(0.14), buttonFill: .white.opacity(0.10), frosted: true) {
            DelayReportHero(report: store.delayReport, year: store.year, lookup: lookup)
        } content: {
            DelayReportSections(report: store.delayReport, year: store.year, key: store.revision, lookup: lookup)
        }
    }
}

// MARK: - Hero

struct DelayReportHero: View {
    var report: DelayReport
    var year: Int?
    var lookup: (String) -> Airport?
    @Environment(\.reference) private var reference

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            if report.flights == 0 {
                Text(year.map { "No flights in \(String($0))" } ?? "No flights yet")
                    .scaledFont(20, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaledPadding(.vertical, 40)
            } else {
                share.scaledPadding(.top, 26)
                lost.scaledPadding(.top, 28)
                if let worst = report.worst {
                    worstDelay(worst).scaledPadding(.top, 30)
                }
                if !report.airlineLosses.isEmpty {
                    worstAirline.scaledPadding(.top, 30)
                }
                basis.scaledPadding(.top, 24)
            }
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .scaledPadding(.top, 18)
                .accessibilityHidden(true)
        }
        // Every figure rolls as the year changes; the flap board flips its own tiles.
        .rollingDigits()
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 14)
        .scaledPadding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DelayInk.hero)
    }

    /// The app's name and the period, over an amber rule: what makes a shared image ours.
    private var masthead: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SOMA FLIGHT")
                    .scaledFont(15, weight: .heavy)
                    .tracking(2)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text("\(year.map(String.init) ?? "All-time") delay report")
                    .scaledFont(15, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DelayInk.amber)
                    .lineLimit(1)
            }
            Rectangle().fill(DelayInk.amber).frame(height: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var share: some View {
        let s = report.lateArrivals
        return VStack(alignment: .leading, spacing: 2) {
            Text(report.withTimes == 0 ? "No times yet" : "\(s.percent)%")
                .scaledFont(64, weight: .bold)
                .monospacedDigit()
                .rollingDigits(Double(s.percent))
                .foregroundStyle(.white)
            Text("of my flights landed late")
                .scaledFont(24, weight: .bold)
                .foregroundStyle(.white)
            Text(DelayFacts.shareLine(s))
                .scaledFont(17)
                .monospacedDigit()
                .foregroundStyle(DelayInk.soft)
                .scaledPadding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.withTimes == 0 ? "No arrival times yet"
                            : "\(s.percent) percent of my flights landed late. \(DelayFacts.shareLine(s))")
    }

    private var lost: some View {
        let board = DelayFacts.board(report.lostMinutes)
        return VStack(alignment: .leading, spacing: 6) {
            FlapBoard(value: board.value, unit: board.unit)
            Text("Spent waiting on late arrivals")
                .scaledFont(24, weight: .bold)
                .foregroundStyle(.white)
                .scaledPadding(.top, 8)
            Text(DelayFacts.averageLine(report.averageLateMinutes, late: report.lateArrivals.late))
                .scaledFont(17)
                .monospacedDigit()
                .foregroundStyle(DelayInk.soft)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DelayFacts.spoken(report.lostMinutes)) spent waiting on late arrivals. "
                            + DelayFacts.averageLine(report.averageLateMinutes, late: report.lateArrivals.late))
    }

    private func worstDelay(_ worst: DelayReport.Late) -> some View {
        let f = worst.flight
        let route = "\(lookup(f.originIcao)?.iata ?? f.originIcao)-\(lookup(f.destinationIcao)?.iata ?? f.destinationIcao)"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Longest wait")
                .scaledFont(24, weight: .bold)
                .foregroundStyle(.white)
            LEDStrip(parts: [DelayFacts.led(worst.minutes), f.isPrivate ? "PRIVATE" : f.ident.uppercased(), route])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Longest wait: \(DelayFacts.spoken(worst.minutes)) late, \(Format.ident(f)), "
                            + "\(lookup(f.originIcao)?.city ?? f.originIcao) to \(lookup(f.destinationIcao)?.city ?? f.destinationIcao)")
    }

    private var worstAirline: some View {
        let top = report.airlineLosses[0]
        let name = reference.airline(top.key)?.name ?? top.key
        return VStack(alignment: .leading, spacing: 4) {
            Text("Hardest-hit airline")
                .scaledFont(24, weight: .bold)
                .foregroundStyle(.white)
            Text("\(name) \u{00B7} \(DelayFacts.hoursShort(top.minutes)) late in all")
                .scaledFont(17)
                .monospacedDigit()
                .foregroundStyle(DelayInk.soft)
                .lineLimit(2)
            AirlineLossBar(losses: report.airlineLosses)
                .scaledPadding(.top, 10)
        }
    }

    private var basis: some View {
        Text(DelayFacts.basis(report))
            .scaledFont(13)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sections

struct DelayReportSections: View {
    var report: DelayReport
    var year: Int?
    var key: Int
    var lookup: (String) -> Airport?
    @State private var moreAirlines = false
    @State private var moreAirports = false
    @State private var moreDelays = false
    @Environment(\.reference) private var reference

    static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReportSection(title: "My Performance", key: key) { performance }
            ReportSection(title: "Airline Performance", key: key) { airlines(expanded: moreAirlines) }
            ReportSection(title: "Airport Performance", key: key) { airports(expanded: moreAirports) }
            ReportSection(title: "Arrival Delays", key: key) { delays(expanded: moreDelays) }
        }
        .rollingDigits()
    }

    // MARK: My performance

    private var performance: some View {
        let net = DelayFacts.net(report.netMinutes)
        return VStack(alignment: .leading, spacing: 14) {
            BigFigure(value: net.value, unit: net.unit,
                      caption: "net arrival time over \(DelayFacts.flights(report.withTimes)) with times")
            VStack(spacing: 10) {
                ForEach(DelayReport.Bucket.allCases, id: \.self) { b in
                    HStack(spacing: 12) {
                        Text(ui: b.title)
                            .scaledFont(16, weight: .medium)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 96, alignment: .leading)
                        Bar(fraction: report.fraction(b), fill: DelayInk.bucket(b), height: 22)
                        Text("\(report.percent(b))%")
                            .scaledFont(16, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(b.title): \(report.percent(b)) percent, \(report.count(b)) flights")
                }
            }
        }
    }

    // MARK: Airlines

    private func airlines(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BigFigure(value: report.withTimes == 0 ? "None" : "\(report.lateArrivals.percent)%", unit: "late arrivals",
                      caption: nil)
            let rows = expanded ? report.airlines : Array(report.airlines.prefix(Self.shown))
            ForEach(rows) { row in
                let airline = reference.airline(row.key)
                ShareBarRow(title: airline.map { AircraftImage.shortName($0) } ?? row.key, share: row.share,
                            accessibility: airline?.name ?? row.key) {
                    AirlineMark(code: airline?.iata ?? row.key, key: row.key, size: 26, decorative: true)
                        .environment(\.logoSurface, .fixed(0x161314))
                }
            }
            if report.airlines.isEmpty { empty("No arrival times yet") }
            if report.airlines.count > Self.shown { ShowMoreButton(expanded: $moreAirlines, noun: "airlines", limit: Self.shown) }
        }
    }

    // MARK: Airports

    private func airports(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BigFigure(value: report.lateDepartures.of == 0 ? "None" : "\(report.lateDepartures.percent)%",
                      unit: "late departures",
                      caption: report.lateDepartures.of == 0 ? nil : "\(report.lateDepartures.of) departures with times")
            let rows = expanded ? report.airports : Array(report.airports.prefix(Self.shown))
            ForEach(rows) { row in
                let airport = lookup(row.key)
                let country = row.country ?? airport?.country
                ShareBarRow(title: airport?.iata ?? row.key, share: row.share,
                            accessibility: airport?.name ?? row.key) {
                    Text(country.map(AirportFacts.flag) ?? "\u{1F3F3}\u{FE0F}")
                        .scaledFont(22)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                }
            }
            if report.airports.isEmpty { empty("No departure times yet. They come in with an import that has them.") }
            if report.airports.count > Self.shown { ShowMoreButton(expanded: $moreAirports, noun: "airports", limit: Self.shown) }
        }
    }

    // MARK: Arrival delays

    private func delays(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BigFigure(value: "\(report.arrivalDelays.count)", unit: "total", caption: nil)
            let rows = expanded ? report.arrivalDelays : Array(report.arrivalDelays.prefix(Self.shown))
            VStack(spacing: 0) {
                ForEach(rows) { late in
                    LateArrivalRow(late: late, origin: lookup(late.flight.originIcao),
                                   destination: lookup(late.flight.destinationIcao))
                }
            }
            if rows.isEmpty { empty(year.map { "No late arrivals in \(String($0))" } ?? "No late arrivals yet") }
            if report.arrivalDelays.count > Self.shown { ShowMoreButton(expanded: $moreDelays, noun: "late arrivals", limit: Self.shown) }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(ui: text).scaledFont(15).foregroundStyle(Theme.secondary)
    }
}

/// "45%" big, "late arrivals" beside it in grey, an optional caption under.
struct BigFigure: View {
    var value: String
    var unit: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { number; label }
                VStack(alignment: .leading, spacing: 0) { number; label }
            }
            if let caption {
                Text(ui: caption).scaledFont(17).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var number: some View {
        Text(ui: value).scaledFont(54, weight: .bold).monospacedDigit().foregroundStyle(Theme.primary).lineLimit(1)
            .rollingDigits()
    }

    private var label: some View {
        Text(ui: unit).scaledFont(32, weight: .regular).foregroundStyle(Theme.secondary).lineLimit(1)
    }
}

/// The airline mark, "LH 7995", how late in red, "MUC-SFO" and the day; stacked at large type sizes.
struct LateArrivalRow: View {
    var late: DelayReport.Late
    var origin: Airport?
    var destination: Airport?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let f = late.flight
        let route = "\(origin?.iata ?? f.originIcao)-\(destination?.iata ?? f.destinationIcao)"
        let day = ScreenFormat.day(f.date, origin?.timeZone ?? TimeZone(identifier: f.originTz ?? "UTC") ?? .gmt)
        Group {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 10) {
                    mark
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { ident; Spacer(); delay }
                        Text("\(route)  \(day)").scaledFont(15).foregroundStyle(Theme.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    mark
                    ident.frame(minWidth: 66, alignment: .leading)
                    delay.frame(minWidth: 58, alignment: .leading)
                    Text(ui: route).scaledFont(15).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    Text(ui: day).scaledFont(15).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                        .minimumScaleFactor(0.8).layoutPriority(1)
                }
            }
        }
        .scaledPadding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.ident(f)), \(DelayFacts.spoken(late.minutes)) late, "
                            + "\(origin?.city ?? f.originIcao) to \(destination?.city ?? f.destinationIcao), \(day)")
    }

    private var mark: some View {
        PastFlightMark(flight: late.flight, size: 24, decorative: true)
            .environment(\.logoSurface, .fixed(0x161314))
    }

    private var ident: some View {
        Text(Format.ident(late.flight)).scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary)
            .lineLimit(1).fixedSize()
    }

    private var delay: some View {
        Text(Format.minutes(late.minutes)).scaledFont(15, weight: .semibold).monospacedDigit()
            .foregroundStyle(DelayInk.late).lineLimit(1)
    }
}

// MARK: - Copy

/// The Delay Report's words and numbers as text.
enum DelayFacts {
    /// "21 of 47 flights with times reached the gate after schedule".
    static func shareLine(_ s: DelayReport.Share) -> String {
        guard s.of > 0 else { return "None of these flights has an arrival time yet" }
        return "\(s.late) of \(flights(s.of)) with times reached the gate after schedule"
    }

    /// "1 flight", "47 flights".
    static func flights(_ n: Int) -> String { n == 1 ? "1 flight" : "\(n) flights" }

    /// What the flap board spells: whole hours from one hour up ("7", "HRS"), else minutes ("45", "MIN").
    static func board(_ minutes: Int) -> (value: String, unit: String) {
        if minutes >= 60 {
            let h = minutes / 60
            return ("\(h)", h == 1 ? "HR" : "HRS")
        }
        return ("\(minutes)", "MIN")
    }

    /// "Late flights ran 21m behind on average".
    static func averageLine(_ average: Int, late: Int) -> String {
        late == 0 ? "No flight landed late" : "Late flights ran \(Format.minutes(average)) behind on average"
    }

    /// The strip's duration: "1H 31M", "45 MIN".
    static func led(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)H \(String(format: "%02d", minutes % 60))M" : "\(minutes) MIN"
    }

    /// "3h", "1h 20m" under 2 hours, "45m" under one.
    static func hoursShort(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 120, minutes % 60 != 0 { return "1h \(minutes % 60)m" }
        return "\((minutes + 30) / 60)h"
    }

    /// The same, for VoiceOver.
    static func hours(_ minutes: Int) -> String { spoken(minutes) }

    /// "7 hours 25 minutes", "1 minute".
    static func spoken(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let hp = h == 1 ? "1 hour" : "\(h) hours"
        let mp = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 { return mp }
        return m == 0 ? hp : "\(hp) \(mp)"
    }

    /// The net arrival time as the big figure: "5m" "late", "12m" "early", "0m" "on time".
    static func net(_ minutes: Int) -> (value: String, unit: String) {
        if minutes == 0 { return ("0m", "on time") }
        return (Format.minutes(abs(minutes)), minutes > 0 ? "late" : "early")
    }

    /// "Based on 47 of 57 flights with arrival times. 10 have none." and the canceled and diverted ones.
    static func basis(_ r: DelayReport) -> String {
        var parts = ["Based on \(r.withTimes) of \(flights(r.flights)) with arrival times."]
        if r.noData > 0 { parts.append(r.noData == 1 ? "1 has none." : "\(r.noData) have none.") }
        let other = [r.canceled > 0 ? "\(r.canceled) canceled" : nil, r.diverted > 0 ? "\(r.diverted) diverted" : nil]
            .compactMap { $0 }
        if !other.isEmpty { parts.append(other.joined(separator: " and ").prefix(1).uppercased()
                                         + other.joined(separator: " and ").dropFirst() + ".") }
        parts.append("Late means any minute after schedule.")
        return parts.joined(separator: " ")
    }

    /// The line under a shared section.
    @MainActor static var signature: some View {
        HStack {
            Text("SOMA FLIGHT").scaledFont(12, weight: .heavy).tracking(1.5).foregroundStyle(DelayInk.amber)
            Spacer()
            Text("Delay Report").scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 6)
    }
}
