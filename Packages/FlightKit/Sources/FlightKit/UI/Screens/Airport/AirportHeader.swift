import SwiftUI

/// Code chips (IATA, ICAO, local time), the airport name and flag with city and country.
/// The close button belongs to the sheet shell, so the trailing edge is left free for it.
struct AirportHeader: View {
    @Environment(\.units) private var units
    var airport: Airport?
    var code: String
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if let iata = airport?.iata { chip(iata) }
                chip(airport?.id ?? code)
                if let airport { chip(localTime(airport.timeZone)) }
            }
            .scaledPadding(.bottom, 6)
            Text(airport?.name ?? code)
                .themeFont(.sheetTitle)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let airport {
                HStack(spacing: 5) {
                    Text(AirportFacts.flag(airport.country)).scaledFont(13)
                    Text("\(airport.city), \(AirportFacts.countryName(airport.country))".uppercased())
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .scaledPadding(.top, 3)
            }
        }
        .scaledPadding(.trailing, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func localTime(_ tz: TimeZone) -> String {
        "\(Format.clock(now, tz, units.clock)) \(tz.abbreviation(for: now) ?? "")"
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .themeFont(.chip)
            .foregroundStyle(Theme.secondary)
            .scaledPadding(.horizontal, 5)
            .scaledPadding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.grid, lineWidth: 1))
    }
}

/// Maroon card at the top of the sheet when the day is going badly: the FAA's programs and runway
/// notices first, then one line each for departures, arrivals and weather, the weather line saying
/// whether it explains the delays.
struct IssuesCard: View {
    var severity: Severity
    var departures: DelayStats?
    var arrivals: DelayStats?
    var weather: Weather?
    /// FAA programs and the NOTAM line (`FAAFacts.airportRows`).
    var programs: [AdvisoryRowData] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                let dot = severity == .major ? Theme.veryLate : Theme.late
                ZStack {
                    Circle().fill(dot.opacity(0.25)).frame(width: 16, height: 16)
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(FAAFacts.issuesTitle(severity, programs: programs))
                    .scaledFont(19, weight: .semibold)
                    .foregroundStyle(Theme.primary)
            }
            .scaledPadding(.bottom, 14)
            IssuesProgramRows(rows: programs)
            if let departures, let arrivals {
                if !programs.isEmpty { divider }
                row("airplane.departure", "Departures", AirportFacts.delayLine(departures, verb: "Leaving"))
                divider
                row("airplane.arrival", "Arrivals", AirportFacts.delayLine(arrivals, verb: "Arriving"))
            }
            if let weather, let departures, let arrivals {
                divider
                row(Sky(metar: weather.metarRaw).symbol(night: false), "Weather",
                    AirportFacts.issuesWeatherLine(weather, departures: departures, arrivals: arrivals))
            }
        }
        .scaledPadding(.horizontal, 18)
        .scaledPadding(.top, 18)
        .scaledPadding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.issues))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.issuesRim, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(Theme.primary.opacity(0.12)).frame(height: 1).scaledPadding(.leading, 30)
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .scaledFont(15, weight: .medium)
                .foregroundStyle(Theme.primary)
                .frame(width: 20)
                .scaledPadding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).scaledFont(15.5, weight: .medium).foregroundStyle(Theme.primary)
                Text(text)
                    .scaledFont(14.5)
                    .foregroundStyle(Theme.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledPadding(.vertical, 10)
    }
}
