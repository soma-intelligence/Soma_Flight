import SwiftUI

// MARK: - Wording

/// The words of the flight sheet's "At a glance" block. No SwiftUI here, so the tests read the exact text.
///
/// Every cell always holds a value: a known fact, a guess marked as one ("Predicted", "Estimated"), or a
/// quiet placeholder ("Gate soon", "After landing"). Nothing is left blank.
enum GlanceFacts {
    /// How sure a cell's value is: drawn in full for `known`, `predicted` and `estimated` (with the caption
    /// saying which), grey for a `placeholder`.
    enum Kind: Equatable, Sendable { case known, predicted, estimated, placeholder }

    struct Cell: Equatable, Sendable {
        var label: String
        var value: String
        var caption: String?
        var kind: Kind
    }

    enum Tone: Equatable, Sendable { case good, late, veryLate, neutral }

    /// The block's top line: on time or late, and on what it rests.
    struct Outlook: Equatable, Sendable {
        var title: String
        var text: String
        var tone: Tone
    }

    static let gateSoon = "Gate soon"
    static let notPosted = "Not posted"
    static let afterLanding = "After landing"
    static let beltSoon = "Belt soon"

    /// The block shows for every flight but a canceled or diverted one, whose notice says what matters.
    static func isShown(_ f: Flight) -> Bool { f.status != .canceled && f.status != .diverted }

    /// True once the plane left the departure gate.
    static func hasLeft(_ f: Flight) -> Bool {
        f.actualOut != nil || [.departed, .enRoute, .landed, .arrived].contains(f.status)
    }

    /// True once the plane is down at the arrival airport.
    static func hasLanded(_ f: Flight) -> Bool {
        f.actualIn != nil || f.actualOn != nil || f.status == .landed || f.status == .arrived
    }

    // MARK: Boarding

    /// Boarding starts this long before departure: 40 minutes on a wide-body, 30 on anything else or when
    /// the aircraft is not known yet. The same figures as the "Leave by" breakdown (`LeaveTimePlanner`), so
    /// both say the same time.
    static func boardingLead(aircraft: AircraftType?) -> TimeInterval {
        aircraft?.family.isWidebody == true ? LeaveTimePlanner.boardingLeadWideBody : LeaveTimePlanner.boardingLeadNarrowBody
    }

    /// The estimated start of boarding: the airline's departure estimate (boarding moves with a posted
    /// delay), else the schedule, less `boardingLead`. nil without either time.
    static func boardingEstimate(_ f: Flight, aircraft: AircraftType?) -> Date? {
        (f.estimatedOut ?? f.scheduledOut).map { $0.addingTimeInterval(-boardingLead(aircraft: aircraft)) }
    }

    /// Boarding: "Closed" once the plane left, the time on the boarding pass when there is one, else the
    /// estimate marked "Estimated", else "Not posted".
    static func boarding(_ f: Flight, pass: BoardingPass?, aircraft: AircraftType?, tz: TimeZone,
                         clock: TimeStyle) -> Cell {
        let label = "Boarding"
        if hasLeft(f) {
            return Cell(label: label, value: "Closed",
                        caption: f.actualOut.map { "Left at \(Format.clock($0, tz, clock))" }, kind: .known)
        }
        if let t = pass?.boardingTime {
            return Cell(label: label, value: Format.clock(t, tz, clock), caption: "On your pass", kind: .known)
        }
        if let text = pass?.boardingText, !text.isEmpty {
            return Cell(label: label, value: text, caption: "On your pass", kind: .known)
        }
        guard let t = boardingEstimate(f, aircraft: aircraft) else {
            return Cell(label: label, value: notPosted, caption: nil, kind: .placeholder)
        }
        return Cell(label: label, value: Format.clock(t, tz, clock), caption: "Estimated", kind: .estimated)
    }

    // MARK: Gates and belt

    private static func terminal(_ t: String?) -> String? { t.map { "Terminal \($0)" } }

    /// The departure gate: the airline's, else the likely one from the gate history marked "Predicted",
    /// else "Gate soon" (or "Not posted" once the plane left without one), with the terminal when known.
    static func departureGate(_ f: Flight, predicted: GatePrediction?) -> Cell {
        let label = "Departure gate"
        if let gate = f.gateOrigin {
            return Cell(label: label, value: gate, caption: terminal(f.terminalOrigin), kind: .known)
        }
        if hasLeft(f) {
            return Cell(label: label, value: notPosted, caption: terminal(f.terminalOrigin), kind: .placeholder)
        }
        if let p = predicted {
            let where_ = terminal(f.terminalOrigin ?? p.terminal)
            if let badge = p.badge {
                return Cell(label: label, value: badge, caption: (["Predicted"] + [where_].compactMap { $0 })
                                .joined(separator: " · "), kind: .predicted)
            }
            if let t = f.terminalOrigin ?? p.terminal {
                return Cell(label: label, value: gateSoon,
                            caption: f.terminalOrigin == nil ? "Likely terminal \(t)" : "Terminal \(t)",
                            kind: .placeholder)
            }
        }
        return Cell(label: label, value: gateSoon, caption: terminal(f.terminalOrigin), kind: .placeholder)
    }

    /// The arrival gate: the airline's, else "Gate soon" (or "Not posted" once landed without one).
    static func arrivalGate(_ f: Flight) -> Cell {
        let label = "Arrival gate"
        if let gate = f.gateDestination {
            return Cell(label: label, value: gate, caption: terminal(f.terminalDestination), kind: .known)
        }
        return Cell(label: label, value: hasLanded(f) ? notPosted : gateSoon,
                    caption: terminal(f.terminalDestination), kind: .placeholder)
    }

    /// How long after the arrival a belt can still be posted.
    static let beltWindow: TimeInterval = 2 * 3600

    /// The baggage belt: the airline's, else "After landing" while in the air or before, "Belt soon" once
    /// down, and "Not posted" once the arrival is more than `beltWindow` old (a Passport flight of last
    /// spring has no belt coming).
    static func belt(_ f: Flight, now: Date = .now) -> Cell {
        let label = "Baggage belt"
        if let belt = f.baggageBelt { return Cell(label: label, value: belt, caption: nil, kind: .known) }
        guard hasLanded(f) else { return Cell(label: label, value: afterLanding, caption: nil, kind: .placeholder) }
        let arrived = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn
        let stale = arrived.map { now.timeIntervalSince($0) > beltWindow } ?? false
        return Cell(label: label, value: stale ? notPosted : beltSoon, caption: nil, kind: .placeholder)
    }

    // MARK: Outlook

    /// "12m late", "5m early".
    private static func off(_ m: Int) -> String {
        m >= 1 ? "\(DetailFacts.span(minutes: m)) late" : "\(DetailFacts.span(minutes: -m)) early"
    }

    /// The top line. Landed: how the arrival went. In the air: the landing against its schedule. Before
    /// departure: the airline's moved estimate first, else the prediction (`DelayPrediction`), else
    /// "On time so far". nil for a canceled or diverted flight.
    static func outlook(_ f: Flight, prediction: DelayPrediction?) -> Outlook? {
        switch f.status {
        case .canceled, .diverted:
            return nil
        case .landed, .arrived:
            guard let m = DetailFacts.offsetMinutes(scheduled: f.scheduledIn, estimated: f.estimatedIn,
                                                    actual: f.actualIn ?? f.actualOn) else {
                return Outlook(title: "Landed", text: "Arrival time not posted", tone: .neutral)
            }
            if m == 0 { return Outlook(title: "Arrived on time", text: "Against the schedule", tone: .good) }
            return Outlook(title: "Arrived \(off(m))", text: "Against the schedule", tone: m >= 1 ? .veryLate : .good)
        case .departed, .enRoute:
            guard let m = DetailFacts.offsetMinutes(scheduled: f.scheduledIn, estimated: f.estimatedIn,
                                                    actual: nil) else {
                return Outlook(title: "In the air", text: "Landing time not posted", tone: .neutral)
            }
            if m == 0 { return Outlook(title: "Landing on time", text: "Airline estimate", tone: .good) }
            return Outlook(title: "Landing \(off(m))", text: "Airline estimate", tone: m >= 1 ? .veryLate : .good)
        case .scheduled, .unknown:
            if let m = DetailFacts.offsetMinutes(scheduled: f.scheduledOut, estimated: f.estimatedOut, actual: nil),
               m != 0 {
                return Outlook(title: "Leaving \(off(m))", text: "Airline estimate", tone: m >= 1 ? .veryLate : .good)
            }
            if let p = prediction {
                return Outlook(title: p.headline, text: "Predicted. \(p.cause) \(p.confidence.title).",
                               tone: p.confidence == .low ? .neutral : .late)
            }
            return Outlook(title: "On time so far", text: "No sign of a delay yet", tone: .good)
        }
    }
}

// MARK: - Block

/// "At a glance", under the countdown: on time or late, then the departure gate, boarding, the arrival gate
/// and the baggage belt in one card. Hidden for a canceled or diverted flight (`GlanceFacts.isShown`).
struct AtAGlanceCard: View {
    var flight: Flight
    var origin: Airport?
    var aircraft: AircraftType?
    var pass: BoardingPass?
    var prediction: DelayPrediction?
    var predictedGate: GatePrediction?
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if GlanceFacts.isShown(flight) {
            let tz = origin?.timeZone ?? .current
            let cells = [GlanceFacts.departureGate(flight, predicted: predictedGate),
                         GlanceFacts.boarding(flight, pass: pass, aircraft: aircraft, tz: tz, clock: units.clock),
                         GlanceFacts.arrivalGate(flight),
                         GlanceFacts.belt(flight)]
            DetailCard {
                if let o = GlanceFacts.outlook(flight, prediction: prediction) {
                    outlook(o)
                    Hairline().scaledPadding(.vertical, 14)
                }
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { ForEach(cells, id: \.label) { cell($0) } }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) { cell(cells[0]); cell(cells[1]) }
                        HStack(alignment: .top, spacing: 16) { cell(cells[2]); cell(cells[3]) }
                    }
                }
            }
            .id("glance")
        }
    }

    private func tint(_ tone: GlanceFacts.Tone) -> Color {
        switch tone {
        case .good: Theme.onTime
        case .late: Theme.late
        case .veryLate: Theme.veryLate
        case .neutral: Theme.primary
        }
    }

    private func outlook(_ o: GlanceFacts.Outlook) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint(o.tone)).frame(width: 9, height: 9)
                .scaledPadding(.top, 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: o.title).scaledFont(19, weight: .semibold)
                    .foregroundStyle(o.tone == .neutral ? Theme.primary : tint(o.tone))
                Text(ui: o.text).scaledFont(14).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func cell(_ c: GlanceFacts.Cell) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: UIText.localized(c.label).uppercased()).scaledFont(12, weight: .medium).foregroundStyle(Theme.secondary)
            Text(ui: c.value)
                .scaledFont(20, weight: c.kind == .placeholder ? .medium : .bold)
                .monospacedDigit()
                .foregroundStyle(c.kind == .placeholder ? Theme.secondary : Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption = c.caption {
                Text(ui: caption).scaledFont(13, weight: c.kind == .known ? .regular : .medium)
                    .foregroundStyle(c.kind == .predicted || c.kind == .estimated ? Theme.late : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
