import SwiftUI

// MARK: - Wording

extension DetailFacts {
    /// The big figure and the word under it at the start of a My Flights row: time to the gate departure
    /// ("1" "DAY", "3" "DAYS", "5" "HRS", "1" "HR", "40" "MIN"), time left in the air ("2h" "LEFT", "40m"
    /// "LEFT"), or a word with no figure: how it ended ("LANDED", "CANCELED", "DIVERTED"), "DEPARTING" past
    /// its departure time while still at the gate, "ARRIVING" past its arrival time while still in the air,
    /// and "SCHEDULED" / "IN AIR" when the time is unknown. Whole units, rounded down.
    static func countdownColumn(_ f: Flight, now: Date) -> (value: String, unit: String) {
        switch f.status {
        case .canceled: return ("", "CANCELED")
        case .diverted: return ("", "DIVERTED")
        case .landed, .arrived: return ("", "LANDED")
        case .departed, .enRoute:
            guard let end = bestIn(f) else { return ("", "IN AIR") }
            let m = Int(end.timeIntervalSince(now) / 60)
            guard m >= 1 else { return ("", "ARRIVING") }
            return (m >= 60 ? "\(m / 60)h" : "\(m)m", "LEFT")
        case .scheduled, .unknown:
            guard let out = bestOut(f) else { return ("", "SCHEDULED") }
            let s = out.timeIntervalSince(now)
            guard s >= 60 else { return ("", "DEPARTING") }
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

// MARK: - Shared chrome

/// The layout both My Flights rows share, so they cannot drift apart: the countdown column beside the
/// airline logo, flight number and date, the route, and the two codes, closed by a hairline. At
/// accessibility sizes the countdown leads the text as one line. Only the countdown and the data differ.
struct FlightRowChrome<Countdown: View, Ends: View>: View {
    var airline: Airline?
    var code: String
    var ident: String
    var day: String?
    var from: String
    var to: String
    /// The accessibility-size one-line countdown and its colour.
    var line: String
    var lineColor: Color
    var accessibilityText: String
    @ViewBuilder var countdown: Countdown
    @ViewBuilder var ends: Ends
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var column: CGFloat = 66
    /// The airline's mark beside the flight number.
    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 24

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // No room for a column: the countdown leads the text as one line.
                VStack(alignment: .leading, spacing: 6) {
                    Text(ui: line)
                        .scaledFont(20, weight: .semibold)
                        .foregroundStyle(lineColor)
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
            RouteText(from: from, to: to)
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
            Text(ui: ident)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var dayText: some View {
        if let day {
            Text(ui: day)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize()
        }
    }
}

/// One end of a row's route: the arrow disc, the airport code and its local time ("--:--" when unknown),
/// with the arrival's day marker ("+1") when given.
struct FlightRowEnd: View {
    var icon: String
    var code: String
    var time: Date?
    var tz: TimeZone?
    var marker: String?
    @Environment(\.units) private var units

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: icon)
                .scaledFont(10, weight: .bold)
                .foregroundStyle(Theme.background)
                .scaledPadding(.all, 4)
                .background(Circle().fill(Theme.secondary.opacity(0.75)))
                .accessibilityHidden(true)
            Text(ui: code)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(time.map { Format.clock($0, tz ?? .current, units.clock) } ?? "--:--")
                    .foregroundStyle(Theme.primary)
                if let marker {
                    Text(ui: marker)
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

    public init(flight: Flight, origin: Airport?, destination: Airport?, airline: Airline?, now: Date = .now) {
        self.flight = flight; self.origin = origin; self.destination = destination
        self.airline = airline; self.now = now
    }

    /// "Fri, Oct 30": the day it leaves as best known (the time shown beside the origin), in the origin's zone.
    static func day(_ f: Flight, origin: Airport?) -> String? {
        guard let out = DetailFacts.bestOut(f) else { return nil }
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: origin?.timeZone ?? .current)
        style = style.weekday(.abbreviated).month(.abbreviated).day()
        return out.formatted(style)
    }

    /// The arrival's day marker ("+1"), from the detail sheet's rule.
    static func marker(_ f: Flight, origin: Airport?, destination: Airport?) -> String? {
        guard let out = DetailFacts.bestOut(f), let arr = DetailFacts.bestIn(f) else { return nil }
        return DetailFacts.dayMarker(departure: out, depTz: origin?.timeZone ?? .current,
                                     arrival: arr, arrTz: destination?.timeZone ?? .current)
    }

    public var body: some View {
        let count = DetailFacts.countdownColumn(flight, now: now)
        FlightRowChrome(
            airline: airline, code: code, ident: Format.ident(flight.ident), day: Self.day(flight, origin: origin),
            from: origin?.city ?? flight.originCode, to: destination?.city ?? flight.destinationCode,
            line: [count.value, count.unit].filter { !$0.isEmpty }.joined(separator: " "),
            lineColor: count.value.isEmpty ? unitColor : Theme.primary,
            accessibilityText: accessibilityText(count)
        ) {
            countdown(count)
        } ends: {
            FlightRowEnd(icon: "arrow.up.right", code: flight.originCode, time: DetailFacts.bestOut(flight),
                         tz: origin?.timeZone, marker: nil)
            FlightRowEnd(icon: "arrow.down.right", code: flight.destinationCode, time: DetailFacts.bestIn(flight),
                         tz: destination?.timeZone, marker: Self.marker(flight, origin: origin, destination: destination))
        }
    }

    private func countdown(_ c: (value: String, unit: String)) -> some View {
        VStack(spacing: 2) {
            if !c.value.isEmpty {
                Text(ui: c.value)
                    .scaledFont(34, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(ui: c.unit)
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

    private func accessibilityText(_ c: (value: String, unit: String)) -> String {
        var parts = [Format.ident(flight.ident),
                     ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode)]
        if let day = Self.day(flight, origin: origin) { parts.append(day) }
        parts.append(c.value.isEmpty ? c.unit.capitalized : "\(c.value) \(c.unit.lowercased())")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Toast

/// A short confirmation in a glass capsule, shown over the tab pill ("Added UA 990").
public struct AddedToast: View {
    var text: String
    /// A failure: a red mark instead of the accent check.
    var isError = false

    public init(text: String, isError: Bool = false) { self.text = text; self.isError = isError }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.veryLate : Theme.accent)
                .accessibilityHidden(true)
            Text(ui: text)
                .foregroundStyle(Theme.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .scaledFont(17, weight: .semibold)
        .scaledPadding(.horizontal, 22)
        .scaledPadding(.vertical, 13)
        .glassEffect(.regular.tint(HomeTabPill.tint), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The toast's place above the tab pill: slides up and fades, or only fades under Reduce Motion.
public struct ToastSlot: View {
    var text: String?
    /// The toast reports a failure: red mark and an error haptic as it shows.
    var isError = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String?, isError: Bool = false) { self.text = text; self.isError = isError }

    public var body: some View {
        Group {
            if let text {
                AddedToast(text: text, isError: isError)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: text)
        .sensoryFeedback(.error, trigger: text) { _, new in new != nil && isError }
    }
}
