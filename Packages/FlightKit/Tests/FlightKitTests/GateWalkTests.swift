import Foundation
import Testing
@testable import FlightKit

/// The walk from security to the gate: reading gate names, the table's lookup order, the size defaults,
/// its words and how it folds into the computed leave time.
@Suite struct GateWalkTests {
    // MARK: Gate names

    @Test func gateNamesReadIntoConcourseAndNumber() {
        #expect(GateName.parse("B32") == GateName(concourse: "B", number: 32))
        #expect(GateName.parse("b 32") == GateName(concourse: "B", number: 32))
        #expect(GateName.parse("B-32") == GateName(concourse: "B", number: 32))
        #expect(GateName.parse("Gate B32") == GateName(concourse: "B", number: 32))
        #expect(GateName.parse("E10A") == GateName(concourse: "E", number: 10))
        #expect(GateName.parse("T5") == GateName(concourse: "T", number: 5))
        #expect(GateName.parse("52") == GateName(concourse: nil, number: 52))
        #expect(GateName.parse("52A") == GateName(concourse: nil, number: 52))
        #expect(GateName.parse("C") == GateName(concourse: "C", number: nil))
        #expect(GateName.parse("MA4") == GateName(concourse: "MA", number: 4))
    }

    @Test func oddGateNamesReadAsNothing() {
        for raw in [nil, "", "  ", "TBD", "Hardstand 4", "B32/33", "12345", "B32AB"] as [String?] {
            #expect(GateName.parse(raw) == nil, "\(raw ?? "nil")")
        }
    }

    @Test func terminalsNormalise() {
        #expect(GateWalkTable.normaliseTerminal("Terminal 1") == "1")
        #expect(GateWalkTable.normaliseTerminal("T1") == "1")
        #expect(GateWalkTable.normaliseTerminal("t4") == "4")
        #expect(GateWalkTable.normaliseTerminal("Terminal B") == "B")
        #expect(GateWalkTable.normaliseTerminal("TBIT") == "TBIT")
        #expect(GateWalkTable.normaliseTerminal(" ") == nil)
        #expect(GateWalkTable.normaliseTerminal(nil) == nil)
    }

    // MARK: The table

    @Test func theTableListsTheFortyBusiestUSAirportsOnce() {
        let codes = GateWalkTable.entries.map(\.airport)
        #expect(codes.count == 40)
        #expect(Set(codes).count == 40)
        for e in GateWalkTable.entries {
            #expect((2...25).contains(e.typical), "\(e.airport)")
            for a in e.areas { #expect((2...25).contains(a.minutes), "\(e.airport)") }
        }
    }

    @Test func theGatesConcourseGivesTheFigure() {
        let w = GateWalkTable.walk(airport: "ATL", icao: "KATL", terminal: "S", gate: "F3", size: .large)
        #expect(w == GateWalk(minutes: 19, basis: .concourse("F"), gate: "F3"))
        #expect(w.isForGate)
        #expect(GateWalkTable.walk(airport: "DEN", icao: nil, terminal: nil, gate: "A32", size: nil).minutes == 9)
    }

    @Test func theIcaoCodeFindsAUSAirportWithoutItsIata() {
        let w = GateWalkTable.walk(airport: nil, icao: "KSLC", terminal: nil, gate: "B12", size: nil)
        #expect(w.minutes == 15 && w.basis == .concourse("B"))
    }

    @Test func aConcourseInSeveralTerminalsUsesTheTerminalOrElseTheLongestWalk() {
        // JFK has a concourse B in terminal 4 (10m) and in terminal 8 (7m).
        #expect(GateWalkTable.walk(airport: "JFK", icao: nil, terminal: "8", gate: "B12", size: nil).minutes == 7)
        #expect(GateWalkTable.walk(airport: "JFK", icao: nil, terminal: "Terminal 4", gate: "B40", size: nil).minutes == 10)
        #expect(GateWalkTable.walk(airport: "JFK", icao: nil, terminal: nil, gate: "B40", size: nil).minutes == 10)
    }

    @Test func aNumberedGateFallsInARange() {
        let w = GateWalkTable.walk(airport: "LAX", icao: "KLAX", terminal: nil, gate: "210B", size: nil)
        #expect(w.minutes == 13 && w.basis == .gates(200...299))
        #expect(GateWalkTable.walk(airport: "DCA", icao: nil, terminal: nil, gate: "3", size: nil).minutes == 4)
    }

    @Test func withoutAGateTheTerminalGivesTheFigure() {
        let lax = GateWalkTable.walk(airport: "LAX", icao: nil, terminal: "TBIT", gate: nil, size: nil)
        #expect(lax == GateWalk(minutes: 8, basis: .terminal("TBIT")))
        #expect(!lax.isForGate)
        // A terminal with concourses but no figure of its own: the longest of them.
        #expect(GateWalkTable.walk(airport: "JFK", icao: nil, terminal: "4", gate: nil, size: nil).minutes == 10)
    }

    @Test func nothingKnownGivesTheAirportsTypicalWalk() {
        #expect(GateWalkTable.walk(airport: "SFO", icao: nil, terminal: nil, gate: nil, size: nil)
                == GateWalk(minutes: 7, basis: .airport))
        // An unknown concourse at a listed airport.
        #expect(GateWalkTable.walk(airport: "SFO", icao: nil, terminal: nil, gate: "Q9", size: nil)
                == GateWalk(minutes: 7, basis: .airport, gate: "Q9"))
        #expect(GateWalkTable.walk(airport: "AUS", icao: nil, terminal: nil, gate: "12", size: nil).minutes == 7)
    }

    @Test func airportsOutsideTheTableGoBySize() {
        #expect(GateWalkTable.walk(airport: "CDG", icao: "LFPG", terminal: "2E", gate: "K40", size: .large)
                == GateWalk(minutes: 10, basis: .size(.large), gate: "K40"))
        #expect(GateWalkTable.walk(airport: "BOD", icao: "LFBD", terminal: nil, gate: nil, size: .medium).minutes == 6)
        #expect(GateWalkTable.walk(airport: nil, icao: "LFXX", terminal: nil, gate: nil, size: .small).minutes == 3)
        #expect(GateWalkTable.walk(airport: nil, icao: "ZZZZ", terminal: nil, gate: nil, size: nil).basis == .size(.medium))
    }

    @Test func theBundledSizesReadOurAirportsTypes() {
        let sizes = AirportSizes.bundled
        #expect(sizes.size("LFPG") == .large)
        #expect(sizes.size("kjfk") == .large)
        #expect(sizes.size("NOPE") == .medium)
    }

    // MARK: Words

    @Test func theRowSaysTheWalkAndWhatItRestsOn() {
        let gate = GateWalk(minutes: 12, basis: .concourse("B"), gate: "B32")
        #expect(GateWalkFacts.title(gate) == "About 12m walk to gate B32")
        #expect(GateWalkFacts.basis(gate) == "From security to concourse B, a typical walk")
        let early = GateWalk(minutes: 7, basis: .airport)
        #expect(GateWalkFacts.title(early) == "About 7m walk to the gate")
        #expect(GateWalkFacts.basis(early) == "A typical walk at this airport. This sharpens once the gate is known")
        #expect(GateWalkFacts.basis(GateWalk(minutes: 10, basis: .size(.large))) == "A typical walk at a large airport")
        #expect(GateWalkFacts.basis(GateWalk(minutes: 13, basis: .gates(200...299), gate: "210"))
                == "From security to gates 200 to 299, a typical walk")
    }

    // MARK: Leave time

    @Test @MainActor func theWalkMovesAComputedLeaveTimeEarlier() throws {
        let walk = GateWalk(minutes: 12, basis: .concourse("K"), gate: "K40")
        let without = try #require(LeaveTimeTests.plan(ReminderTests.af84()))
        let with = try #require(LeaveTimePlanner.plan(for: ReminderTests.af84(), origin: ReminderTests.cdg,
                                                      destination: ReminderTests.sfo, aircraft: LeaveTimeTests.wide,
                                                      measure: LeaveTimeTests.measure(), precheck: false, walk: walk))
        #expect(without.leaveAt.timeIntervalSince(with.leaveAt) == 12 * 60)
        #expect(with.breakdown?.walk == walk)
        #expect(LeaveTimeFacts.summary(with).hasSuffix(" · 12m walk"))
        let lines = LeaveTimeFacts.lines(try #require(with.breakdown), departure: with.departure, international: true,
                                         tz: .gmt, clock: .h24)
        #expect(lines.map(\.title).contains("About 12m walk to gate K40"))
    }

    @Test @MainActor func theWalkNeverChangesTheFixedRule() throws {
        let walk = GateWalk(minutes: 12, basis: .airport)
        let a = try #require(LeaveTimeTests.plan(ReminderTests.af84(), measure: nil))
        let b = try #require(LeaveTimePlanner.plan(for: ReminderTests.af84(), origin: ReminderTests.cdg,
                                                   destination: ReminderTests.sfo, aircraft: LeaveTimeTests.wide,
                                                   measure: nil, precheck: false, walk: walk))
        #expect(a == b)
    }
}
