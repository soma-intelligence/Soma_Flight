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
/// airline logo, flight number and date, the route, the two codes, and an optional footer (the refined
/// status line and progress bar, R1), closed by a hairline. At accessibility sizes the countdown leads the
/// text as one line. Only the countdown and the data differ.
struct FlightRowChrome<Countdown: View, Ends: View, Footer: View>: View {
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
    var countdown: Countdown
    var ends: Ends
    /// Under the times line: the progress bar and the status line of a followed flight.
    var footer: Footer
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var column: CGFloat = 66
    /// The airline's mark beside the flight number.
    @ScaledMetric(relativeTo: .subheadline) private var mark: CGFloat = 24

    init(airline: Airline?, code: String, ident: String, day: String?, from: String, to: String, line: String,
         lineColor: Color, accessibilityText: String, @ViewBuilder countdown: () -> Countdown,
         @ViewBuilder ends: () -> Ends, @ViewBuilder footer: () -> Footer) {
        self.airline = airline; self.code = code; self.ident = ident; self.day = day; self.from = from; self.to = to
        self.line = line; self.lineColor = lineColor; self.accessibilityText = accessibilityText
        self.countdown = countdown(); self.ends = ends(); self.footer = footer()
    }

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
            footer
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

extension FlightRowChrome where Footer == EmptyView {
    /// A row with nothing under its times (a planned flight: no status yet).
    init(airline: Airline?, code: String, ident: String, day: String?, from: String, to: String, line: String,
         lineColor: Color, accessibilityText: String, @ViewBuilder countdown: () -> Countdown,
         @ViewBuilder ends: () -> Ends) {
        self.init(airline: airline, code: code, ident: ident, day: day, from: from, to: to, line: line,
                  lineColor: lineColor, accessibilityText: accessibilityText, countdown: countdown, ends: ends) {
            EmptyView()
        }
    }
}

/// One end of a row's route: the arrow disc, the airport code and its local time ("--:--" when unknown),
/// with the arrival's day marker ("+1") when given. A time that moved from the schedule is drawn in the
/// status colour with the scheduled time struck through beside it (R1); an estimate the app made itself
/// (offline) says "est." instead.
struct FlightRowEnd: View {
    var icon: String
    var code: String
    var time: Date?
    var tz: TimeZone?
    var marker: String?
    /// The scheduled time, struck through when it differs from `time` by a minute or more.
    var scheduled: Date? = nil
    /// The colour of `time`; primary when nil.
    var tone: Color? = nil
    /// `time` is the app's own estimate (no connection): "est." follows it and no struck time shows.
    var estimated = false
    @Environment(\.units) private var units

    /// The scheduled time to strike through: only when the shown time moved from it by a minute or more.
    static func struck(time: Date?, scheduled: Date?) -> Date? {
        guard let time, let scheduled, abs(time.timeIntervalSince(scheduled)) >= 60 else { return nil }
        return scheduled
    }

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
                    .fontWeight(.semibold)
                    .foregroundStyle(tone ?? Theme.primary)
                if let marker {
                    Text(ui: marker)
                        .scaledFont(11, weight: .medium)
                        .foregroundStyle(tone ?? Theme.primary)
                        .baselineOffset(8)
                }
            }
            if estimated {
                Text(ui: "est.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
            } else if let was = Self.struck(time: time, scheduled: scheduled) {
                Text(Format.clock(was, tz ?? .current, units.clock))
                    .scaledFont(13)
                    .strikethrough(true, color: Theme.secondary)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel(Text(ui: "scheduled \(Format.clock(was, tz ?? .current, units.clock))"))
            }
        }
        .scaledFont(17)
        .monospacedDigit()
        .lineLimit(1)
    }
}

// MARK: - Row

/// A followed flight in My Flights (R1): the countdown column, then the airline logo, flight number and
/// date, the route by city, the two codes with their local times (the arrival's "+1" when it lands on a
/// later local date; a moved time in the status colour beside the struck scheduled one), a progress bar
/// while in the air, and the status line in words and colour ("Departed 16m late · lands 05:28"). A
/// hairline closes it under the text.
public struct MyFlightRow: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var now: Date
    var estimated: Bool
    @Environment(\.units) private var units

    /// - Parameter estimated: no connection, so the arrival is the app's own estimate: it reads "est." and
    ///   the status line says so.
    public init(flight: Flight, origin: Airport?, destination: Airport?, airline: Airline?, now: Date = .now,
                estimated: Bool = false) {
        self.flight = flight; self.origin = origin; self.destination = destination
        self.airline = airline; self.now = now; self.estimated = estimated
    }

    /// The row's status: `FlightStatusSummary`, with " est." after an estimated landing time offline.
    static func status(_ f: Flight, now: Date, origin: Airport?, destination: Airport?, clock: TimeStyle,
                       estimated: Bool) -> FlightStatusSummary {
        var s = FlightStatusSummary.make(for: f, now: now, origin: origin, destination: destination, clock: clock)
        if estimated, s.progress != nil, s.text.contains(" \u{00B7} lands ") { s.text += " est." }
        return s
    }

    /// The colour of a shown time: grey once canceled, the status colour when it moved later than scheduled,
    /// primary otherwise.
    static func timeTone(_ f: Flight, time: Date?, scheduled: Date?, status: FlightStatusSummary) -> Color? {
        if f.status == .canceled { return Theme.secondary }
        guard let time, let scheduled, time.timeIntervalSince(scheduled) >= 60 else { return nil }
        return status.tone
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
        let status = Self.status(flight, now: now, origin: origin, destination: destination, clock: units.clock,
                                 estimated: estimated)
        let out = DetailFacts.bestOut(flight), arr = DetailFacts.bestIn(flight)
        FlightRowChrome(
            airline: airline, code: code, ident: Format.ident(flight.ident), day: Self.day(flight, origin: origin),
            from: origin?.city ?? flight.originCode, to: destination?.city ?? flight.destinationCode,
            line: [count.value, count.unit].filter { !$0.isEmpty }.joined(separator: " "),
            lineColor: count.value.isEmpty ? unitColor : Theme.primary,
            accessibilityText: accessibilityText(count, status: status)
        ) {
            countdown(count)
        } ends: {
            FlightRowEnd(icon: "arrow.up.right", code: flight.originCode, time: out, tz: origin?.timeZone,
                         marker: nil, scheduled: flight.scheduledOut,
                         tone: Self.timeTone(flight, time: out, scheduled: flight.scheduledOut, status: status))
            FlightRowEnd(icon: "arrow.down.right", code: flight.destinationCode, time: arr, tz: destination?.timeZone,
                         marker: Self.marker(flight, origin: origin, destination: destination),
                         scheduled: flight.scheduledIn,
                         tone: Self.timeTone(flight, time: arr, scheduled: flight.scheduledIn, status: status),
                         estimated: estimated && status.progress != nil)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let progress = status.progress {
                    FlightProgressBar(progress: progress, tone: status.tone)
                }
                StatusLine(status)
            }
            .scaledPadding(.top, 6)
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

    private func accessibilityText(_ c: (value: String, unit: String), status: FlightStatusSummary) -> String {
        var parts = [Format.ident(flight.ident),
                     ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode)]
        if let day = Self.day(flight, origin: origin) { parts.append(day) }
        parts.append(c.value.isEmpty ? c.unit.capitalized : "\(c.value) \(c.unit.lowercased())")
        parts.append(status.text.replacingOccurrences(of: " \u{00B7} ", with: ", "))
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
