import Foundation
import Testing
@testable import FlightKit

/// The flight sheet's "At a glance" block: the boarding estimate, the placeholders, the predicted gate and
/// the on time or late line.
@Suite struct AtAGlanceTests {
    static let out = Date(timeIntervalSince1970: 1_800_000_000)
    static let tz = TimeZone.gmt
    static let narrow = AircraftType(id: "A320", family: .a320, manufacturer: "Airbus", name: "A320")
    static let wide = AircraftType(id: "B77W", family: .b777, manufacturer: "Boeing", name: "777-300ER")

    static func flight(status: FlightStatus = .scheduled, scheduledOut: Date? = out, estimatedOut: Date? = nil,
                       estimatedIn: Date? = nil, actualOut: Date? = nil, actualIn: Date? = nil,
                       gate: String? = nil, terminal: String? = nil, arrivalGate: String? = nil,
                       arrivalTerminal: String? = nil, belt: String? = nil) -> Flight {
        Flight(providerId: "p", ident: "AF84", originIcao: "KSFO", originIata: "SFO", destinationIcao: "LFPG",
               destinationIata: "CDG", scheduledOut: scheduledOut,
               scheduledIn: scheduledOut?.addingTimeInterval(11 * 3600), estimatedOut: estimatedOut,
               estimatedIn: estimatedIn, actualOut: actualOut, actualIn: actualIn, gateOrigin: gate,
               gateDestination: arrivalGate, terminalOrigin: terminal, terminalDestination: arrivalTerminal,
               baggageBelt: belt, status: status)
    }

    static let gateGuess = GatePrediction(guess: .gate, gate: "B22", concourse: "B", terminal: "2", used: 6, of: 7,
                                          label: "B22", detail: "Used 6 of the last 7 days")

    func boarding(_ f: Flight, pass: BoardingPass? = nil, aircraft: AircraftType? = nil) -> GlanceFacts.Cell {
        GlanceFacts.boarding(f, pass: pass, aircraft: aircraft, tz: Self.tz, clock: .h24)
    }

    // MARK: Boarding

    @Test func boardingLeadFollowsAircraftSize() {
        #expect(GlanceFacts.boardingLead(aircraft: Self.wide) == 40 * 60)
        #expect(GlanceFacts.boardingLead(aircraft: Self.narrow) == 30 * 60)
        #expect(GlanceFacts.boardingLead(aircraft: nil) == 30 * 60)
    }

    @Test func boardingEstimateUsesTheAirlineEstimateFirst() {
        let late = Self.out.addingTimeInterval(25 * 60)
        #expect(GlanceFacts.boardingEstimate(Self.flight(), aircraft: Self.wide) == Self.out.addingTimeInterval(-40 * 60))
        #expect(GlanceFacts.boardingEstimate(Self.flight(estimatedOut: late), aircraft: Self.narrow)
            == late.addingTimeInterval(-30 * 60))
        #expect(GlanceFacts.boardingEstimate(Self.flight(scheduledOut: nil), aircraft: Self.narrow) == nil)
    }

    @Test func boardingCellIsEstimatedWithoutAPass() {
        // 1_800_000_000 is 08:00 UTC; a wide-body boards at 07:20.
        let cell = boarding(Self.flight(), aircraft: Self.wide)
        #expect(cell == .init(label: "Boarding", value: "07:20", caption: "Estimated", kind: .estimated))
    }

    @Test func boardingCellPrefersThePass() {
        let pass = BoardingPass(source: .scan, carrier: "AF", flightNumber: "84", origin: "SFO", destination: "CDG",
                                boardingTime: Self.out.addingTimeInterval(-45 * 60))
        #expect(boarding(Self.flight(), pass: pass, aircraft: Self.wide)
            == .init(label: "Boarding", value: "07:15", caption: "On your pass", kind: .known))
        let printed = BoardingPass(source: .scan, carrier: "AF", flightNumber: "84", origin: "SFO", destination: "CDG",
                                   boardingText: "07:10")
        #expect(boarding(Self.flight(), pass: printed).value == "07:10")
    }

    @Test func boardingCellClosesOnceTheFlightLeft() {
        let left = Self.out.addingTimeInterval(5 * 60)
        #expect(boarding(Self.flight(status: .enRoute, actualOut: left))
            == .init(label: "Boarding", value: "Closed", caption: "Left at 08:05", kind: .known))
        #expect(boarding(Self.flight(scheduledOut: nil)).value == GlanceFacts.notPosted)
    }

    // MARK: Gates and belt

    @Test func departureGateKnownThenPredictedThenPlaceholder() {
        #expect(GlanceFacts.departureGate(Self.flight(gate: "A4", terminal: "1"), predicted: Self.gateGuess)
            == .init(label: "Departure gate", value: "A4", caption: "Terminal 1", kind: .known))
        #expect(GlanceFacts.departureGate(Self.flight(), predicted: Self.gateGuess)
            == .init(label: "Departure gate", value: "B22", caption: "Predicted · Terminal 2", kind: .predicted))
        #expect(GlanceFacts.departureGate(Self.flight(), predicted: nil)
            == .init(label: "Departure gate", value: "Gate soon", caption: nil, kind: .placeholder))
        #expect(GlanceFacts.departureGate(Self.flight(terminal: "3"), predicted: nil).caption == "Terminal 3")
    }

    @Test func departureGateConcourseAndTerminalGuesses() {
        let concourse = GatePrediction(guess: .concourse, concourse: "B", used: 5, of: 7, label: "Concourse B",
                                       detail: "Used 5 of the last 7 days")
        #expect(GlanceFacts.departureGate(Self.flight(), predicted: concourse).value == "B gates")
        let terminal = GatePrediction(guess: .terminal, terminal: "2", used: 5, of: 7, label: "Terminal 2",
                                      detail: "Used 5 of the last 7 days")
        #expect(GlanceFacts.departureGate(Self.flight(), predicted: terminal)
            == .init(label: "Departure gate", value: "Gate soon", caption: "Likely terminal 2", kind: .placeholder))
    }

    @Test func departureGateAfterLeavingWithoutOne() {
        let cell = GlanceFacts.departureGate(Self.flight(status: .enRoute), predicted: Self.gateGuess)
        #expect(cell.value == "Not posted" && cell.kind == .placeholder)
    }

    @Test func arrivalGateAndBelt() {
        #expect(GlanceFacts.arrivalGate(Self.flight(arrivalGate: "G91", arrivalTerminal: "I"))
            == .init(label: "Arrival gate", value: "G91", caption: "Terminal I", kind: .known))
        #expect(GlanceFacts.arrivalGate(Self.flight(arrivalTerminal: "2"))
            == .init(label: "Arrival gate", value: "Gate soon", caption: "Terminal 2", kind: .placeholder))
        #expect(GlanceFacts.arrivalGate(Self.flight(status: .arrived)).value == "Not posted")
        #expect(GlanceFacts.belt(Self.flight(belt: "12")).value == "12")
        #expect(GlanceFacts.belt(Self.flight()).value == "After landing")
        #expect(GlanceFacts.belt(Self.flight(status: .landed)).value == "Belt soon")
    }

    @Test func noCellIsEverBlank() {
        for status in [FlightStatus.scheduled, .unknown, .departed, .enRoute, .landed, .arrived] {
            let f = Self.flight(status: status, scheduledOut: nil)
            let cells = [GlanceFacts.departureGate(f, predicted: nil), boarding(f), GlanceFacts.arrivalGate(f),
                         GlanceFacts.belt(f)]
            #expect(cells.allSatisfy { !$0.value.isEmpty }, "\(status)")
        }
    }

    // MARK: Outlook

    @Test func outlookBeforeDeparture() {
        #expect(GlanceFacts.outlook(Self.flight(), prediction: nil)
            == .init(title: "On time so far", text: "No sign of a delay yet", tone: .good))
        let p = DelayPrediction(minutes: 25, reason: .lateInbound, confidence: .high, reasonTitle: "Late inbound aircraft",
                                summary: "Likely 25 min late: inbound aircraft running late")
        #expect(GlanceFacts.outlook(Self.flight(), prediction: p)
            == .init(title: "Likely 25 min late",
                     text: "Predicted. Inbound aircraft running late. High confidence.", tone: .late))
        // The airline's own estimate wins over the prediction.
        let moved = Self.flight(estimatedOut: Self.out.addingTimeInterval(40 * 60))
        #expect(GlanceFacts.outlook(moved, prediction: p)
            == .init(title: "Leaving 40m late", text: "Airline estimate", tone: .veryLate))
    }

    @Test func outlookInTheAirAndLanded() {
        let sIn = Self.out.addingTimeInterval(11 * 3600)
        #expect(GlanceFacts.outlook(Self.flight(status: .enRoute, estimatedIn: sIn.addingTimeInterval(-8 * 60)),
                                    prediction: nil)?.title == "Landing 8m early")
        #expect(GlanceFacts.outlook(Self.flight(status: .arrived, actualIn: sIn.addingTimeInterval(72 * 60)),
                                    prediction: nil)?.title == "Arrived 1h 12m late")
        #expect(GlanceFacts.outlook(Self.flight(status: .canceled), prediction: nil) == nil)
        #expect(!GlanceFacts.isShown(Self.flight(status: .diverted)))
    }
}
