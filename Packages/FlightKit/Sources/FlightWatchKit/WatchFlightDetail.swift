@_exported import FlightActivityKit
import Foundation

/// What the watch's flight screen shows for one flight at one moment: the big status, both ends with
/// their times, the facts that matter at the airport, the progress while in the air and the boarding
/// pass. The wording is the widgets' (`FlightWidgetDisplay`), so the watch, the widgets and the Live
/// Activity say the same thing.
public struct WatchFlightDetail: Sendable, Hashable, Identifiable {
    public var display: FlightWidgetDisplay
    public var extras: WatchFlightExtras?

    public init(_ display: FlightWidgetDisplay, extras: WatchFlightExtras? = nil) {
        self.display = display; self.extras = extras
    }

    public var id: UUID { display.flight.id }
    public var flight: WidgetFlight { display.flight }

    /// "AF 84".
    public var ident: String { display.ident }
    /// The big status: "On Time", "25m Late", "In the Air", "Landed", "Canceled".
    public var status: String { display.activity.statusText }
    /// The colour of the status: the delay level, as on the flight card.
    public var level: DelayLevel { display.level }

    /// "Departs in 5 hrs", "Arrives in 2h", "Departing", "Landed": the countdown in words, under the status.
    public var countdownLine: String {
        let c = display.countdown
        guard !c.value.isEmpty else { return c.unit.capitalized }
        if display.isAirborne { return "Arrives in \(c.value)" }
        return "Departs in \(c.value) \(c.unit.lowercased())"
    }

    // MARK: Ends

    /// One end of the flight as the screen draws it.
    public struct End: Sendable, Hashable {
        public var code: String
        public var city: String
        /// The best time, local to the airport.
        public var time: String
        /// The schedule, struck through beside the time, once the best time moved off it.
        public var scheduled: String?
        /// "+1" on an arrival a local day later.
        public var dayMark: String?
        public var tone: FlightWidgetDisplay.Tone
        /// "25m Late", "On Time"; nil while only the schedule is known.
        public var offset: String?
        public var gate: String?
        public var terminal: String?
    }

    public var departure: End {
        End(code: flight.origin.code, city: flight.origin.name, time: display.departureTime,
            scheduled: display.scheduledDeparture, dayMark: nil, tone: display.departureTone,
            offset: FlightWidgetDisplay.offsetWord(flight.departureDelayMinutes),
            gate: flight.gateOrigin, terminal: flight.terminalOrigin)
    }

    public var arrival: End {
        End(code: flight.destination.code, city: flight.destination.name, time: display.arrivalTime,
            scheduled: display.scheduledArrival, dayMark: display.arrivalDayMark, tone: display.arrivalTone,
            offset: FlightWidgetDisplay.offsetWord(flight.arrivalDelayMinutes),
            gate: flight.gateDestination, terminal: flight.terminalDestination)
    }

    // MARK: Facts

    /// A labelled value in the facts grid ("Gate" "K42").
    public struct Fact: Sendable, Hashable, Identifiable {
        public var label: String
        public var value: String
        /// The gate is drawn as the app's yellow badge.
        public var isGate: Bool
        public var id: String { label }
    }

    /// What the traveller looks for now: the departure gate and terminal and the seat before take-off;
    /// the arrival gate, terminal and baggage belt after. Only the known ones, in that order.
    public var facts: [Fact] {
        var out: [Fact] = []
        let end = display.isPastDeparture ? arrival : departure
        if let gate = end.gate { out.append(Fact(label: "Gate", value: gate, isGate: true)) }
        if let terminal = end.terminal { out.append(Fact(label: "Terminal", value: terminal, isGate: false)) }
        if display.isPastDeparture {
            if let belt = extras?.baggageBelt { out.append(Fact(label: "Belt", value: belt, isGate: false)) }
            if let seat = extras?.seat { out.append(Fact(label: "Seat", value: seat, isGate: false)) }
        } else {
            if let seat = extras?.seat { out.append(Fact(label: "Seat", value: seat, isGate: false)) }
            if let group = extras?.pass?.boardingGroup { out.append(Fact(label: "Group", value: group, isGate: false)) }
            if let belt = extras?.baggageBelt { out.append(Fact(label: "Belt", value: belt, isGate: false)) }
        }
        return out
    }

    // MARK: Progress and pass

    /// The share flown, shown only while in the air.
    public var progress: Double? { display.isAirborne ? display.progress : nil }

    /// "4h 10m left": the time to the gate arrival while in the air.
    public var timeLeft: String? {
        guard display.isAirborne, let end = flight.bestIn else { return nil }
        let m = Int(end.timeIntervalSince(display.date) / 60)
        return m >= 1 ? "\(FlightActivityDisplay.duration(minutes: m)) left" : nil
    }

    /// The boarding pass, until the flight is down: a landed flight no longer needs it.
    public var pass: WatchPass? {
        switch flight.status {
        case .landed, .arrived, .canceled: nil
        default: extras?.pass
        }
    }

    /// What VoiceOver reads for the header.
    public var spokenHeader: String {
        "\(ident), \(display.routeCities), \(status), \(countdownLine)"
    }
}
