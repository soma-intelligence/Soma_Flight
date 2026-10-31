import Foundation
import Testing
@testable import FlightKit

/// FAA advisories: `faa-status` and `faa-notams` answers decoded (the backend's contract files), which
/// programs matter at which end, the words on Good to Know, the issues card and the Operations Report,
/// the fakes and the stores. The contract files are read from `supabase/functions/faa-status/contract/`
/// and `supabase/functions/faa-notams/contract/` (written by the backend's tests), so a change on the
/// backend side that the app cannot read fails here.
@MainActor @Suite struct FAATests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions")

    private func status(_ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appending(path: "faa-status/contract/\(name).json"))
    }

    private func notams(_ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appending(path: "faa-notams/contract/\(name).json"))
    }

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let ny = TimeZone(identifier: "America/New_York")!
    static let iso = ISO8601DateFormatter()
    static func date(_ s: String) -> Date { iso.date(from: s)! }
    /// The contract's clock: 31 October 2026, 20:10 UTC (13:10 in San Francisco).
    static let now = date("2026-10-31T20:10:00Z")

    // MARK: Decoding

    @Test func decodesTheGroundDelayProgram() throws {
        let p = try #require(try SupabaseFAAService.decodePrograms(try status("ground_delay")))
        #expect(p.airportIcao == "KSFO")
        #expect(p.iata == "SFO")
        #expect(!p.isStale)
        #expect(p.fetchedAt == Self.now)
        let gdp = try #require(p.programs.first)
        #expect(p.programs.count == 1)
        #expect(gdp.kind == .groundDelay)
        #expect(gdp.averageMinutes == 47)
        #expect(gdp.reason == "low clouds")
        #expect(gdp.reasonRaw == "WEATHER / LOW CEILINGS")
        #expect(gdp.startsAt == Self.date("2026-10-31T16:00:00Z"))
        #expect(gdp.endsAt == Self.date("2026-11-01T03:59:00Z"))
        #expect(gdp.advisoryURL?.host() == "www.fly.faa.gov")
        #expect(gdp.severity == .moderate)
    }

    @Test func decodesEveryOtherAnswer() throws {
        let gs = try #require(try SupabaseFAAService.decodePrograms(try status("ground_stop"))).programs
        #expect(gs.map(\.kind) == [.groundStop])
        #expect(gs[0].extensionChance == .medium)
        #expect(gs[0].severity == .major)
        let dep = try #require(try SupabaseFAAService.decodePrograms(try status("departure_delay"))).programs
        #expect(dep.map(\.kind) == [.departureDelay])
        #expect(dep[0].trend == .increasing)
        let arr = try #require(try SupabaseFAAService.decodePrograms(try status("arrival_delay"))).programs
        #expect(arr[0].trend == .decreasing)
        let closure = try #require(try SupabaseFAAService.decodePrograms(try status("closure"))).programs
        #expect(closure.map(\.kind) == [.closure])
        #expect(try #require(try SupabaseFAAService.decodePrograms(try status("calm"))).programs.isEmpty)
        #expect(try SupabaseFAAService.decodePrograms(try status("not_available")) == nil)
    }

    @Test func anUnknownProgramKindIsLeftOut() throws {
        var json = try JSONSerialization.jsonObject(with: try status("ground_delay")) as! [String: Any]
        var programs = json["programs"] as! [[String: Any]]
        var newer = programs[0]
        newer["kind"] = "airspace_flow_program"
        programs.append(newer)
        json["programs"] = programs
        let p = try #require(try SupabaseFAAService.decodePrograms(try JSONSerialization.data(withJSONObject: json)))
        #expect(p.programs.map(\.kind) == [.groundDelay])
    }

    @Test func decodesTheNotices() throws {
        let r = try #require(try SupabaseFAAService.decodeNotams(try notams("notams")))
        #expect(r.airportIcao == "KSFO")
        #expect(r.notams.map(\.number) == ["10/101", "10/104", "10/102", "10/103", "10/107", "10/105", "10/106"])
        let first = r.notams[0]
        #expect(first.kind == .runwayClosed)
        #expect(first.closesRunway)
        #expect(first.raw == "!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300")
        #expect(first.endsAt == Self.date("2026-10-31T13:00:00Z"))
        #expect(r.notams[3].endsEstimated)
        #expect(r.notams[6].endsAt == nil)
        // Closed to private flights only: not an airport closure for a passenger.
        #expect(!r.notams[6].closesAirport)
        #expect(try SupabaseFAAService.decodeNotams(try notams("not_configured")) == nil)
    }

    // MARK: Which end

    @Test func programsMatterAtTheRightEnd() {
        #expect(FAAFacts.matters(.departureDelay, at: .origin))
        #expect(!FAAFacts.matters(.departureDelay, at: .destination))
        #expect(FAAFacts.matters(.arrivalDelay, at: .destination))
        #expect(!FAAFacts.matters(.arrivalDelay, at: .origin))
        #expect(!FAAFacts.matters(.deicing, at: .destination))
        for k in [AirportProgram.Kind.closure, .groundStop, .groundDelay] {
            #expect(FAAFacts.matters(k, at: .origin) && FAAFacts.matters(k, at: .destination))
        }
        let p = AirportPrograms(airportIcao: "KBOS", iata: "BOS", fetchedAt: Self.now, programs: [
            AirportProgram(airport: "BOS", kind: .arrivalDelay, averageMinutes: 20),
            AirportProgram(airport: "BOS", kind: .groundStop, endsAt: Self.now.addingTimeInterval(-60)),
            AirportProgram(airport: "BOS", kind: .closure),
        ])
        #expect(FAAFacts.programs(p, at: .origin, now: Self.now).map(\.kind) == [.closure])
        #expect(FAAFacts.programs(p, at: .destination, now: Self.now).map(\.kind) == [.closure, .arrivalDelay])
        #expect(FAAFacts.programs(p, at: nil, now: Self.now).map(\.kind) == [.closure, .arrivalDelay])
        #expect(FAAFacts.worthLoading(.scheduled) && FAAFacts.worthLoading(.enRoute))
        #expect(!FAAFacts.worthLoading(.arrived) && !FAAFacts.worthLoading(.canceled))
    }

    // MARK: Words

    @Test func programRowsSayWhatTheFAAHolds() throws {
        let gdp = try #require(try SupabaseFAAService.decodePrograms(try status("ground_delay"))).programs[0]
        let r = FAAFacts.row(gdp, code: "SFO", timeZone: Self.la, now: Self.now)
        #expect(r.title == "Ground delay program at SFO")
        #expect(r.text == "Average 47m · Low clouds · Until 20:59")
        #expect(FAAFacts.row(gdp, code: "SFO", timeZone: Self.la, clock: .h12, now: Self.now).text
            == "Average 47m · Low clouds · Until 8:59 PM")

        let gs = try #require(try SupabaseFAAService.decodePrograms(try status("ground_stop"))).programs[0]
        let s = FAAFacts.row(gs, code: "EWR", timeZone: Self.ny, now: Self.now)
        #expect(s.title == "Ground stop at EWR")
        #expect(s.text == "Flights to EWR are held before take-off · Thunderstorms · Until 17:15 · May be extended")

        let dep = try #require(try SupabaseFAAService.decodePrograms(try status("departure_delay"))).programs[0]
        #expect(FAAFacts.row(dep, code: "LGA", timeZone: Self.ny, now: Self.now)
            == ("Departure delays at LGA", "Average 31m and rising · Heavy traffic"))
        let arr = try #require(try SupabaseFAAService.decodePrograms(try status("arrival_delay"))).programs[0]
        #expect(FAAFacts.row(arr, code: "BOS", timeZone: Self.ny, now: Self.now)
            == ("Arrival delays at BOS", "Average 22m and easing · Strong wind"))

        let closure = try #require(try SupabaseFAAService.decodePrograms(try status("closure"))).programs[0]
        let night = Self.date("2026-10-31T06:56:00Z")
        #expect(FAAFacts.row(closure, code: "SBY", timeZone: Self.ny, now: night)
            == ("SBY is closed", "Until 06:00 · Check with your airline"))
        // A closure that has not started yet says when it does.
        #expect(FAAFacts.row(closure, code: "SBY", timeZone: Self.ny, now: Self.date("2026-10-31T01:00:00Z")).text
            == "From 23:00 to 06:00 · Check with your airline")
        #expect(FAAFacts.row(AirportProgram(airport: "SBY", kind: .closure), code: "SBY", timeZone: Self.ny,
                             now: night).text == "Until further notice · Check with your airline")
        #expect(FAAFacts.row(AirportProgram(airport: "ORD", kind: .deicing), code: "ORD", timeZone: Self.ny,
                             now: night).title == "Deicing at ORD")
    }

    @Test func theNoticeLineCountsRunways() throws {
        let r = try #require(try SupabaseFAAService.decodeNotams(try notams("notams")))
        // 10/101 closes a whole runway; 10/102 only part of one; 10/104 is an ILS.
        let line = try #require(FAAFacts.notamLine(r, code: "SFO"))
        #expect(line.title == "Runway closure at SFO")
        #expect(line.text == "Runway 10L/28R closed · ILS glide slope for runway 28L out of service")

        var two = r
        two.notams.append(Notam(number: "10/120", kind: .runwayClosed, title: "Runway 01L/19R closed", relevance: 80,
                                raw: "RWY 01L/19R CLSD"))
        #expect(FAAFacts.notamLine(two, code: "SFO")?.title == "2 runway closures at SFO")

        let ilsOnly = NotamReport(airportIcao: "KSFO", iata: "SFO", fetchedAt: Self.now,
                                  notams: r.notams.filter { $0.kind == .ilsOut })
        #expect(FAAFacts.notamLine(ilsOnly, code: "SFO")?.title == "ILS out at SFO")
        let minor = NotamReport(airportIcao: "KSFO", iata: "SFO", fetchedAt: Self.now,
                                notams: r.notams.filter { $0.kind == .taxiwayClosed || $0.kind == .obstacleLight })
        #expect(FAAFacts.notamLine(minor, code: "SFO") == nil)
        #expect(FAAFacts.notamLine(nil, code: "SFO") == nil)
        let closed = NotamReport(airportIcao: "KSBY", iata: "SBY", fetchedAt: Self.now, notams: [
            Notam(number: "10/069", kind: .airportClosed, title: "Airport closed", relevance: 100,
                  raw: "!SBY 10/069 SBY AD AP CLSD 2610310300-2610311000"),
        ])
        #expect(FAAFacts.notamLine(closed, code: "SBY")?.title == "SBY closed by NOTAM")
    }

    @Test func noticeWindows() throws {
        let r = try #require(try SupabaseFAAService.decodeNotams(try notams("notams")))
        let at = Self.date("2026-10-31T08:00:00Z")
        #expect(FAAFacts.notamWindow(r.notams[0], timeZone: Self.la, now: at) == "Until 06:00")
        #expect(FAAFacts.notamWindow(r.notams[2], timeZone: Self.la, now: at) == "From 07:00 to 15:00")
        #expect(FAAFacts.notamWindow(r.notams[3], timeZone: Self.la, now: at) == "Until about 15:59")
        #expect(FAAFacts.notamWindow(r.notams[6], timeZone: Self.la, now: at) == "Until further notice")
        #expect(FAAFacts.notamSource(r, now: at.addingTimeInterval(600)) == "FAA NOTAM service • updated 10 min ago")
    }

    @Test func goodToKnowAndIssuesRows() throws {
        let p = try #require(try SupabaseFAAService.decodePrograms(try status("ground_delay")))
        let n = try #require(try SupabaseFAAService.decodeNotams(try notams("notams")))
        let rows = FAAFacts.rows(programs: p, notams: n, end: .destination, code: "SFO", timeZone: Self.la,
                                 clock: .h24, now: Self.now)
        #expect(rows.map(\.title) == ["Ground delay program at SFO", "Runway closure at SFO"])
        #expect(rows.map(\.severity) == [.moderate, .moderate])
        #expect(FAAFacts.issuesSeverity(stats: nil, rows: rows) == .moderate)
        #expect(FAAFacts.issuesSeverity(stats: nil, rows: []) == .normal)
        #expect(FAAFacts.issuesTitle(.moderate, programs: rows) == "Delays are building")
        let gs = try #require(try SupabaseFAAService.decodePrograms(try status("ground_stop")))
        let stop = FAAFacts.airportRows(programs: gs, notams: nil, code: "EWR", timeZone: Self.ny, clock: .h24,
                                        now: Self.now)
        #expect(FAAFacts.issuesSeverity(stats: nil, rows: stop) == .major)
        #expect(FAAFacts.issuesTitle(.major, programs: stop) == "Flights held by the FAA")
    }

    // MARK: Fakes, stores, environment

    @Test func fakesGiveABadAfternoon() async throws {
        let faa = FakeFAAService(now: PreviewData.now)
        #expect(try await faa.programs(airport: "SFO")?.programs.map(\.kind) == [.groundDelay])
        #expect(try await faa.programs(airport: "KEWR")?.programs.map(\.kind) == [.groundStop])
        #expect(try await faa.programs(airport: "DEN")?.programs == [])
        #expect(try await faa.programs(airport: "CDG") == nil)
        #expect(try await faa.notams(airport: "SFO")?.notams.first?.kind == .runwayClosed)
        await faa.setNextError(.providerUnavailable)
        await #expect(throws: APIError.self) { try await faa.programs(airport: "SFO") }
        await #expect(throws: APIError.self) { try await faa.programs(airport: "ZZZZ") }
    }

    @Test func storesLoadTheAdvisories() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let airports = FakeAirportService(now: PreviewData.now)
        let faa = FakeFAAService(now: PreviewData.now)
        // UA1527, SFO to AUS, not left yet: SFO's program at the origin, AUS's departure delays do not
        // matter at the destination, but its runway closure does.
        let ua = PreviewData.followed.first { $0.ident == "UA1527" }!
        let store = FlightDetailStore(id: ua.id, flights: flights, airports: airports, faa: faa)
        await store.load()
        await store.loadExtras(now: PreviewData.now)
        #expect(store.advisories.originPrograms?.programs.map(\.kind) == [.groundDelay])
        #expect(store.advisories.destinationNotams?.notams.count == 1)
        let rows = FAAFacts.rows(store, flight: store.flight!, clock: .h24, now: PreviewData.now)
        #expect(rows.origin.map(\.title) == ["Ground delay program at SFO", "Runway closure at SFO"])
        #expect(rows.destination.map(\.title) == ["Runway closure at AUS"])

        // Canceled: nothing asked, nothing shown.
        let canceled = PreviewData.followed.first { $0.status == .canceled }!
        let off = FlightDetailStore(id: canceled.id, flights: flights, airports: airports, faa: faa)
        await off.load()
        await off.loadExtras(now: PreviewData.now)
        #expect(off.advisories == FlightAdvisories())

        // A failure hides the rows only.
        await faa.setNextError(.providerUnavailable)
        let failed = FlightDetailStore(id: ua.id, flights: flights, airports: airports, faa: faa)
        await failed.load()
        await failed.loadExtras(now: PreviewData.now)
        #expect(failed.error == nil)

        let sfo = AirportStore(code: "KSFO", airports: airports, faa: faa)
        await sfo.load()
        #expect(sfo.programs?.programs.count == 1)
        #expect(sfo.notams?.notams.count == 6)
        #expect(sfo.error == nil)
        let plain = AirportStore(code: "KSFO", airports: airports)
        await plain.load()
        #expect(plain.programs == nil && plain.notams == nil)
    }

    @Test func environmentsWireTheService() async throws {
        let fake = try await AppEnvironment.fake(now: PreviewData.now)
        #expect(fake.faa is FakeFAAService)
        let store = fake.makeAirportStore(code: "KSFO")
        await store.load()
        #expect(store.programs != nil)
        #expect(store.notams != nil)
    }
}
