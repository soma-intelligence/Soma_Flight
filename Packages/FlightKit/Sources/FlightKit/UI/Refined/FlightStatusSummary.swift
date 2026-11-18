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
    /// "Departed 16m late · lands 05:28", "On time · gate B22", "Canceled", "Diverted to OAK".
    public var text: String
    /// The delay level behind the colour.
    public var level: DelayLevel
    /// Fraction of the trip flown, 0...1, while departed or en route; nil otherwise.
    public var progress: Double?

    public init(text: String, level: DelayLevel, progress: Double? = nil) {
        self.text = text; self.level = level; self.progress = progress
    }

    /// The colour of the words, the dot and the progress bar. Canceled keeps the home row's red label
    /// (`Theme.veryLate`); every other level is its `DelayLevel.color`.
    public var tone: Color { Self.tone(for: level) }

    /// The status line's colour for `level`: red for canceled, the delay colour otherwise.
    public static func tone(for level: DelayLevel) -> Color {
        level == .canceled ? Theme.veryLate : level.color
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
            return .init(text: "Canceled", level: .canceled)

        case .diverted:
            guard let d = destination, d.id != flight.destinationIcao else {
                return .init(text: "Diverted", level: .diverted)
            }
            return .init(text: "Diverted to \(d.iata ?? d.id)", level: .diverted)

        case .landed, .arrived:
            guard let delay = flight.arrivalDelay else { return .init(text: "Landed", level: .onTime) }
            let m = Format.minutes(delay)
            let words = m >= 1 ? "Landed \(Format.minutes(m)) late"
                : m <= -1 ? "Landed \(Format.minutes(-m)) early" : "Landed on time"
            return .init(text: words, level: DelayLevel.for(delay: delay, status: flight.status))

        case .departed, .enRoute:
            let lands = DetailFacts.bestIn(flight).map {
                " · lands \(Format.clock($0, destination?.timeZone ?? .current, clock))"
            } ?? ""
            let lead: String, named: Duration?
            if let dep = flight.departureDelay, Format.minutes(dep) >= 1 {
                lead = "Departed \(Format.minutes(Format.minutes(dep))) late"; named = dep
            } else if let arr = flight.arrivalDelay, Format.minutes(arr) >= 1 {
                lead = "\(Format.minutes(Format.minutes(arr))) late"; named = arr
            } else {
                lead = "On time"; named = nil
            }
            return .init(text: lead + lands, level: DelayLevel.for(delay: named, status: flight.status),
                         progress: flight.progress(at: now))

        case .scheduled, .unknown:
            let gate = flight.gateOrigin.flatMap { $0.isEmpty ? nil : " · gate \($0)" } ?? ""
            guard let dep = flight.departureDelay else {
                // Only the schedule is known: say so rather than promise "On time".
                return .init(text: "Scheduled" + gate, level: .onTime)
            }
            let m = Format.minutes(dep)
            guard m >= 1 else { return .init(text: "On time" + gate, level: .onTime) }
            let departs = DetailFacts.bestOut(flight).map {
                " · departs \(Format.clock($0, origin?.timeZone ?? .current, clock))"
            } ?? ""
            return .init(text: "\(Format.minutes(m)) late" + departs + gate,
                         level: DelayLevel.for(delay: dep, status: flight.status))
        }
    }
}
