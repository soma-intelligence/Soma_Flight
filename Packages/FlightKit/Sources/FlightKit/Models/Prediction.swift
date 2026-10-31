import Foundation

/// How late a flight that has not left is likely to leave, before the airline moves its estimate. Made by
/// the Rust core (`predict.rs`) from what the flight sheet already loaded (`Predictions.delay`); the
/// backend runs the same rules for its "AF 84 likely 25 min late" push.
public struct DelayPrediction: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case lateInbound, originWeather, destinationWeather, congestion, history
    }

    public enum Confidence: Int, Sendable, Hashable, Comparable {
        case low, medium, high
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .low: "Low confidence"
            case .medium: "Medium confidence"
            case .high: "High confidence"
            }
        }
    }

    /// Rounded to 5 minutes, at least 15.
    public var minutes: Int
    public var reason: Reason
    public var confidence: Confidence
    /// "Late inbound aircraft", "Weather at SFO", "Airport congestion", "Often late".
    public var reasonTitle: String
    /// "Likely 25 min late: inbound aircraft running late".
    public var summary: String

    public init(minutes: Int, reason: Reason, confidence: Confidence, reasonTitle: String, summary: String) {
        self.minutes = minutes; self.reason = reason; self.confidence = confidence
        self.reasonTitle = reasonTitle; self.summary = summary
    }

    /// "Likely 25 min late".
    public var headline: String { "Likely \(minutes) min late" }

    /// What the summary says after its colon, as a sentence: "Inbound aircraft running late."
    public var cause: String {
        guard let r = summary.range(of: ": ") else { return reasonTitle + "." }
        let tail = summary[r.upperBound...]
        return tail.prefix(1).uppercased() + tail.dropFirst() + "."
    }
}

/// Which gate a flight is likely to leave from before one is assigned (the Rust core's `predict_gate`
/// over `GateHistory`): a gate, or failing that its concourse or terminal.
public struct GatePrediction: Sendable, Hashable {
    public enum Guess: Sendable, Hashable { case gate, concourse, terminal }

    public var guess: Guess
    public var gate: String?
    public var concourse: String?
    public var terminal: String?
    /// Days (or, from the airline, flights) that agree, and how many were counted.
    public var used: Int
    public var of: Int
    /// True when the guess comes from the airline's other flights at the airport.
    public var fromAirline: Bool
    /// "B22", "Concourse B", "Terminal 2".
    public var label: String
    /// "Used 6 of the last 7 days", "Where AF usually departs".
    public var detail: String

    public init(guess: Guess, gate: String? = nil, concourse: String? = nil, terminal: String? = nil, used: Int,
                of: Int, fromAirline: Bool = false, label: String, detail: String) {
        self.guess = guess; self.gate = gate; self.concourse = concourse; self.terminal = terminal
        self.used = used; self.of = of; self.fromAirline = fromAirline; self.label = label; self.detail = detail
    }

    /// "Likely gate B22", "Likely concourse B", "Likely terminal 2".
    public var headline: String {
        switch guess {
        case .gate: "Likely gate \(label)"
        case .concourse: "Likely concourse \(concourse ?? label)"
        case .terminal: "Likely terminal \(terminal ?? label)"
        }
    }

    /// The text of the gate badge: the gate ("B22"), or the concourse ("B gates"); nil for a terminal
    /// guess, which only Good to Know shows.
    public var badge: String? {
        switch guess {
        case .gate: gate ?? label
        case .concourse: concourse.map { "\($0) gates" }
        case .terminal: nil
        }
    }
}

/// The departure gates a flight number used lately at its origin, and its airline's gates there
/// (`gate_history`, filled from the gates the backend already stores).
public struct GateHistory: Sendable, Hashable, Decodable {
    public struct Day: Sendable, Hashable, Decodable {
        /// Local day at the origin, "YYYY-MM-DD".
        public var day: String
        public var gate: String
        public var terminal: String?
        public init(day: String, gate: String, terminal: String? = nil) {
            self.day = day; self.gate = gate; self.terminal = terminal
        }
    }

    public struct Count: Sendable, Hashable, Decodable {
        public var gate: String
        public var terminal: String?
        public var flights: Int
        public init(gate: String, terminal: String? = nil, flights: Int) {
            self.gate = gate; self.terminal = terminal; self.flights = flights
        }
    }

    /// Newest first.
    public var days: [Day]
    /// Busiest first.
    public var airline: [Count]

    public init(days: [Day] = [], airline: [Count] = []) { self.days = days; self.airline = airline }
}
