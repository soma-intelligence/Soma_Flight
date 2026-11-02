import SwiftUI
import FlightImportKit

// MARK: - Wording

/// What My Flights shows for a flight added weeks ahead that is not followed yet (`FollowLaterQueue`).
enum PlannedFlight {
    /// When it leaves as best known: the departure the source gave, else the start of its day at the origin.
    static func departure(_ u: UpcomingFlight, origin: Airport?) -> Date {
        if let d = u.departure { return d }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = origin?.timeZone ?? .current
        let parts = DateComponents(year: u.day.year, month: u.day.month, day: u.day.day)
        return cal.date(from: parts) ?? .distantFuture
    }

    /// The figure and unit word of the countdown column, in `MyFlightRow`'s own words: days at a day or
    /// more ("3" "DAYS"), then hours ("5" "HRS"). Past its time, or inside the last hour, only "PLANNED".
    static func countdown(_ u: UpcomingFlight, origin: Airport?, now: Date) -> (value: String, unit: String) {
        let s = departure(u, origin: origin).timeIntervalSince(now)
        if s >= 86_400 {
            let d = Int(s / 86_400)
            return ("\(d)", d == 1 ? "DAY" : "DAYS")
        }
        if s >= 3600 {
            let h = Int(s / 3600)
            return ("\(h)", h == 1 ? "HR" : "HRS")
        }
        return ("", "PLANNED")
    }

    /// The word under the unit when there is a figure above it.
    static let caption = "PLANNED"

    /// "Fri, Oct 30": its day at the origin, which is the day it was added with.
    static func day(_ u: UpcomingFlight) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        guard let date = cal.date(from: DateComponents(year: u.day.year, month: u.day.month, day: u.day.day, hour: 12))
        else { return "" }
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
        style = style.weekday(.abbreviated).month(.abbreviated).day()
        return date.formatted(style)
    }
}

// MARK: - Row

/// A flight added ahead of time, in My Flights until it comes within reach and is followed: the same
/// columns as `MyFlightRow` (countdown, airline logo, number and date, route, the two codes), with
/// "PLANNED" under the countdown. It has no status, gate or terminal, and no detail screen.
struct PlannedFlightRow: View {
    var flight: UpcomingFlight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var now: Date
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var column: CGFloat = 66
    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 24

    private var originName: String { origin?.city ?? flight.origin ?? "TBA" }
    private var destinationName: String { destination?.city ?? flight.destination ?? "TBA" }
    private var count: (value: String, unit: String) {
        PlannedFlight.countdown(flight, origin: origin, now: now)
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(accessibilityCountdown)
                        .scaledFont(20, weight: .semibold)
                        .foregroundStyle(count.value.isEmpty ? Theme.secondary : Theme.primary)
                    details
                }
                .scaledPadding(.vertical, 14)
                .overlay(alignment: .bottom) { Hairline() }
            } else {
                HStack(alignment: .center, spacing: 13) {
                    countdown
                        .frame(width: column)
                    VStack(alignment: .leading, spacing: 0) {
                        details
                            .scaledPadding(.vertical, 14)
                        Hairline()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityCountdown: String {
        count.value.isEmpty ? count.unit : "\(count.value) \(count.unit) \(PlannedFlight.caption)"
    }

    private var countdown: some View {
        VStack(spacing: 2) {
            if !count.value.isEmpty {
                Text(count.value)
                    .scaledFont(34, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(count.unit)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !count.value.isEmpty {
                Text(PlannedFlight.caption)
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var code: String { TravelFacts.airlineCode(ident: flight.ident) }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    logoAndIdent
                    Spacer(minLength: 8)
                    dayText
                }
                VStack(alignment: .leading, spacing: 2) {
                    logoAndIdent
                    dayText
                }
            }
            RouteText(from: originName, to: destinationName)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { ends }
                VStack(alignment: .leading, spacing: 4) { ends }
            }
            .scaledPadding(.top, 2)
        }
    }

    private var logoAndIdent: some View {
        HStack(alignment: .center, spacing: 8) {
            AirlineLogo(airline: airline, code: code, size: mark, decorative: true)
            Text(Format.ident(flight.ident))
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize()
        }
    }

    private var dayText: some View {
        Text(PlannedFlight.day(flight))
            .scaledFont(15)
            .foregroundStyle(Theme.secondary)
            .fixedSize()
    }

    @ViewBuilder private var ends: some View {
        end(icon: "arrow.up.right", code: flight.origin ?? "---",
            time: flight.departure.map { Format.clock($0, origin?.timeZone ?? .current, units.clock) })
        end(icon: "arrow.down.right", code: flight.destination ?? "---", time: nil)
    }

    private func end(icon: String, code: String, time: String?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .scaledFont(10, weight: .bold)
                .foregroundStyle(Theme.background)
                .scaledPadding(.all, 4)
                .background(Circle().fill(Theme.secondary.opacity(0.75)))
                .accessibilityHidden(true)
            Text(code)
                .foregroundStyle(Theme.secondary)
            Text(time ?? "--:--")
                .foregroundStyle(Theme.primary)
        }
        .scaledFont(17)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var accessibilityText: String {
        [Format.ident(flight.ident), ScreenFormat.route(originName, destinationName), PlannedFlight.day(flight),
         count.value.isEmpty ? "Planned" : "\(count.value) \(count.unit.lowercased()), planned"].joined(separator: ", ")
    }
}
