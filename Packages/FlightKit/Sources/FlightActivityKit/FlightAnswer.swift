import Foundation

/// What Siri, Shortcuts and the Control Center say about a followed flight, from the snapshot the app keeps
/// in the App Group: no network, so it answers offline and never sends anything anywhere. Times are local to
/// their airport, in the user's clock style.
public enum FlightAnswer {
    /// Said when nothing is followed (or nobody is signed in).
    public static let nothingFollowed = "You're not following any flights. Open Soma Flight to add one."

    /// "UA 1527 to Austin departs at 18:25, 25m late, from terminal 3, gate F11." for the next flight.
    public static func nextFlight(_ snapshot: WidgetSnapshot, at date: Date, twelveHour: Bool) -> String {
        guard let next = snapshot.flights(at: date).first else { return nothingFollowed }
        return sentence(next, at: date, twelveHour: twelveHour)
    }

    /// One flight in a sentence: where it is and what changed.
    public static func sentence(_ flight: WidgetFlight, at date: Date, twelveHour: Bool) -> String {
        let d = FlightWidgetDisplay(flight, at: date, twelveHour: twelveHour)
        let to = flight.destination.name
        switch flight.status {
        case .canceled:
            return "\(d.ident) to \(to) is canceled."
        case .diverted:
            return "\(d.ident) to \(to) was diverted."
        case .landed, .arrived:
            return "\(d.ident) landed in \(to) at \(d.arrivalTime)" + place(nil, flight.gateDestination) + "."
        case .departed, .enRoute:
            return "\(d.ident) to \(to) is in the air and lands at \(d.arrivalTime)"
                + delay(flight.arrivalDelayMinutes) + place(flight.terminalDestination, flight.gateDestination) + "."
        case .scheduled, .unknown:
            return "\(d.ident) to \(to) departs at \(d.departureTime)"
                + delay(flight.departureDelayMinutes) + place(flight.terminalOrigin, flight.gateOrigin, from: true) + "."
        }
    }

    /// ", 25m late" or ", on time"; nothing while only the schedule is known.
    static func delay(_ minutes: Int?) -> String {
        FlightWidgetDisplay.offsetWord(minutes).map { ", " + $0.lowercased() } ?? ""
    }

    /// ", from terminal 3, gate F11"; nothing when neither is known.
    static func place(_ terminal: String?, _ gate: String?, from: Bool = false) -> String {
        var parts: [String] = []
        if let terminal, !terminal.isEmpty { parts.append("terminal \(terminal)") }
        if let gate, !gate.isEmpty { parts.append("gate \(gate)") }
        guard !parts.isEmpty else { return "" }
        return ", " + (from ? "from " : "at ") + parts.joined(separator: ", ")
    }
}
