import Foundation
@testable import FlightKit
import Testing

/// The Connection Assistant: the MCT table, pairing two followed flights, the verdict and what the card says,
/// the "Other flights" window, and the store that keeps it all live.
@Suite struct ConnectionTests {
    static let t0 = FlightJSON.parse("2026-11-03T12:00:00Z")!

    static func at(_ minutes: Int) -> Date { t0.addingTimeInterval(TimeInterval(minutes * 60)) }

    /// A flight from `o` to `d` leaving `out` and landing `in_` minutes after `t0`.
    static func flight(_ ident: String, _ o: String, _ d: String, out: Int, in in_: Int,
                       status: FlightStatus = .scheduled, id: UUID = UUID()) -> Flight {
        Flight(id: id, providerId: "\(ident)-\(out)", ident: ident, originIcao: o, originIata: String(o.dropFirst()),
               destinationIcao: d, destinationIata: String(d.dropFirst()), scheduledOut: at(out), scheduledIn: at(in_),
               status: status)
    }

    static let countries: [String: String] = [
        "KSFO": "US", "KORD": "US", "KJFK": "US", "KLAX": "US", "KATL": "US", "KMIA": "US", "TJSJ": "PR",
        "LFPG": "FR", "LEMD": "ES", "EGLL": "GB", "OMDB": "AE", "KXYZ": "US", "LFBO": "FR", "EDDM": "DE",
    ]
    static func country(_ icao: String) -> String? { countries[icao] }

    static func assess(_ a: Flight, _ b: Flight) -> ConnectionAssessment {
        ConnectionAssistant.assess(Connection(arriving: a, departing: b), country: country)
    }

    // MARK: Rules

    @Test func theTableHasFortyAirportsAndSaneFigures() {
        let r = ConnectionRules.bundled
        #expect(r.airports.count == 40)
        for (icao, p) in r.airports {
            #expect(icao.count == 4)
            for kind in ConnectionKind.allCases {
                #expect((25...180).contains(p.mct.minutes(kind)), "\(icao) \(kind)")
            }
        }
        #expect(r.profile("KSFO").mct.minutes(.internationalToDomestic) == 90)
        #expect(r.profile("ksfo").iata == "SFO")
        #expect(r.profile("KXYZ") == r.defaults)
        #expect(r.knows("EDDF") && !r.knows("LFBO"))
    }

    /// push-sender reads the backend copy: both must be the same file, byte for byte.
    @Test func theBackendReadsTheSameRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let backend = try Data(contentsOf: root.appending(path: "supabase/functions/_shared/connection_rules.json"))
        let app = try Data(contentsOf: root.appending(path: "Packages/FlightKit/Sources/FlightKit/Resources/Reference/connection_rules.json"))
        #expect(backend == app)
    }

    /// `alternate-flights` answers as its tests write them, read by the decoder the live service uses.
    @Test func decodesTheAlternatesContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "supabase/functions/alternate-flights/contract/alternates.json"))
        let answer = try SupabaseAlternateFlightsService.decodeAnswer(data)
        #expect(answer.origin == "KSFO" && answer.destination == "KORD")
        #expect(answer.after == FlightJSON.parse("2026-11-03T15:00:00Z"))
        #expect(!answer.stale)
        let flights = try SupabaseAlternateFlightsService.decode(data)
        #expect(flights.map(\.ident) == ["UA2306", "AA1781", "UA1958", "AS1314"])
        let ua = try #require(flights.first { $0.ident == "UA1958" })
        #expect(ua.operator == "UAL")
        #expect(ua.originIata == "SFO" && ua.destinationIata == "ORD")
        #expect(ua.scheduledOut == FlightJSON.parse("2026-11-03T20:00:00Z"))
        #expect(ua.status == .scheduled && ua.estimatedOut == nil)
        #expect(ua.aircraftType == "B772")
        #expect(SupabaseAlternateFlightsService.iso(FlightJSON.parse("2026-11-03T15:20:00Z")!) == "2026-11-03T15:20:00Z")
    }

    @Test func regions() {
        let r = ConnectionRules.bundled
        #expect(r.sameRegion("US", "us"))
        #expect(r.sameRegion("US", "PR"))
        #expect(r.sameRegion("FR", "ES"))
        #expect(!r.sameRegion("FR", "GB"))
        #expect(!r.sameRegion("US", "CA"))
    }

    // MARK: Pairing

    @Test func aFlightLandingWhereTheNextLeavesConnects() {
        let a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        let pairs = ConnectionPairing.pairs([b, a])
        #expect(pairs.count == 1)
        #expect(pairs.first?.arriving.id == a.id && pairs.first?.departing.id == b.id)
        #expect(pairs.first?.airport == "KSFO")
    }

    @Test func pairingNeedsTheSameAirportAndAGapUpTo24Hours() {
        let a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let elsewhere = Self.flight("UA1", "KJFK", "KORD", out: 780, in: 900)
        let tooLate = Self.flight("UA2", "KSFO", "KORD", out: 660 + 24 * 60 + 1, in: 660 + 25 * 60)
        let justInTime = Self.flight("UA3", "KSFO", "KORD", out: 660 + 24 * 60, in: 660 + 25 * 60)
        let before = Self.flight("UA4", "KSFO", "KORD", out: 600, in: 800)
        #expect(ConnectionPairing.pairs([a, elsewhere, tooLate, before]).isEmpty)
        #expect(ConnectionPairing.pairs([a, justInTime]).count == 1)
    }

    @Test func aReturnTripIsNotAConnection() {
        let out = Self.flight("UA10", "KSFO", "KLAX", out: 0, in: 90)
        let back = Self.flight("UA11", "KLAX", "KSFO", out: 600, in: 690)
        #expect(ConnectionPairing.pairs([out, back]).isEmpty)
    }

    @Test func aThreeLegTripGivesTwoConnectionsAndTheMiddleLegHasBoth() {
        let a = Self.flight("IB1", "LEMD", "LFPG", out: 0, in: 120)
        let b = Self.flight("AF84", "LFPG", "KSFO", out: 200, in: 860)
        let c = Self.flight("UA1958", "KSFO", "KORD", out: 980, in: 1235)
        #expect(ConnectionPairing.pairs([c, b, a]).map(\.arriving.ident) == ["IB1", "AF84"])
        let middle = ConnectionPairing.connections(for: b.id, in: [a, b, c])
        #expect(middle.map(\.departing.ident) == ["AF84", "UA1958"])
        #expect(ConnectionPairing.connections(for: a.id, in: [a, b, c]).count == 1)
    }

    @Test func theNearestOnwardFlightWinsAndEachFlightPairsOnce() {
        let a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let near = Self.flight("UA1", "KSFO", "KORD", out: 760, in: 1000)
        let far = Self.flight("UA2", "KSFO", "KJFK", out: 900, in: 1200)
        let pairs = ConnectionPairing.pairs([a, far, near])
        #expect(pairs.count == 1)
        #expect(pairs.first?.departing.ident == "UA1")
    }

    @Test func aDelayNeverSplitsAPair() {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let b = Self.flight("UA1958", "KSFO", "KORD", out: 720, in: 1000)
        a.estimatedIn = Self.at(800) // lands after UA 1958 is due out
        #expect(ConnectionPairing.pairs([a, b]).count == 1)
    }

    // MARK: Kinds, MCT and rules at the airport

    @Test func internationalToDomesticAtSFO() {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        a.terminalDestination = "I"; a.gateDestination = "G91"
        var b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        b.terminalOrigin = "3"; b.gateOrigin = "F3"
        let x = Self.assess(a, b)
        #expect(x.kind == .internationalToDomestic)
        #expect(x.mctMinutes == 90)
        #expect(x.knownAirport)
        #expect(x.layoverMinutes == 120)
        #expect(x.verdict == .comfortable)
        #expect(x.passport == .entry)
        #expect(x.security)
        #expect(x.terminalChange == true)
        #expect(x.steps.map(\.kind) == [.deplane, .immigration, .customsRecheck, .terminalTransfer(to: "3"),
                                        .security, .walkToGate(gate: "F3")])
        #expect(x.stepMinutes == 15 + 25 + 15 + 15 + 15 + 10)
    }

    @Test func domesticAtOneTerminalNeedsNothingButTheWalk() {
        var a = Self.flight("UA1", "KLAX", "KSFO", out: 0, in: 90)
        a.terminalDestination = "3"
        var b = Self.flight("UA2", "KSFO", "KORD", out: 150, in: 400)
        b.terminalOrigin = "Terminal 3"
        let x = Self.assess(a, b)
        #expect(x.kind == .domesticToDomestic)
        #expect(x.mctMinutes == 45)
        #expect(x.terminalChange == false)
        #expect(x.passport == nil)
        #expect(!x.security)
        #expect(x.steps.map(\.kind) == [.deplane, .walkToGate(gate: nil)])
    }

    @Test func jfkTerminalsAreNotConnectedAirside() {
        var a = Self.flight("B61", "KSFO", "KJFK", out: 0, in: 330)
        a.terminalDestination = "5"
        var b = Self.flight("DL2", "KJFK", "KATL", out: 420, in: 560)
        b.terminalOrigin = "4"
        let x = Self.assess(a, b)
        #expect(x.terminalChange == true)
        #expect(x.security)
    }

    @Test func unknownTerminalsSayUnknown() {
        let a = Self.flight("B61", "KSFO", "KJFK", out: 0, in: 330)
        let b = Self.flight("DL2", "KJFK", "KATL", out: 420, in: 560)
        #expect(Self.assess(a, b).terminalChange == nil)
    }

    @Test func schengenToNonSchengenAtCDGHasExitControl() {
        let a = Self.flight("AF1001", "LEMD", "LFPG", out: 0, in: 120)
        let b = Self.flight("AF84", "LFPG", "KSFO", out: 240, in: 900)
        let x = Self.assess(a, b)
        #expect(x.kind == .domesticToInternational)
        #expect(x.schengenAirport)
        #expect(x.mctMinutes == 90)
        #expect(x.passport == .exit)
        #expect(!x.security)
        #expect(ConnectionCopy.kind(x) == "Schengen to non-Schengen")
    }

    @Test func nonSchengenTransitAtCDGHasNoPassportCheckButSecurity() {
        let a = Self.flight("AF1081", "EGLL", "LFPG", out: 0, in: 70)
        let b = Self.flight("AF84", "LFPG", "KSFO", out: 240, in: 900)
        let x = Self.assess(a, b)
        #expect(x.kind == .internationalToInternational)
        #expect(x.passport == nil)
        #expect(x.security)
    }

    @Test func theUSHasNoAirsideTransit() {
        let a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let b = Self.flight("EK226", "KSFO", "OMDB", out: 840, in: 1800)
        let x = Self.assess(a, b)
        #expect(x.kind == .internationalToInternational)
        #expect(x.passport == .entry)
        #expect(x.steps.contains { $0.kind == .customsRecheck })
    }

    @Test func londonScreensEveryTransfer() {
        let a = Self.flight("BA1", "KJFK", "EGLL", out: 0, in: 420)
        let b = Self.flight("BA2", "EGLL", "OMDB", out: 540, in: 960)
        let x = Self.assess(a, b)
        #expect(x.passport == nil)
        #expect(x.security)
        #expect(x.mctMinutes == 60)
    }

    @Test func puertoRicoIsDomesticFromTheMainland() {
        let a = Self.flight("AA1", "TJSJ", "KMIA", out: 0, in: 150)
        let b = Self.flight("AA2", "KMIA", "KATL", out: 240, in: 360)
        #expect(Self.assess(a, b).kind == .domesticToDomestic)
    }

    @Test func anAirportOutsideTheTableUsesTheDefaults() {
        let a = Self.flight("AF1", "LFPG", "LFBO", out: 0, in: 80)
        let b = Self.flight("AF2", "LFBO", "LEMD", out: 200, in: 280)
        let x = Self.assess(a, b)
        #expect(!x.knownAirport)
        #expect(x.mctMinutes == ConnectionRules.bundled.defaults.mct.dd)
        #expect(ConnectionCopy.mctLabel(x) == "Typical minimum")
    }

    @Test func anUnknownCountryCountsAsInternational() {
        let a = Self.flight("ZZ1", "ZZZZ", "KSFO", out: 0, in: 120)
        let b = Self.flight("UA2", "KSFO", "KORD", out: 300, in: 500)
        #expect(Self.assess(a, b).kind == .internationalToDomestic)
    }

    // MARK: Verdicts

    @Test func verdictThresholds() {
        let v = { (layover: Int) in ConnectionAssistant.verdict(layover: layover, mct: 60, broken: nil) }
        #expect(v(120) == .comfortable)
        #expect(v(90) == .comfortable)
        #expect(v(89) == .tight)
        #expect(v(60) == .tight)
        #expect(v(59) == .atRisk)
        #expect(v(15) == .atRisk)
        #expect(v(14) == .missed)
        #expect(v(-30) == .missed)
        #expect(ConnectionAssistant.verdict(layover: 300, mct: 60, broken: .departingCanceled) == .missed)
        #expect(ConnectionVerdict.missed > .atRisk && ConnectionVerdict.atRisk > .tight)
    }

    @Test func theVerdictFollowsTheBestEstimates() {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        var b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        let c = Connection(arriving: a, departing: b)
        #expect(ConnectionAssistant.assess(c, country: Self.country).verdict == .comfortable) // 120 vs 90
        a.estimatedIn = Self.at(680)
        #expect(ConnectionAssistant.assess(c.updated(with: a), country: Self.country).verdict == .tight) // 100
        a.estimatedIn = Self.at(720)
        #expect(ConnectionAssistant.assess(c.updated(with: a), country: Self.country).verdict == .atRisk) // 60
        b.estimatedOut = Self.at(840)
        let later = c.updated(with: a).updated(with: b)
        #expect(ConnectionAssistant.assess(later, country: Self.country).layoverMinutes == 120)
        a.actualIn = Self.at(830)
        #expect(ConnectionAssistant.assess(later.updated(with: a), country: Self.country).verdict == .missed) // 10
    }

    @Test func aLandingWithoutAGateTimeAddsTaxiing() {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        a.actualOn = Self.at(650)
        #expect(ConnectionAssistant.bestArrival(a) == Self.at(655))
    }

    @Test func brokenConnectionsAreMissed() {
        let a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        let b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        var canceledA = a; canceledA.status = .canceled
        var canceledB = b; canceledB.status = .canceled
        var divertedA = a; divertedA.status = .diverted
        var leftB = b; leftB.actualOut = Self.at(700); leftB.status = .departed
        #expect(Self.assess(canceledA, b).broken == .arrivingCanceled)
        #expect(Self.assess(a, canceledB).broken == .departingCanceled)
        #expect(Self.assess(divertedA, b).broken == .arrivingDiverted)
        #expect(Self.assess(a, leftB).broken == .departed)
        #expect(Self.assess(a, leftB).verdict == .missed)
        var landedA = a; landedA.actualIn = Self.at(650); landedA.status = .arrived
        #expect(Self.assess(landedA, leftB).broken == nil)
    }

    // MARK: Copy

    @Test func cardCopy() {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        a.terminalDestination = "I"; a.gateDestination = "G91"
        var b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        b.terminalOrigin = "3"; b.gateOrigin = "F3"
        let c = Connection(arriving: a, departing: b)
        let x = ConnectionAssistant.assess(c, country: Self.country)
        #expect(ConnectionCopy.subtitle(c) == "AF 84 to UA 1958 at SFO")
        #expect(ConnectionCopy.verdict(.atRisk) == "At risk")
        #expect(ConnectionCopy.layover(x) == "2h")
        #expect(ConnectionCopy.caption(c, x) == "30m more than the 1h 30m this connection usually needs at SFO.")
        #expect(ConnectionCopy.kind(x) == "International to domestic")
        #expect(ConnectionCopy.mctLabel(x) == "Usual minimum")
        #expect(ConnectionCopy.terminalChange(x) == "I to 3")
        #expect(ConnectionCopy.passport(x) == "Likely, after landing")
        #expect(ConnectionCopy.security(x) == "Likely")
        #expect(ConnectionCopy.place(terminal: "I", gate: "G91") == "Terminal I, gate G91")
        #expect(ConnectionCopy.place(terminal: nil, gate: nil) == nil)
        #expect(x.steps.map(ConnectionCopy.step) == ["Leave the plane", "Passport control", "Customs and bag drop",
                                                     "Get to Terminal 3", "Security", "Walk to gate F3"])
        #expect(ConnectionCopy.stepsTotal(x) == "About 1h 35m from door to gate")

        var late = a; late.estimatedIn = Self.at(705) // 75 minutes on the ground
        let tight = ConnectionAssistant.assess(c.updated(with: late), country: Self.country)
        #expect(tight.verdict == .atRisk)
        #expect(ConnectionCopy.caption(c, tight)
                == "15m short of the 1h 30m this connection usually needs at SFO. Tell the crew you are connecting.")
        late.estimatedIn = Self.at(670)
        let t2 = ConnectionAssistant.assess(c.updated(with: late), country: Self.country)
        #expect(ConnectionCopy.caption(c, t2) == "Only 20m over the usual 1h 30m. Go straight to your gate.")
        late.estimatedIn = Self.at(775)
        let gone = ConnectionAssistant.assess(c.updated(with: late), country: Self.country)
        #expect(ConnectionCopy.caption(c, gone) == "AF 84 now reaches the gate after boarding closes for UA 1958.")
        late.estimatedIn = Self.at(800)
        #expect(ConnectionCopy.layover(ConnectionAssistant.assess(c.updated(with: late), country: Self.country)) == "-20m")
        var canceled = b; canceled.status = .canceled
        let off = ConnectionAssistant.assess(c.updated(with: canceled), country: Self.country)
        #expect(ConnectionCopy.caption(c, off) == "UA 1958 is canceled. The airline should rebook you.")
        #expect(ConnectionCopy.step(ConnectionStep(.terminalTransfer(to: "International"), minutes: 10))
                == "Get to the International terminal")
        #expect(ConnectionCopy.step(ConnectionStep(.walkToGate(gate: nil), minutes: 10)) == "Walk to your gate")
    }

    // MARK: Other flights

    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    @Test func aCanceledFlightAsksForItsRouteFromNow() throws {
        let f = Self.flight("DL2204", "KATL", "KAUS", out: 120, in: 240, status: .canceled)
        let r = try #require(AlternateRequest.make(flight: f, connections: [], now: Self.at(17), timeZone: { _ in .gmt }))
        #expect(r.origin == "KATL" && r.destination == "KAUS" && r.destinationCode == "AUS")
        #expect(r.after == Self.at(0)) // held to the half hour
        #expect(r.until == FlightJSON.parse("2026-11-04T00:00:00Z"))
        #expect(r.endsToday)
        #expect(r.excluding == "DL2204")
        #expect(ConnectionCopy.alternatesTitle(r) == "Other flights to AUS today")
        let fine = Self.flight("DL2205", "KATL", "KAUS", out: 120, in: 240)
        #expect(AlternateRequest.make(flight: fine, connections: [], now: Self.at(17), timeZone: { _ in .gmt }) == nil)
    }

    @Test func lateInTheDayTheWindowRunsTwelveHours() {
        let r = AlternateRequest(origin: "KSFO", destination: "KORD", destinationCode: "ORD",
                                 after: FlightJSON.parse("2026-11-03T21:10:00Z")!, timeZone: .gmt, excluding: "UA1")
        #expect(r.after == FlightJSON.parse("2026-11-03T21:00:00Z"))
        #expect(r.until == FlightJSON.parse("2026-11-04T09:00:00Z"))
        #expect(!r.endsToday)
        #expect(ConnectionCopy.alternatesTitle(r) == "Other flights to ORD in the next 12 hours")
    }

    @Test func aConnectionAtRiskAsksForTheOnwardRouteFromLandingPlusTheMCT() throws {
        var a = Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660)
        a.estimatedIn = Self.at(720)
        let b = Self.flight("UA1958", "KSFO", "KORD", out: 780, in: 1035)
        let c = Connection(arriving: a, departing: b)
        let x = ConnectionAssistant.assess(c, country: Self.country)
        #expect(x.verdict == .atRisk)
        for f in [a, b] {
            let r = try #require(AlternateRequest.make(flight: f, connections: [(c, x)], now: Self.at(100),
                                                       timeZone: { _ in Self.pacific }))
            #expect(r.origin == "KSFO" && r.destination == "KORD")
            #expect(r.after == Self.at(810)) // 720 + 90
            #expect(r.excluding == "UA1958")
        }
        // Comfortable: nothing to offer. A canceled first flight: its passengers never reach SFO.
        let fine = ConnectionAssistant.assess(Connection(arriving: Self.flight("AF84", "LFPG", "KSFO", out: 0, in: 660),
                                                         departing: b), country: Self.country)
        #expect(AlternateRequest.make(flight: b, connections: [(c, fine)], now: Self.at(100), timeZone: { _ in .gmt }) == nil)
        var canceled = a; canceled.status = .canceled
        let off = ConnectionAssistant.assess(c.updated(with: canceled), country: Self.country)
        #expect(AlternateRequest.make(flight: b, connections: [(c, off)], now: Self.at(100), timeZone: { _ in .gmt }) == nil)
    }

    @Test func theWindowFiltersAndSorts() {
        let r = AlternateRequest(origin: "KSFO", destination: "KORD", destinationCode: "ORD", after: Self.at(0),
                                 timeZone: .gmt, excluding: "UA1958")
        func alt(_ ident: String, _ out: Int, est: Int? = nil, status: FlightStatus = .scheduled) -> AlternateFlight {
            AlternateFlight(id: ident, ident: ident, originIata: "SFO", destinationIata: "ORD", scheduledOut: Self.at(out),
                            scheduledIn: Self.at(out + 250), estimatedOut: est.map(Self.at), status: status)
        }
        let list = r.filter([alt("AA2", 300), alt("UA1958", 100), alt("AS1", -10), alt("B65", 60, est: 400),
                             alt("DL3", 200), alt("UA9", 900), alt("WN1", 120, status: .canceled)])
        #expect(list.map(\.ident) == ["DL3", "AA2", "B65"])
    }

    @Test func alternateStatusCopy() {
        var f = AlternateFlight(id: "x", ident: "UA1", originIata: "SFO", destinationIata: "ORD",
                                scheduledOut: Self.at(0), scheduledIn: Self.at(240))
        #expect(ConnectionCopy.alternateStatus(f).text == "Scheduled")
        f.estimatedOut = Self.at(5)
        #expect(ConnectionCopy.alternateStatus(f).text == "On time")
        f.estimatedOut = Self.at(20)
        #expect(ConnectionCopy.alternateStatus(f).text == "20m late")
        f.status = .canceled
        #expect(ConnectionCopy.alternateStatus(f).text == "Canceled")
    }

    // MARK: Store

    @MainActor @Test func theStoreFindsTheConnectionAndMovesWithUpdates() async throws {
        let flights = FakeFlightService(now: PreviewData.now)
        let af84 = try #require(try await flights.followed().first { $0.ident == "AF84" })
        let landing = try #require(af84.scheduledIn)
        let onward = Flight(providerId: "UA1958-t", ident: "UA1958", originIcao: "KSFO", originIata: "SFO",
                            destinationIcao: "KORD", destinationIata: "ORD", scheduledOut: landing.addingTimeInterval(7200),
                            scheduledIn: landing.addingTimeInterval(7200 + 15300), terminalOrigin: "3")
        await flights.push(onward)
        try await flights.follow(onward.id, notify: true)

        let store = ConnectionStore(id: onward.id, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                    lookup: AirportDirectory.bundled().lookup)
        let run = Task { await store.run(flight: onward) }
        defer { run.cancel() }
        try await eventually { !store.connections.isEmpty }
        let c = try #require(store.connections.first)
        #expect(c.arriving.id == af84.id && c.departing.id == onward.id)
        // AF 84 is estimated 11 minutes late in the seed: 109 minutes against 90.
        #expect(store.assessment(c).verdict == .tight)
        #expect(store.alternateRequest(for: onward, now: PreviewData.now) == nil)

        var later = af84
        later.estimatedIn = landing.addingTimeInterval(80 * 60)
        // The store subscribes once it has its connections: push until the update lands.
        for _ in 0..<100 where store.connections.first?.arriving.estimatedIn != later.estimatedIn {
            await flights.push(later)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.connections.first?.arriving.estimatedIn == later.estimatedIn)
        let x = store.assessment(try #require(store.connections.first))
        #expect(x.verdict == .atRisk)
        let request = try #require(store.alternateRequest(for: onward, now: PreviewData.now))
        #expect(request.destination == "KORD")
    }

    @MainActor @Test func followingAnAlternateLooksItUpAndFollowsIt() async throws {
        let flights = FakeFlightService(now: PreviewData.now)
        let alternates = FakeAlternateFlightsService(flights: flights)
        let canceled = try #require(try await flights.followed().first { $0.status == .canceled })
        let store = ConnectionStore(id: canceled.id, flights: flights, alternates: alternates,
                                    lookup: AirportDirectory.bundled().lookup)
        let request = try #require(store.alternateRequest(for: canceled, now: PreviewData.now))
        await store.loadAlternates(request)
        #expect(store.alternatesLoaded)
        #expect(!store.alternates.isEmpty)
        #expect(store.alternates.allSatisfy { $0.scheduledOut >= request.after && $0.scheduledOut <= request.until })
        let pick = try #require(store.alternates.first)
        let followed = try #require(await store.follow(pick))
        #expect(followed.ident == pick.ident)
        #expect(try await flights.followed().contains { $0.id == followed.id })
        #expect(store.pending == nil && store.followError == nil)
    }

    @MainActor @Test func aFollowWithNoMatchingFlightSaysSo() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let store = ConnectionStore(id: UUID(), flights: flights)
        let ghost = AlternateFlight(id: "g", ident: "ZZ9999", originIata: "SFO", destinationIata: "ORD",
                                    scheduledOut: PreviewData.now, scheduledIn: PreviewData.now.addingTimeInterval(3600))
        #expect(await store.follow(ghost) == nil)
        #expect(store.followError == .notFound)
        #expect(ConnectionCopy.followFailed(.notFound) == "Could not find this flight to follow it. Try Search.")
    }

    @Test func matchPicksTheSameFlightNearestTheSchedule() {
        let alt = AlternateFlight(id: "a", ident: "UA 512", originIata: "SFO", destinationIata: "ORD",
                                  scheduledOut: Self.at(300), scheduledIn: Self.at(550))
        let right = Self.flight("UA512", "KSFO", "KORD", out: 305, in: 550)
        let yesterday = Self.flight("UA512", "KSFO", "KORD", out: 300 - 1440, in: 550 - 1440)
        let otherOrigin = Self.flight("UA512", "KORD", "KSFO", out: 300, in: 550)
        #expect(ConnectionStore.match(alt, in: [yesterday, otherOrigin, right])?.id == right.id)
        #expect(ConnectionStore.match(alt, in: [yesterday]) == nil)
    }

    @Test func theFakeScheduleIsStableAndOnTheRoute() {
        let a = FakeAlternateFlightsService.schedule(origin: "KSFO", destination: "KORD", after: Self.at(0),
                                                     originAirport: nil, destinationAirport: nil)
        let b = FakeAlternateFlightsService.schedule(origin: "KSFO", destination: "KORD", after: Self.at(0),
                                                     originAirport: nil, destinationAirport: nil)
        #expect(a == b)
        #expect(a.count == 4)
        #expect(a.allSatisfy { $0.scheduledOut > Self.at(0) && $0.scheduledIn > $0.scheduledOut })
        #expect(zip(a, a.dropFirst()).allSatisfy { $0.scheduledOut < $1.scheduledOut })
    }
}

/// Polls `condition` on the main actor for up to two seconds.
@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never became true")
}
