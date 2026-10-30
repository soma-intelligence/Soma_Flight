import SwiftUI

// MARK: - Wording

extension DetailFacts {
    /// "+8 hours time zone change" and "10:15 arrival is 02:15 San Francisco time": how far the
    /// destination's clock is from the origin's at the moment of arrival. Half hours read "+5h 30m",
    /// westbound changes are negative. nil when both clocks agree at arrival.
    static func timeZoneChange(origin: Airport, destination: Airport, arrival: Date,
                               clock: TimeStyle = .h24) -> (title: String, text: String)? {
        let diff = destination.timeZone.secondsFromGMT(for: arrival) - origin.timeZone.secondsFromGMT(for: arrival)
        guard diff != 0 else { return nil }
        let minutes = abs(diff) / 60
        let h = minutes / 60, m = minutes % 60
        let amount: String = if m == 0 {
            "\(h) \(h == 1 ? "hour" : "hours")"
        } else {
            h == 0 ? "\(m)m" : "\(h)h \(m)m"
        }
        let title = "\(diff > 0 ? "+" : "-")\(amount) time zone change"
        let text = "\(Format.clock(arrival, destination.timeZone, clock)) arrival is "
            + "\(Format.clock(arrival, origin.timeZone, clock)) \(origin.city) time"
        return (title, text)
    }

    /// The disruption row of an airport: only when its departures (origin) or arrivals (destination) run
    /// at moderate or major severity.
    static func disruption(code: String, stats: DelayStats?, departures: Bool) -> (title: String, text: String)? {
        guard let stats, stats.severity != .normal else { return nil }
        let avg = Format.minutes(Int(stats.avgDelayMinutes.rounded()))
        return ("Delays at \(code)",
                "\(departures ? "Departures" : "Arrivals") average \(avg) late right now. Tap for the airport's details.")
    }

    /// "18°C and scattered clouds"; the sky alone when there is no temperature.
    static func weatherText(_ w: Weather) -> String {
        let sky = Sky(metar: w.metarRaw).description
        guard let t = w.tempC else { return sky.prefix(1).uppercased() + sky.dropFirst().lowercased() }
        return "\(Int(t.rounded()))°C and \(sky.lowercased())"
    }
}

// MARK: - Cards

/// The bordered card every lower section of the flight sheet sits in.
struct DetailCard<Content: View>: View {
    var padded: Bool
    var content: Content

    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.padded = padded; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .scaledPadding(.all, padded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
    }
}

/// Title and grey subtitle at the top of a card.
struct CardTitle: View {
    var title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Good to Know: per airport, a header that opens the airport sheet with the disruption row under it when
/// delays build, then that airport's weather; last, the time zone change.
struct GoodToKnow: View {
    struct Side {
        var icao: String
        var code: String
        var stats: DelayStats?
        var weather: Weather?
        var departures: Bool
    }

    var origin: Side
    var destination: Side?
    var timeZone: (title: String, text: String)?
    var onAirport: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Good to Know")
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
                .scaledPadding(.bottom, 4)
            block(origin)
            if let destination { block(destination) }
            if let timeZone {
                DetailCard {
                    InfoRow(symbol: "clock.arrow.circlepath", title: timeZone.title, text: timeZone.text)
                }
            }
        }
    }

    @ViewBuilder private func block(_ side: Side) -> some View {
        let disruption = DetailFacts.disruption(code: side.code, stats: side.stats, departures: side.departures)
        DetailCard(padded: false) {
            Button { onAirport(side.icao) } label: {
                HStack(spacing: 4) {
                    Text(side.code).scaledFont(19, weight: .medium)
                    Image(systemName: "chevron.right").scaledFont(15, weight: .semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.primary)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(side.code) airport")
            .accessibilityHint("Opens the airport")
            if let disruption {
                Hairline()
                Button { onAirport(side.icao) } label: {
                    InfoRow(symbol: "exclamationmark.triangle.fill", tint: tint(side.stats?.severity),
                            title: disruption.title, titleTint: tint(side.stats?.severity), text: disruption.text,
                            chevron: true)
                        .scaledPadding(.all, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if let w = side.weather {
            DetailCard {
                InfoRow(symbol: Sky(metar: w.metarRaw).symbol(night: false), multicolor: true,
                        title: side.departures ? "Departure weather" : "Arrival weather",
                        text: DetailFacts.weatherText(w))
            }
        }
    }

    private func tint(_ s: Severity?) -> Color { s == .major ? Theme.veryLate : Theme.late }
}

/// Icon, title and one grey line: the rows of Good to Know.
struct InfoRow: View {
    var symbol: String
    var tint: Color = Theme.primary
    var multicolor = false
    var title: String
    var titleTint: Color = Theme.primary
    var text: String
    var chevron = false
    @ScaledMetric(relativeTo: .body) private var iconWidth = 34

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome)
                .scaledFont(24, weight: .medium)
                .foregroundStyle(tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scaledFont(19, weight: .medium).foregroundStyle(titleTint)
                (chevron ? Text("\(text) \(Image(systemName: "chevron.right"))") : Text(text))
                    .scaledFont(16)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
