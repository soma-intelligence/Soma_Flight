import SwiftUI

// MARK: - Wording

extension DetailFacts {
    /// The big figure and the word under it at the start of a My Flights row: time to the gate departure
    /// ("1" "DAY", "3" "DAYS", "5" "HRS", "1" "HR", "40" "MIN"), time left in the air ("2h" "LEFT", "40m"
    /// "LEFT"), or how it ended with no figure ("LANDED", "CANCELED", "DIVERTED"). Whole units, rounded down.
    static func countdownColumn(_ f: Flight, now: Date) -> (value: String, unit: String) {
        switch f.status {
        case .canceled: return ("", "CANCELED")
        case .diverted: return ("", "DIVERTED")
        case .landed, .arrived: return ("", "LANDED")
        case .departed, .enRoute:
            guard let end = bestIn(f) else { return ("", "IN AIR") }
            let m = max(0, Int(end.timeIntervalSince(now) / 60))
            return (m >= 60 ? "\(m / 60)h" : "\(m)m", "LEFT")
        case .scheduled, .unknown:
            guard let out = bestOut(f) else { return ("", "SCHEDULED") }
            let s = max(0, out.timeIntervalSince(now))
            if s >= 86_400 {
                let d = Int(s / 86_400)
                return ("\(d)", d == 1 ? "DAY" : "DAYS")
            }
            if s >= 3600 {
                let h = Int(s / 3600)
                return ("\(h)", h == 1 ? "HR" : "HRS")
            }
            return ("\(Int(s / 60))", "MIN")
        }
    }
}

// MARK: - Row

/// A followed flight in My Flights: the countdown column, then the airline logo, flight number and date,
/// the route by city, and the two codes with their local times (the arrival's "+1" when it lands on a
/// later local date). A hairline closes it under the text.
public struct MyFlightRow: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var now: Date
    @Environment(\.units) private var units
    @ScaledMetric(relativeTo: .largeTitle) private var column: CGFloat = 66

    public init(flight: Flight, origin: Airport?, destination: Airport?, airline: Airline?, now: Date = .now) {
        self.flight = flight; self.origin = origin; self.destination = destination
        self.airline = airline; self.now = now
    }

    /// "Fri, Oct 30": the day it leaves, in the origin's zone.
    static func day(_ f: Flight, origin: Airport?) -> String? {
        guard let out = f.scheduledOut ?? DetailFacts.bestOut(f) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = origin?.timeZone ?? .current
        df.dateFormat = "EEE, MMM d"
        return df.string(from: out)
    }

    /// The arrival's day marker ("+1"), from the detail sheet's rule.
    static func marker(_ f: Flight, origin: Airport?, destination: Airport?) -> String? {
        guard let out = DetailFacts.bestOut(f), let arr = DetailFacts.bestIn(f) else { return nil }
        return DetailFacts.dayMarker(departure: out, depTz: origin?.timeZone ?? .current,
                                     arrival: arr, arrTz: destination?.timeZone ?? .current)
    }

    public var body: some View {
        let count = DetailFacts.countdownColumn(flight, now: now)
        HStack(alignment: .center, spacing: 13) {
            countdown(count)
                .frame(width: column)
            VStack(alignment: .leading, spacing: 0) {
                details
                    .scaledPadding(.vertical, 14)
                Hairline()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(count))
    }

    private func countdown(_ c: (value: String, unit: String)) -> some View {
        VStack(spacing: 2) {
            if !c.value.isEmpty {
                Text(c.value)
                    .scaledFont(34, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(c.unit)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(unitColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var unitColor: Color {
        switch flight.status {
        case .canceled: Theme.veryLate
        case .diverted: Theme.diverted
        default: Theme.secondary
        }
    }

    private var code: String {
        flight.operator.map(AirportFacts.airlineCode) ?? TravelFacts.airlineCode(ident: flight.ident)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                AirlineLogo(airline: airline, code: code, size: 18, decorative: true)
                Text(Format.ident(flight.ident))
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                if let day = Self.day(flight, origin: origin) {
                    Text(day)
                        .scaledFont(15)
                        .foregroundStyle(Theme.secondary)
                }
            }
            RouteText(from: origin?.city ?? flight.originCode, to: destination?.city ?? flight.destinationCode)
                .lineLimit(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { ends }
                VStack(alignment: .leading, spacing: 4) { ends }
            }
            .scaledPadding(.top, 2)
        }
    }

    @ViewBuilder private var ends: some View {
        end(icon: "arrow.up.right", code: flight.originCode, time: DetailFacts.bestOut(flight),
            tz: origin?.timeZone, marker: nil)
        end(icon: "arrow.down.right", code: flight.destinationCode, time: DetailFacts.bestIn(flight),
            tz: destination?.timeZone, marker: Self.marker(flight, origin: origin, destination: destination))
    }

    private func end(icon: String, code: String, time: Date?, tz: TimeZone?, marker: String?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .scaledFont(10, weight: .bold)
                .foregroundStyle(Theme.background)
                .scaledPadding(.all, 4)
                .background(Circle().fill(Theme.secondary.opacity(0.75)))
                .accessibilityHidden(true)
            Text(code)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(time.map { Format.clock($0, tz ?? .current, units.clock) } ?? "--:--")
                    .foregroundStyle(Theme.primary)
                if let marker {
                    Text(marker)
                        .scaledFont(11, weight: .medium)
                        .foregroundStyle(Theme.primary)
                        .baselineOffset(8)
                }
            }
        }
        .scaledFont(17)
        .monospacedDigit()
        .lineLimit(1)
    }

    private func accessibilityText(_ c: (value: String, unit: String)) -> String {
        var parts = [Format.ident(flight.ident),
                     ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode)]
        if let day = Self.day(flight, origin: origin) { parts.append(day) }
        parts.append(c.value.isEmpty ? c.unit.capitalized : "\(c.value) \(c.unit.lowercased())")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Toast

/// A short confirmation in a glass capsule, shown over the tab pill ("Following UA 990").
public struct AddedToast: View {
    var text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .scaledFont(17, weight: .semibold)
        .scaledPadding(.horizontal, 22)
        .scaledPadding(.vertical, 13)
        .glassEffect(.regular.tint(HomeTabPill.tint), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
