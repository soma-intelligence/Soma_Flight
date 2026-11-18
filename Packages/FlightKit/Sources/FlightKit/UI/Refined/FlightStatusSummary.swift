import SwiftUI

/// The refined status line of a flight (R1, R3, R9): the words, the delay level that colours them, and the
/// trip's progress while the flight is in the air. Pure: the same flight, clock and airports always give the
/// same summary, so the rows, the hero card and the tests agree.
///
/// Named `FlightStatusSummary` because `FlightStatus` is already the provider's status enum.
///
/// The level comes from the delay the words name, through `DelayLevel.for(delay:status:)` (on time under
/// 15 min, late 15 to 44, very late 45 or more), so the colour and the words always speak of the same delay.
public struct FlightStatusSummary: Hashable, Sendable {
    /// "Departed 16m late · lands 05:28", "On time · gate B22", "Canceled", "Diverted to OAK". Built from
    /// format keys in the app's catalog ("Departed %@ late", "lands %@", "gate %@"), so it reads in the
    /// user's language; the pieces are joined with " · " (A1).
    public var text: String
    /// The delay level behind the colour.
    public var level: DelayLevel
    /// Fraction of the trip flown, 0...1, while departed or en route; nil otherwise.
    public var progress: Double?
    /// The text ends with the landing time ("· lands 05:28"), so a caller may mark it estimated without
    /// searching the (localized) words.
    public var showsLandingTime: Bool

    public init(text: String, level: DelayLevel, progress: Double? = nil, showsLandingTime: Bool = false) {
        self.text = text; self.level = level; self.progress = progress; self.showsLandingTime = showsLandingTime
    }

    /// The colour of the dot and the progress bar. Canceled keeps the home row's red label
    /// (`Theme.veryLate`); every other level is its `DelayLevel.color`.
    public var tone: Color { Self.tone(for: level) }

    /// The colour of the words: the same hue as `tone`, darkened in light mode to reach 4.5:1 (A3).
    public var textTone: Color { Self.textTone(for: level) }

    /// The status line's colour for `level`: red for canceled, the delay colour otherwise.
    public static func tone(for level: DelayLevel) -> Color {
        level == .canceled ? Theme.veryLate : level.color
    }

    /// `tone(for:)` as a text colour (`DelayLevel.textColor`, `Theme.veryLateText` for canceled).
    public static func textTone(for level: DelayLevel) -> Color {
        level == .canceled ? Theme.veryLateText : level.textColor
    }

    /// The separator between the pieces of a status line.
    static let separator = " \u{00B7} "

    private static func words(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .main)
    }

    private static func joined(_ pieces: String?...) -> String {
        pieces.compactMap { $0 }.joined(separator: separator)
    }

    /// The summary of `flight` at `now`.
    /// - Parameters:
    ///   - origin: the departure airport, for the local departure time.
    ///   - destination: where the flight actually goes (the diversion airport once diverted), for the local
    ///     arrival time and "Diverted to OAK".
    ///   - clock: the user's clock style (`Units.clock`).
    public static func make(for flight: Flight, now: Date, origin: Airport? = nil, destination: Airport? = nil,
                            clock: TimeStyle = .h24) -> FlightStatusSummary {
        switch flight.status {
        case .canceled:
            return .init(text: words("Canceled"), level: .canceled)

        case .diverted:
            guard let d = destination, d.id != flight.destinationIcao else {
                return .init(text: words("Diverted"), level: .diverted)
            }
            let code = d.iata ?? d.id
            return .init(text: words("Diverted to \(code)"), level: .diverted)

        case .landed, .arrived:
            guard let delay = flight.arrivalDelay else { return .init(text: words("Landed"), level: .onTime) }
            let m = Format.minutes(delay)
            let text: String
            if m >= 1 {
                let span = Format.minutes(m)
                text = words("Landed \(span) late")
            } else if m <= -1 {
                let span = Format.minutes(-m)
                text = words("Landed \(span) early")
            } else {
                text = words("Landed on time")
            }
            return .init(text: text, level: DelayLevel.for(delay: delay, status: flight.status))

        case .departed, .enRoute:
            let lands = DetailFacts.bestIn(flight).map { date -> String in
                let time = Format.clock(date, destination?.timeZone ?? .current, clock)
                return words("lands \(time)")
            }
            let lead: String, named: Duration?
            if let dep = flight.departureDelay, Format.minutes(dep) >= 1 {
                let span = Format.minutes(Format.minutes(dep))
                lead = words("Departed \(span) late"); named = dep
            } else if let arr = flight.arrivalDelay, Format.minutes(arr) >= 1 {
                let span = Format.minutes(Format.minutes(arr))
                lead = words("\(span) late"); named = arr
            } else {
                lead = words("On time"); named = nil
            }
            return .init(text: joined(lead, lands), level: DelayLevel.for(delay: named, status: flight.status),
                         progress: flight.progress(at: now), showsLandingTime: lands != nil)

        case .scheduled, .unknown:
            let gate = flight.gateOrigin.flatMap { g -> String? in g.isEmpty ? nil : words("gate \(g)") }
            guard let dep = flight.departureDelay else {
                // Only the schedule is known: say so rather than promise "On time".
                return .init(text: joined(words("Scheduled"), gate), level: .onTime)
            }
            let m = Format.minutes(dep)
            guard m >= 1 else { return .init(text: joined(words("On time"), gate), level: .onTime) }
            let departs = DetailFacts.bestOut(flight).map { date -> String in
                let time = Format.clock(date, origin?.timeZone ?? .current, clock)
                return words("departs \(time)")
            }
            let span = Format.minutes(m)
            return .init(text: joined(words("\(span) late"), departs, gate),
                         level: DelayLevel.for(delay: dep, status: flight.status))
        }
    }
}
