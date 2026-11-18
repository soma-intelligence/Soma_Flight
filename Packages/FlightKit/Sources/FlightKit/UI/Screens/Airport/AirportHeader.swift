import SwiftUI

/// The airport sheet's Detail header (R5): the code in a grey square, "SFO · KSFO · 22:28 PST" in small caps,
/// the airport's name as the 20 pt title, the alert bell and the 44 pt glass close button. Under it, the flag
/// with the city and country, lined up with the title.
struct AirportHeader: View {
    @Environment(\.units) private var units
    var airport: Airport?
    var code: String
    var now: Date
    /// True while the first load runs: the city line searches for its letters.
    var loading = false
    /// The bell beside the close button (`FavoriteAirportToggle`); nil hides it.
    var actions: AnyView? = nil
    /// Closes the sheet; nil hides the close button.
    var onClose: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    /// "SFO · KSFO · 22:28 PST": the codes and the local time.
    static func overline(_ airport: Airport?, code: String, time: String?) -> String {
        [airport?.iata, airport?.id ?? code, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let overline = Self.overline(airport, code: code, time: airport.map { localTime($0.timeZone) })
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                // A12: the name wraps at accessibility sizes instead of "San Fran...".
                WrappingDetailHeader(overline: overline, title: airport?.name ?? code, actions: actions,
                                     onClose: onClose) { mark }
                place
                    .scaledPadding(.horizontal, Theme.gutter)
            } else {
                SheetHeader.detail(overline: overline, title: airport?.name ?? code, onClose: onClose) {
                    mark
                } actions: {
                    if let actions { actions }
                }
                place
                    // Lined up with the title: the gutter, the 36 pt mark and the 12 pt gap.
                    .scaledPadding(.leading, Theme.gutter + 36 + 12)
                    .scaledPadding(.trailing, Theme.gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mark: some View {
        Text(ui: airport?.iata ?? airport?.id ?? code)
            .scaledFont(12, weight: .bold)
            .foregroundStyle(Theme.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // The square stays 36 pt, so its code stops growing at xxLarge (the overline repeats it in full).
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pill))
    }

    @ViewBuilder private var place: some View {
        if loading && airport == nil {
            DecodeText(text: nil, placeholderLength: 22)
                .scaledFont(13, weight: .medium, design: .monospaced)
                .foregroundStyle(Theme.secondary.opacity(0.6))
                .lineLimit(1)
        } else if let airport {
            HStack(spacing: 5) {
                Text(AirportFacts.flag(airport.country)).scaledFont(13)
                Text("\(airport.city), \(AirportFacts.countryName(airport.country))")
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func localTime(_ tz: TimeZone) -> String {
        "\(Format.clock(now, tz, units.clock)) \(tz.abbreviation(for: now) ?? "")"
    }
}

// MARK: - Severity wording

/// The words of the airport's severity card (R7, R9). No SwiftUI here, so the tests read the exact text.
enum AirportSeverityFacts {
    /// One cause row: "Ground delay program at SFO", Major, "Average 47m · Low clouds · Until 04:28".
    struct Cause: Equatable, Sendable {
        var title: String
        var level: Severity
        var text: String
    }

    /// The word beside a cause's dot: "Major", "Moderate", "Calm".
    static func word(_ s: Severity) -> String {
        switch s {
        case .major: "Major"
        case .moderate: "Moderate"
        case .normal: "Calm"
        }
    }

    /// The weather's own level: calm unless it is likely slowing the airport, major when severe.
    static func level(_ w: Weather) -> Severity {
        let impact = WeatherImpact.of(w)
        guard impact.slows else { return .normal }
        return impact.level == .severe ? .major : .moderate
    }

    /// The card's causes: the FAA's programs and notices, then departures, arrivals and the weather.
    static func causes(departures: DelayStats?, arrivals: DelayStats?, weather: Weather?,
                       programs: [AdvisoryRowData]) -> [Cause] {
        var out = programs.map { Cause(title: $0.title, level: $0.severity, text: $0.text) }
        if let departures, let arrivals {
            out.append(Cause(title: "Departures", level: departures.severity,
                             text: AirportFacts.delayLine(departures, verb: "Leaving")))
            out.append(Cause(title: "Arrivals", level: arrivals.severity,
                             text: AirportFacts.delayLine(arrivals, verb: "Arriving")))
            if let weather {
                out.append(Cause(title: "Weather", level: level(weather),
                                 text: AirportFacts.issuesWeatherLine(weather, departures: departures, arrivals: arrivals)))
            }
        }
        return out
    }

    /// "5 causes · updated 22:28", "1 cause".
    static func subline(causes: Int, updated: String?) -> String {
        let count = causes == 1 ? Format.words("1 cause") : Format.words("\(causes) causes")
        return updated.map { Format.words("\(count) · updated \($0)") } ?? count
    }
}

/// The airport's delay summary on a bad day (R7): a white card with a severity bar on its leading edge and the
/// headline in the same colour ("Delays are building"), then one row per cause, each with its own dot and
/// level word (Major, Moderate, Calm) before its detail. Pink fill is kept for the closed airport only.
/// Penpot: Card/Severity
struct IssuesCard: View {
    var severity: Severity
    var departures: DelayStats?
    var arrivals: DelayStats?
    var weather: Weather?
    /// FAA programs and the NOTAM line (`FAAFacts.airportRows`).
    var programs: [AdvisoryRowData] = []
    /// "22:28": when the data was last fetched, in the airport's time; nil hides it.
    var updated: String? = nil

    static func tone(_ s: Severity) -> Color {
        switch s {
        case .major: Theme.veryLate
        case .moderate: Theme.late
        case .normal: Theme.onTime
        }
    }

    var body: some View {
        let title = FAAFacts.issuesTitle(severity, programs: programs)
        let causes = AirportSeverityFacts.causes(departures: departures, arrivals: arrivals, weather: weather,
                                                 programs: programs)
        let tone = Self.tone(severity == .normal ? .moderate : severity)
        IssuesCardShell(tone: tone, closed: programs.contains { $0.symbol == FAAFacts.symbol(.closure) }) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ui: title)
                        .scaledFont(19, weight: .semibold)
                        .foregroundStyle(tone)
                    Text(ui: AirportSeverityFacts.subline(causes: causes.count, updated: updated))
                        .themeFont(.sectionSubtitle)
                        .foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if !causes.isEmpty {
                    Hairline().scaledPadding(.top, 14).scaledPadding(.bottom, 4)
                    ForEach(Array(causes.enumerated()), id: \.offset) { _, c in row(c) }
                }
            }
        }
    }

    private func row(_ c: AirportSeverityFacts.Cause) -> some View {
        let tone = Self.tone(c.level)
        return VStack(alignment: .leading, spacing: 3) {
            Text(ui: c.title)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            // Only the level word takes the colour; the detail stays secondary so the card is not a flood.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SeverityDot(tone, diameter: 8)
                let word = Text(ui: AirportSeverityFacts.word(c.level)).foregroundStyle(tone).fontWeight(.semibold)
                Text("\(word) · \(Text(ui: c.text))")
                    .themeFont(.sectionSubtitle)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The severity card's surface: the flat `RefinedCard` with its leading bar, or, for a closed airport only,
/// the same card on the pink issues fill (R7).
private struct IssuesCardShell<Content: View>: View {
    var tone: Color
    var closed: Bool
    @ViewBuilder var content: Content
    @Environment(\.metricsScale) private var scale

    var body: some View {
        if closed {
            let shape = RoundedRectangle(cornerRadius: Theme.metric(Theme.cardRadius, scale), style: .continuous)
            content
                .scaledPadding(.all, 16)
                .scaledPadding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Theme.issues
                        tone.frame(width: Theme.metric(4, scale))
                    }
                }
                .clipShape(shape)
        } else {
            RefinedCard(severity: tone) { content }
        }
    }
}
