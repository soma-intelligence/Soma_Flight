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

    /// True when `f` is `u` followed: same flight number and the same departure day at the origin.
    static func matches(_ u: UpcomingFlight, _ f: Flight, reference: ReferenceData,
                        airport: (String) -> Airport?) -> Bool {
        guard let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut else { return false }
        let zone = airport(f.originIcao)?.timeZone ?? .gmt
        return FlightImportPlan.followKey(f.ident, LocalDay(out, in: zone), reference: reference)
            == FlightImportPlan.followKey(u.ident, u.day, reference: reference)
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
/// chrome as `MyFlightRow` (`FlightRowChrome`), with "PLANNED" under the countdown. It has no status,
/// gate or terminal, and no detail screen.
struct PlannedFlightRow: View {
    var flight: UpcomingFlight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var now: Date

    private var originName: String { origin?.city ?? flight.origin ?? "TBA" }
    private var destinationName: String { destination?.city ?? flight.destination ?? "TBA" }
    private var count: (value: String, unit: String) {
        PlannedFlight.countdown(flight, origin: origin, now: now)
    }

    var body: some View {
        FlightRowChrome(
            airline: airline, code: TravelFacts.airlineCode(ident: flight.ident), ident: Format.ident(flight.ident),
            day: PlannedFlight.day(flight), from: originName, to: destinationName,
            line: count.value.isEmpty ? count.unit : "\(count.value) \(count.unit) \(PlannedFlight.caption)",
            lineColor: count.value.isEmpty ? Theme.secondary : Theme.primary,
            accessibilityText: accessibilityText
        ) {
            countdown
        } ends: {
            FlightRowEnd(icon: "arrow.up.right", code: flight.origin ?? "---", time: flight.departure,
                         tz: origin?.timeZone, marker: nil)
            FlightRowEnd(icon: "arrow.down.right", code: flight.destination ?? "---", time: nil, tz: nil, marker: nil)
        }
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

    private var accessibilityText: String {
        [Format.ident(flight.ident), ScreenFormat.route(originName, destinationName), PlannedFlight.day(flight),
         count.value.isEmpty ? "Planned" : "\(count.value) \(count.unit.lowercased()), planned"].joined(separator: ", ")
    }
}
