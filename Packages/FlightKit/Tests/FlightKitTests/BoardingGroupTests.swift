import Foundation
@testable import FlightKit
import Testing

/// When the traveller's boarding group is called: the group read from the pass, the boarding start from the
/// pass or the usual lead, the groups called evenly until 15 minutes before departure.
@Suite struct BoardingGroupTests {
    static let departs = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00Z
    static let narrow = AircraftType(id: "B739", family: .b737, manufacturer: "Boeing", name: "Boeing 737-900")
    static let wide = AircraftType(id: "B77W", family: .b777, manufacturer: "Boeing", name: "Boeing 777-300ER")

    static func flight(_ op: String = "UAL", status: FlightStatus = .scheduled, out: Date? = departs,
                       estimated: Date? = nil, actualOut: Date? = nil) -> Flight {
        Flight(providerId: "p", ident: "\(op)1", operator: op, originIcao: "KSFO", destinationIcao: "KAUS",
               scheduledOut: out, estimatedOut: estimated, actualOut: actualOut, status: status)
    }

    static func pass(group: String? = nil, zone: String? = nil, boarding: Date? = nil, text: String? = nil,
                     carrier: String = "UA") -> BoardingPass {
        BoardingPass(source: .scan, carrier: carrier, flightNumber: "1", origin: "SFO", destination: "AUS",
                     group: group, zone: zone, boardingTime: boarding, boardingText: text)
    }

    static func minutesBefore(_ d: Date?) -> Int? { d.map { Int(departs.timeIntervalSince($0) / 60) } }

    // MARK: Reading the group

    @Test func groupIsReadFromThePassInItsUsualForms() {
        #expect(BoardingGroup.read(group: "5", zone: nil) == BoardingGroup(word: .group, name: "5", position: 5))
        #expect(BoardingGroup.read(group: "GROUP 05", zone: nil)?.title == "Group 5")
        #expect(BoardingGroup.read(group: nil, zone: "Zone 3")?.title == "Zone 3")
        #expect(BoardingGroup.read(group: nil, zone: "2")?.title == "Zone 2")
        #expect(BoardingGroup.read(group: "B", zone: nil) == BoardingGroup(word: .group, name: "B", position: 2))
        #expect(BoardingGroup.read(group: "Group c", zone: nil)?.position == 3)
        // Southwest style: the letter is the group, the number the place in its line.
        #expect(BoardingGroup.read(group: "A15", zone: nil)
                == BoardingGroup(word: .group, name: "A", position: 1, place: 15))
        #expect(BoardingGroup.read(group: "Group B32", zone: nil)?.title == "Group B")
        #expect(BoardingGroup.read(group: "GROUP 5", zone: nil)?.place == nil)
        #expect(BoardingGroup.read(group: "Priority", zone: nil) == nil)
        #expect(BoardingGroup.read(group: "", zone: " ") == nil)
        #expect(BoardingGroup.read(group: nil, zone: nil) == nil)
    }

    @Test func groupCountComesFromTheTableElseTheDefault() {
        #expect(BoardingGroupTiming.groups(airline: "UAL", atLeast: 3) == 6)
        #expect(BoardingGroupTiming.groups(airline: "AAL", atLeast: 3) == 9)
        #expect(BoardingGroupTiming.groups(airline: "AFR", atLeast: 2) == BoardingGroupTiming.defaultGroups)
        #expect(BoardingGroupTiming.groups(airline: "AFR", atLeast: 8) == 8)
        #expect(BoardingGroupTiming.groups(airline: nil, atLeast: 1) == BoardingGroupTiming.defaultGroups)
    }

    // MARK: Timing

    @Test func groupFromThePassWithNoBoardingTimeUsesTheUsualLead() throws {
        let now = Self.departs.addingTimeInterval(-3 * 3600)
        let e = try #require(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(group: "3"),
                                                          aircraft: Self.narrow, originTimeZone: .gmt, now: now))
        // Boarding 30 min before, pre-boarding to 25, six United groups until 15 min before: 2 min apart.
        #expect(Self.minutesBefore(e.boardingStarts) == 30)
        #expect(Self.minutesBefore(e.calledAt) == 21)
        #expect(!e.fromPass)
        #expect(e.phase == .beforeBoarding)
        #expect(BoardingGroupFacts.title(e, tz: .gmt, clock: .h24) == "Group 3, about 07:39")
        #expect(BoardingGroupFacts.caption(e, tz: .gmt, clock: .h24) == "Approximate. Boarding usually starts about 07:30.")
    }

    @Test func firstAndLastGroupsSpanTheBoardingWindow() throws {
        let now = Self.departs.addingTimeInterval(-3 * 3600)
        let first = try #require(BoardingGroupTiming.estimate(Self.flight("AAL"), pass: Self.pass(group: "1", carrier: "AA"),
                                                              aircraft: Self.wide, originTimeZone: .gmt, now: now))
        let last = try #require(BoardingGroupTiming.estimate(Self.flight("AAL"), pass: Self.pass(group: "9", carrier: "AA"),
                                                             aircraft: Self.wide, originTimeZone: .gmt, now: now))
        #expect(Self.minutesBefore(first.calledAt) == 35)
        #expect(Self.minutesBefore(last.calledAt) == 15)
    }

    @Test func boardingTimeOnThePassWins() throws {
        let boarding = Self.departs.addingTimeInterval(-50 * 60)
        let e = try #require(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(group: "1", boarding: boarding),
                                                          aircraft: Self.narrow, originTimeZone: .gmt,
                                                          now: Self.departs.addingTimeInterval(-2 * 3600)))
        #expect(e.fromPass)
        #expect(Self.minutesBefore(e.boardingStarts) == 50)
        #expect(Self.minutesBefore(e.calledAt) == 45)
        #expect(BoardingGroupFacts.caption(e, tz: .gmt, clock: .h24) == "Approximate. Boarding starts at 07:10 on your pass.")
    }

    @Test func aPassThatPrintsOnlyAClockTimeIsPlacedBeforeDeparture() throws {
        let e = try #require(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(group: "2", text: "07:15"),
                                                          aircraft: Self.narrow, originTimeZone: .gmt,
                                                          now: Self.departs.addingTimeInterval(-2 * 3600)))
        #expect(e.fromPass)
        #expect(Self.minutesBefore(e.boardingStarts) == 45)
    }

    @Test func aPostedDelayMovesTheGroupToo() throws {
        let late = Self.departs.addingTimeInterval(3600)
        let e = try #require(BoardingGroupTiming.estimate(Self.flight(estimated: late), pass: Self.pass(group: "1"),
                                                          aircraft: Self.narrow, originTimeZone: .gmt, now: Self.departs))
        #expect(e.boardingStarts == late.addingTimeInterval(-30 * 60))
    }

    @Test func noGroupOnThePassShowsNothing() {
        let now = Self.departs.addingTimeInterval(-3600)
        #expect(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(), aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: now) == nil)
        #expect(BoardingGroupTiming.estimate(Self.flight(), pass: nil, aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: now) == nil)
    }

    @Test func boardingAlreadyStartedSaysSo() throws {
        // Boarding opened 07:30; at 07:33 group 5 of 6 (07:43) is still to come.
        let at = Self.departs.addingTimeInterval(-27 * 60)
        let e = try #require(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(group: "5"), aircraft: Self.narrow,
                                                          originTimeZone: .gmt, now: at))
        #expect(e.phase == .boarding)
        #expect(BoardingGroupFacts.caption(e, tz: .gmt, clock: .h24) == "Approximate. Boarding has started, your group comes later.")
        let later = try #require(BoardingGroupTiming.estimate(Self.flight(), pass: Self.pass(group: "1"), aircraft: Self.narrow,
                                                              originTimeZone: .gmt, now: at.addingTimeInterval(3 * 60)))
        #expect(later.phase == .called)
    }

    @Test func pastDepartureOrGoneShowsNothing() {
        let pass = Self.pass(group: "3")
        #expect(BoardingGroupTiming.estimate(Self.flight(), pass: pass, aircraft: Self.narrow, originTimeZone: .gmt,
                                             now: Self.departs.addingTimeInterval(60)) == nil)
        let early = Self.departs.addingTimeInterval(-3600)
        #expect(BoardingGroupTiming.estimate(Self.flight(status: .enRoute), pass: pass, aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: early) == nil)
        #expect(BoardingGroupTiming.estimate(Self.flight(actualOut: early), pass: pass, aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: early) == nil)
        #expect(BoardingGroupTiming.estimate(Self.flight(status: .canceled), pass: pass, aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: early) == nil)
        #expect(BoardingGroupTiming.estimate(Self.flight(out: nil), pass: pass, aircraft: Self.narrow,
                                             originTimeZone: .gmt, now: early) == nil)
    }

    // MARK: Demo

    @Test func theDemoShowsAGroupOnUA1527() throws {
        let now = FakeSeed.reference
        let flight = try #require(FakeSeed.flights("followed", shift: 0).first { $0.id == FakeBoardingPass.ua1527FlightId })
        let pass = FakeBoardingPass.ua1527(now: now)
        let e = try #require(BoardingGroupTiming.estimate(flight, pass: pass,
                                                          aircraft: ReferenceData.bundled().type("B739"),
                                                          originTimeZone: TimeZone(identifier: "America/Los_Angeles"), now: now))
        #expect(e.group.title == "Group 3")
        #expect(e.groups == 6)
    }
}
