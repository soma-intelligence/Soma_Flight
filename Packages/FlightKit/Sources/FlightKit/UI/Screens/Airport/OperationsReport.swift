import SwiftUI

/// The airport's Operations Report, laid out like a dispatch briefing: a plain summary, then dotted
/// sections for departures, arrivals, the weather impact, current conditions with the raw METAR, the
/// TAF period by period and, last, when each source was fetched. Reads the airport sheet's store, so
/// it asks the network for nothing more.
public struct OperationsReportView: View {
    @Environment(\.units) private var units
    var store: AirportStore
    var fixedNow: Date?
    var onClose: (() -> Void)?
    var scrolls: Bool

    /// - Parameters:
    ///   - now: a fixed clock for previews; nil follows the real time, refreshed each minute.
    ///   - onClose: shows the round close button when set.
    public init(store: AirportStore, now: Date? = nil, onClose: (() -> Void)? = nil) {
        self.init(store: store, now: now, onClose: onClose, scrolls: true)
    }

    /// `scrolls: false` lays everything out in one tall stack (snapshots).
    init(store: AirportStore, now: Date?, onClose: (() -> Void)?, scrolls: Bool) {
        self.store = store; self.fixedNow = now; self.onClose = onClose; self.scrolls = scrolls
    }

    public var body: some View {
        Group {
            if let fixedNow {
                page(now: fixedNow)
            } else {
                TimelineView(.everyMinute) { page(now: $0.date) }
            }
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            if let onClose { CloseButton(action: onClose) }
        }
    }

    @ViewBuilder private func page(now: Date) -> some View {
        if scrolls {
            ScrollView { content(now: now) }
        } else {
            content(now: now)
        }
    }

    private var tz: TimeZone { store.airport?.timeZone ?? .current }
    private var code: String { store.airport?.iata ?? store.airport?.id ?? "" }

    private func content(now: Date) -> some View {
        let report = OpsReport(code: code, stats: store.stats, weather: store.weather, timeZone: tz, now: now,
                               clock: units.clock)
        return VStack(alignment: .leading, spacing: 0) {
            header(report)
            if let d = report.departures { boardSection(d, now: now) }
            if let a = report.arrivals { boardSection(a, now: now) }
            if let impact = report.impact { impactSection(impact, cause: report.cause) }
            if let w = store.weather {
                conditionsSection(report, weather: w, now: now)
                forecastSection(report, weather: w, now: now)
            }
            sourcesSection(now: now)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.bottom, 40)
    }

    // MARK: Header

    private func header(_ report: OpsReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if let iata = store.airport?.iata { BriefChip(text: iata) }
                BriefChip(text: store.airport?.id ?? code)
            }
            .scaledPadding(.bottom, 8)
            Text("Operations Report")
                .scaledFont(26, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Delays read live from the boards, and the official weather reports pilots get, put into plain words.")
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 4)
            Text(report.summary)
                .scaledFont(18, weight: .medium)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 20)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.top, 24)
        .scaledPadding(.trailing, onClose == nil ? 0 : 50)
    }

    // MARK: Sections

    private func boardSection(_ b: OpsReport.Board, now: Date) -> some View {
        BriefSection(symbol: b.departures ? "airplane.departure" : "airplane.arrival",
                     title: b.departures ? "Departures" : "Arrivals") {
            BriefItem(title: "Current Delay", tint: tint(b.severity),
                      text: OpsReport.delayHeadline(b) + " " + OpsReport.delayDetail(b),
                      source: "From the live \(b.departures ? "departure" : "arrival") board" + updated(.stats, now: now))
            if let t = b.trend {
                BriefItem(title: "Trend", text: OpsReport.trendLine(t), source: "Late flights per hour, today")
            }
        }
    }

    private func impactSection(_ i: WeatherImpact, cause: DelayCause?) -> some View {
        BriefSection(symbol: "cloud.bolt.rain", title: "Weather Impact") {
            BriefItem(title: Self.verdictTitle(i), tint: i.slows ? (i.level == .severe ? Theme.veryLate : Theme.late) : nil,
                      text: Self.verdictText(i, cause: cause),
                      source: "Read from the METAR and the board's delays")
        }
    }

    private func conditionsSection(_ r: OpsReport, weather w: Weather, now: Date) -> some View {
        BriefSection(symbol: Sky(metar: w.metarRaw).symbol(night: false), title: "Current Conditions") {
            VStack(alignment: .leading, spacing: 0) {
                CategoryTag(category: w.category).scaledPadding(.bottom, 8)
                BriefItem(title: r.conditionsTitle ?? "Conditions", text: r.conditionsText ?? "",
                          source: "Source: METAR • observed \(Format.ago(w.observedAt, now: now))")
                RawReport(text: w.metarRaw)
            }
        }
    }

    private func forecastSection(_ r: OpsReport, weather w: Weather, now: Date) -> some View {
        BriefSection(symbol: "clock.arrow.circlepath", title: "Forecast") {
            if r.periods.isEmpty {
                BriefItem(title: "No Forecast", text: "This airport has no terminal forecast (TAF) right now.", source: nil)
            } else {
                ForEach(Array(r.periods.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(p.label).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                            Spacer(minLength: 0)
                            CategoryTag(category: p.category, compact: true)
                        }
                        Text(p.text)
                            .scaledFont(15.5)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .scaledPadding(.top, 3)
                        if p.impact.level >= .minor {
                            Text(p.impact.reason + ".")
                                .scaledFont(15, weight: .medium)
                                .foregroundStyle(p.impact.slows ? Theme.late : Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .scaledPadding(.top, 3)
                        }
                    }
                    .scaledPadding(.bottom, 16)
                    .accessibilityElement(children: .combine)
                }
                if let issued = w.tafIssuedAt {
                    SourceLine(text: "Source: TAF • issued \(Format.ago(issued, now: now))")
                } else {
                    SourceLine(text: "Source: TAF")
                }
                if let raw = w.tafRaw { RawReport(text: raw) }
            }
        }
    }

    private func sourcesSection(now: Date) -> some View {
        BriefSection(symbol: "antenna.radiowaves.left.and.right", title: "Sources") {
            VStack(alignment: .leading, spacing: 8) {
                sourceRow("Departure board", store.fetchedAt[.departures], now: now)
                sourceRow("Arrival board", store.fetchedAt[.arrivals], now: now)
                sourceRow("Delay figures", store.fetchedAt[.stats], now: now)
                sourceRow("Weather fetched", store.fetchedAt[.weather], now: now)
                sourceRow("METAR observed", store.weather?.observedAt, now: now)
                sourceRow("TAF issued", store.weather?.tafIssuedAt, now: now)
                Text("Weather from aviationweather.gov (NOAA). Delays from the live boards in this app.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 6)
            }
        }
    }

    @ViewBuilder private func sourceRow(_ label: String, _ date: Date?, now: Date) -> some View {
        if let date {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased())
                Spacer(minLength: 8)
                Text("\(Format.clock(date, tz, units.clock)) • \(Format.ago(date, now: now).uppercased())")
            }
            .scaledFont(12, design: .monospaced)
            .foregroundStyle(Theme.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func updated(_ part: BoardKind, now: Date) -> String {
        store.fetchedAt[part].map { " • updated \(Format.ago($0, now: now))" } ?? ""
    }

    private func tint(_ s: Severity) -> Color? {
        switch s {
        case .normal: nil
        case .moderate: Theme.late
        case .major: Theme.veryLate
        }
    }

    // MARK: Wording

    static func verdictTitle(_ i: WeatherImpact) -> String {
        switch i.level {
        case .severe: "Weather Is Holding Flights Up"
        case .moderate: "Weather Is Slowing Flights"
        case .minor: "Weather Is a Minor Factor"
        case .none: "Weather Is Not a Factor"
        }
    }

    static func verdictText(_ i: WeatherImpact, cause: DelayCause?) -> String {
        let first = i.level == .none ? "Nothing in the latest report should slow flights." : "\(i.reason)."
        let second: String? = switch cause {
        case .weather?: "It matches the delays on the boards, so they are likely weather related."
        case .notWeather?: "The boards show delays all the same, so they come from something else, such as traffic or late aircraft."
        case .weatherAhead?: "Flights are close to time so far."
        case .normal?, nil: nil
        }
        return [first, second].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Briefing pieces

/// Dotted rule with a small icon and an uppercase title, running to both edges.
struct BriefSection<Content: View>: View {
    var symbol: String
    var title: String
    var content: Content

    init(symbol: String, title: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol; self.title = title; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                DottedRule().frame(width: 12)
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .scaledFont(13, weight: .semibold)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .scaledFont(14, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                DottedRule()
            }
            .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 18) { content }
                .scaledPadding(.horizontal, Theme.gutter)
        }
        .scaledPadding(.top, 30)
    }
}

/// A line of dots across the available width.
struct DottedRule: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(Theme.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Title, grey body and an optional monospaced source line.
struct BriefItem: View {
    var title: String
    var tint: Color?
    var text: String
    var source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(tint ?? Theme.primary)
            Text(text)
                .scaledFont(16)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let source { SourceLine(text: source).scaledPadding(.top, 4) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SourceLine: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .scaledFont(11.5, design: .monospaced)
            .foregroundStyle(Theme.secondary.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The raw report as sent, in a monospaced block that can be selected and copied.
struct RawReport: View {
    var text: String

    var body: some View {
        Text(text)
            .scaledFont(12.5, design: .monospaced)
            .foregroundStyle(Theme.primary.opacity(0.85))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .scaledPadding(.all, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.grid, lineWidth: 1))
            .scaledPadding(.top, 10)
            .accessibilityLabel("Raw report: \(text)")
    }
}

/// "IFR" in its colour, with the long name unless compact.
struct CategoryTag: View {
    var category: FlightCategory
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            Text(category.rawValue)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(.white)
                .scaledPadding(.horizontal, 6)
                .scaledPadding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(category.color))
            if !compact {
                Text(category.name).scaledFont(14, weight: .medium).foregroundStyle(category.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.name)
    }
}

/// Small grey code chip ("SFO", "KSFO").
struct BriefChip: View {
    var text: String

    var body: some View {
        Text(text)
            .themeFont(.chip)
            .foregroundStyle(Theme.secondary)
            .scaledPadding(.horizontal, 5)
            .scaledPadding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.grid, lineWidth: 1))
    }
}

/// The airport sheet's way into the report: the weather verdict in one line and a chevron.
struct OperationsReportRow: View {
    var impact: WeatherImpact?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .scaledFont(22, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Operations Report").scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                    Text(impact.map { $0.reason } ?? "Delays and weather, decoded")
                        .scaledFont(14.5)
                        .foregroundStyle(impact?.slows == true ? Theme.late : Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Theme.secondary)
            }
            .scaledPadding(.all, 14)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the airport's operations report")
    }
}

#if DEBUG
// MARK: - Previews

#Preview("Austin: late, weather fine") {
    OperationsReportPreview(code: "KAUS")
        .preferredColorScheme(.dark)
}

#Preview("Paris CDG: fog") {
    OperationsReportPreview(code: "LFPG")
        .preferredColorScheme(.dark)
}

#Preview("San Francisco, light") {
    OperationsReportPreview(code: "KSFO")
        .preferredColorScheme(.light)
}

/// Loads a store from the seed at the seed's own clock.
struct OperationsReportPreview: View {
    var code: String
    @State private var store: AirportStore?

    var body: some View {
        Group {
            if let store {
                OperationsReportView(store: store, now: PreviewData.now, onClose: {})
            } else {
                ProgressView()
            }
        }
        .task {
            let s = AirportStore(code: code, airports: FakeAirportService(now: PreviewData.now))
            await s.load()
            store = s
        }
    }
}
#endif
