import Foundation
import Testing
@testable import FlightKit

/// The conditions summary (`faa-status` `conditions`): the backend's contract example decoded, how it reads in
/// the airport status, the rows and the report, and the fakes and the store. A non-US airport has no program
/// feed, so the summary is all it has.
@MainActor @Suite struct AirportAssessmentTests {
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

    static let paris = TimeZone(identifier: "Europe/Paris")!
    /// The contract's clock: 31 October 2026, 20:10 UTC.
    static let now = ISO8601DateFormatter().date(from: "2026-10-31T20:10:00Z")!

    private func decoded() throws -> AirportPrograms {
        try #require(try SupabaseFAAService.decodePrograms(try status("conditions_outside_us")))
    }

    // MARK: Decoding

    @Test func aNonUSAirportDecodesToConditionsWithoutAFeed() throws {
        let p = try decoded()
        #expect(p.airportIcao == "LFPG")
        #expect(!p.hasFeed)
        #expect(p.programs.isEmpty)
        let a = try #require(p.assessment)
        #expect(a.level == .major)
        #expect(a.summary == "Thunderstorms nearby in the forecast")
        #expect(a.reasons.map(\.source) == [.forecast, .notam, .forecast])
        #expect(a.reasons.map(\.level) == [.major, .minor, .minor])
        #expect(a.reasons[0].startsAt != nil && a.reasons[0].endsAt != nil)
        #expect(a.readMetar && a.readTaf && a.readNotams)
    }

    @Test func withoutConditionsAnOutsideUSAnswerIsStillNil() throws {
        #expect(try SupabaseFAAService.decodePrograms(try status("not_available")) == nil)
    }

    @Test func aUSAnswerWithoutConditionsHasAFeedAndNoAssessment() throws {
        let p = try #require(try SupabaseFAAService.decodePrograms(try status("ground_delay")))
        #expect(p.hasFeed)
        #expect(p.assessment == nil)
    }

    @Test func anUnknownSourceOrLevelIsLeftOut() throws {
        var json = try JSONSerialization.jsonObject(with: try status("conditions_outside_us")) as! [String: Any]
        var c = json["conditions"] as! [String: Any]
        var reasons = c["reasons"] as! [[String: Any]]
        var odd = reasons[0]; odd["source"] = "radar"
        var calm = reasons[0]; calm["level"] = "calm"
        reasons += [odd, calm]
        c["reasons"] = reasons
        json["conditions"] = c
        let p = try #require(try SupabaseFAAService.decodePrograms(try JSONSerialization.data(withJSONObject: json)))
        #expect(p.assessment?.reasons.count == 3)
    }

    // MARK: Status

    @Test func theSummaryDrivesTheStatusOutsideTheUS() throws {
        let a = try #require(try decoded().assessment)
        let s = AirportStatus.of(nil, assessment: a)
        #expect(s.level == .major)
        #expect(s.line == "Thunderstorms nearby in the forecast")
        #expect(AirportStatus.of(nil, assessment: AirportAssessment(level: .normal)) == .normal)
        #expect(AirportStatus.of(nil, assessment: nil) == .normal)
    }

    @Test func anFAAProgramStillWinsAtEqualLevel() {
        let program = AirportProgram(airport: "SFO", kind: .groundStop)
        let a = AirportAssessment(level: .major, summary: "Airport closed by notice")
        let s = AirportStatus.of(AirportOverview(icao: "KSFO", programs: [program]), assessment: a)
        #expect(s.line == "Ground stop")
    }

    // MARK: Rows and report

    @Test func theRowShowsTheForecastAheadInTheAirportsTimeAndNotTheNotices() throws {
        let p = try decoded()
        let rows = FAAFacts.airportRows(programs: p, notams: nil, code: "CDG", timeZone: Self.paris, clock: .h24,
                                        now: Self.now)
        let r = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(r.title == "Disruption likely at CDG")
        #expect(r.severity == .major)
        // The forecast reasons only: the runway notice is the NOTAM line's to say. 22:00 to 02:00 UTC is
        // 23:00 to 03:00 in Paris on 31 October (summer time ended on the 25th).
        #expect(r.text == "Thunderstorms nearby in the forecast, 23:00 to 03:00 · Strong winds in the forecast at times, 03:00 to 08:00")
    }

    @Test func theWeatherNowJoinsTheRowWhenTheCardHasNoWeatherLine() {
        let a = AirportAssessment(level: .minor, summary: "x", reasons: [
            .init(source: .metar, level: .minor, text: "Low clouds at the airport now", startsAt: Self.now),
        ])
        let p = AirportPrograms(airportIcao: "EGLL", iata: "LHR", fetchedAt: Self.now, programs: [], assessment: a,
                                hasFeed: false)
        #expect(FAAFacts.airportRows(programs: p, notams: nil, code: "LHR", timeZone: Self.paris, clock: .h24,
                                     now: Self.now).isEmpty)
        let r = FAAFacts.airportRows(programs: p, notams: nil, code: "LHR", timeZone: Self.paris, clock: .h24,
                                     now: Self.now, includeWeatherNow: true)
        #expect(r.first?.title == "Possible slowdowns at LHR")
        #expect(r.first?.severity == .moderate)
        #expect(r.first?.text == "Low clouds at the airport now")
    }

    @Test func aNormalReadAddsNoRow() {
        let p = AirportPrograms(airportIcao: "EGLL", iata: "LHR", fetchedAt: Self.now, programs: [],
                                assessment: AirportAssessment(level: .normal), hasFeed: false)
        #expect(FAAFacts.airportRows(programs: p, notams: nil, code: "LHR", timeZone: Self.paris, clock: .h24,
                                     now: Self.now, includeWeatherNow: true).isEmpty)
    }

    @Test func theSourceLineSaysItIsInferredAndWhatWasRead() {
        #expect(FAAFacts.assessmentSource(AirportAssessment(level: .minor, readNotams: false))
            == "Inferred from METAR, TAF with simple rules, not an official program")
        #expect(FAAFacts.assessmentSource(AirportAssessment(level: .minor, readMetar: false, readTaf: false,
                                                            readNotams: false))
            == "Inferred from nothing with simple rules, not an official program")
    }

    // MARK: Fakes and the store

    @Test func theFakeGivesLondonAnInferredBadAfternoon() async throws {
        let faa = FakeFAAService(now: PreviewData.now)
        let p = try #require(try await faa.programs(airport: "LHR"))
        #expect(!p.hasFeed && p.programs.isEmpty)
        #expect(p.assessment?.level == .major)
        // No other airport outside the US has one, and US airports have none from the fake.
        #expect(try await faa.programs(airport: "CDG") == nil)
        #expect(try await faa.programs(airport: "SFO")?.assessment == nil)
    }

    @Test func theStoreStatusReadsTheConditions() async {
        let now = PreviewData.now
        let store = AirportStore(code: "EGLL", airports: FakeAirportService(now: now), faa: FakeFAAService(now: now))
        await store.load()
        #expect(store.programs?.assessment != nil)
        #expect(store.status.level == .major)
    }
}
