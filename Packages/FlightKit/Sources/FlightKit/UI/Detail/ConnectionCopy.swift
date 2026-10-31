import SwiftUI

/// The words of the Connection card and the "Other flights" card, in one place so tests read them.
/// Short, plain English; durations in the app's style ("1h 30m").
enum ConnectionCopy {
    static let title = "Connection"

    /// "AF 84 to UA 1958 at SFO".
    static func subtitle(_ c: Connection) -> String {
        "\(Format.ident(c.arriving.ident)) to \(Format.ident(c.departing.ident)) at \(c.departing.originCode)"
    }

    static func verdict(_ v: ConnectionVerdict) -> String {
        switch v {
        case .comfortable: "Comfortable"
        case .tight: "Tight"
        case .atRisk: "At risk"
        case .missed: "Missed"
        }
    }

    static func color(_ v: ConnectionVerdict) -> Color {
        switch v {
        case .comfortable: Theme.onTime
        case .tight: Theme.late
        case .atRisk, .missed: Theme.veryLate
        }
    }

    /// The big figure beside the verdict: "1h 49m", or "-25m" when the onward flight leaves first.
    static func layover(_ a: ConnectionAssessment) -> String {
        guard let m = a.layoverMinutes else { return "--" }
        return m < 0 ? "-\(Format.minutes(-m))" : Format.minutes(m)
    }

    /// The sentence under the verdict.
    static func caption(_ c: Connection, _ a: ConnectionAssessment) -> String {
        let first = Format.ident(c.arriving.ident), next = Format.ident(c.departing.ident)
        let hub = c.departing.originCode
        let mct = Format.minutes(a.mctMinutes)
        switch a.broken {
        case .arrivingCanceled: return "\(first) is canceled, so this connection is off."
        case .departingCanceled: return "\(next) is canceled. The airline should rebook you."
        case .arrivingDiverted: return "\(first) is not landing at \(hub). The airline should rebook you."
        case .departed: return "\(next) left the gate before \(first) reached \(hub)."
        case nil: break
        }
        let spare = a.spareMinutes ?? 0
        switch a.verdict {
        case .missed:
            return "\(first) now reaches the gate after boarding closes for \(next)."
        case .atRisk:
            return "\(Format.minutes(-spare)) short of the \(mct) this connection usually needs at \(hub). Tell the crew you are connecting."
        case .tight:
            return spare == 0
                ? "Exactly the \(mct) this connection usually needs. Go straight to your gate."
                : "Only \(Format.minutes(spare)) over the usual \(mct). Go straight to your gate."
        case .comfortable:
            return "\(Format.minutes(spare)) more than the \(mct) this connection usually needs at \(hub)."
        }
    }

    /// "International to domestic", or "Non-Schengen to Schengen" at a Schengen airport.
    static func kind(_ a: ConnectionAssessment) -> String {
        let (inside, outside) = a.schengenAirport ? ("Schengen", "non-Schengen") : ("domestic", "international")
        let from = a.kind.arrivesInternational ? outside : inside
        let to = a.kind.leavesInternational ? outside : inside
        let text = "\(from) to \(to)"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Usual minimum", or "Typical minimum" where the airport has no figures of its own.
    static func mctLabel(_ a: ConnectionAssessment) -> String { a.knownAirport ? "Usual minimum" : "Typical minimum" }

    /// "Terminal I, gate G91"; "Gate G91"; "Terminal 3"; nil when neither is known.
    static func place(terminal: String?, gate: String?) -> String? {
        switch (terminal, gate) {
        case let (t?, g?): "Terminal \(t), gate \(g)"
        case let (t?, nil): "Terminal \(t)"
        case let (nil, g?): "Gate \(g)"
        case (nil, nil): nil
        }
    }

    static func terminalChange(_ a: ConnectionAssessment) -> String {
        switch a.terminalChange {
        case true?: "\(a.arrivalTerminal ?? "") to \(a.departureTerminal ?? "")"
        case false?: "Same terminal"
        case nil: "Not known yet"
        }
    }

    static func passport(_ a: ConnectionAssessment) -> String {
        switch a.passport {
        case .entry: "Likely, after landing"
        case .exit: "Likely, before your gate"
        case nil: "Not expected"
        }
    }

    static func security(_ a: ConnectionAssessment) -> String { a.security ? "Likely" : "Not expected" }

    static func step(_ s: ConnectionStep) -> String {
        switch s.kind {
        case .deplane: "Leave the plane"
        case .immigration: "Passport control"
        case .customsRecheck: "Customs and bag drop"
        case .exitControl: "Exit passport control"
        case .terminalTransfer(let to):
            // "3" and "2E" are terminal numbers; "International" is a name.
            to.count <= 3 ? "Get to Terminal \(to)" : "Get to the \(to) terminal"
        case .security: "Security"
        case .walkToGate(let gate): gate.map { "Walk to gate \($0)" } ?? "Walk to your gate"
        }
    }

    static func stepIcon(_ s: ConnectionStep) -> String {
        switch s.kind {
        case .deplane: "airplane.arrival"
        case .immigration, .exitControl: "person.text.rectangle"
        case .customsRecheck: "suitcase.rolling"
        case .terminalTransfer: "tram"
        case .security: "shield.lefthalf.filled"
        case .walkToGate: "figure.walk"
        }
    }

    /// "About 1h 15m from door to gate".
    static func stepsTotal(_ a: ConnectionAssessment) -> String { "About \(Format.minutes(a.stepMinutes)) from door to gate" }

    // MARK: Other flights

    /// "Other flights to SFO today", or "in the next 12 hours" late in the day.
    static func alternatesTitle(_ r: AlternateRequest) -> String {
        r.endsToday ? "Other flights to \(r.destinationCode) today"
            : "Other flights to \(r.destinationCode) in the next 12 hours"
    }

    static let alternatesSubtitle = "Direct, any airline. Tap one to follow it."
    static let alternatesEmpty = "No other direct flight is scheduled in this window."
    static let alternatesFootnote = "From airline schedules. Seats are not guaranteed: check with the airline before you go."

    /// "On time", "20m late", "Scheduled", "Canceled".
    static func alternateStatus(_ f: AlternateFlight) -> (text: String, color: Color) {
        switch f.status {
        case .canceled: return ("Canceled", Theme.veryLate)
        case .departed, .enRoute: return ("Departed", Theme.secondary)
        case .landed, .arrived: return ("Arrived", Theme.secondary)
        case .diverted: return ("Diverted", Theme.diverted)
        case .scheduled, .unknown: break
        }
        guard let est = f.estimatedOut else { return ("Scheduled", Theme.secondary) }
        let late = Int(est.timeIntervalSince(f.scheduledOut) / 60)
        if late >= 15 { return ("\(Format.minutes(late)) late", late >= 45 ? Theme.veryLate : Theme.late) }
        return ("On time", Theme.onTime)
    }

    static func followFailed(_ e: APIError) -> String {
        e == .notFound ? "Could not find this flight to follow it. Try Search." : e.message
    }
}
