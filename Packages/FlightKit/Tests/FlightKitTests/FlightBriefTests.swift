import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// The language-model texts: the Info.plist switch, the facts each screen would send (and what must never
/// be in them), the contract with `flight-brief`, the fake service and the model that shows a text.
@MainActor @Suite struct FlightBriefTests {
    typealias R = ReminderTests
    static let now = R.date("2026-11-03T18:00:00Z")
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let functions = repo.appending(path: "supabase/functions/flight-brief")

    static func ids(_ facts: [BriefFact]?) -> [String] { (facts ?? []).map(\.id) }
    static func value(_ facts: [BriefFact]?, _ id: String) -> BriefValue? { facts?.first { $0.id == id }?.value }

    // MARK: Switch

    @Test func theSwitchIsOffUnlessYes() {
        for on in ["YES", "yes", "true", "1", " Yes "] as [Any] { #expect(SupabaseFlightBriefService.isEnabled(raw: on)) }
        #expect(SupabaseFlightBriefService.isEnabled(raw: true))
        #expect(SupabaseFlightBriefService.isEnabled(raw: NSNumber(value: 1)))
        for off in ["NO", "", "$(LLM_ENABLED)", "maybe"] as [Any] { #expect(!SupabaseFlightBriefService.isEnabled(raw: off)) }
        #expect(!SupabaseFlightBriefService.isEnabled(raw: nil))
        #expect(!SupabaseFlightBriefService.isEnabled(raw: false))
    }

    @Test func unavailableMakesNoCallAndShowsNothing() async throws {
        let s = UnavailableFlightBriefService()
        #expect(!s.isAvailable)
        let facts = [BriefFact("ident", .text("AF84")), BriefFact("gate", .text("K36"))]
        #expect(try await s.brief(.doorToDoor, subject: "x", facts: facts) == nil)
    }

    // MARK: Door to door

    static func computed() throws -> (Flight, LeaveTime, GateWalk) {
        let f = R.af84()
        let walk = GateWalk(minutes: 12, basis: .terminal("2E"), gate: "K36")
        let t = try #require(LeaveTimePlanner.plan(for: f, origin: R.cdg, destination: R.sfo,
                                                   aircraft: LeaveTimeTests.wide,
                                                   measure: LeaveTimeTests.measure(), precheck: false, walk: walk))
        return (f, t, walk)
    }

    @Test func doorToDoorFactsAreTheLeaveByInputs() throws {
        let (f, t, walk) = try Self.computed()
        let facts = try #require(BriefFacts.doorToDoor(flight: f, leave: t, walk: walk, tz: R.cdg.timeZone, now: Self.now))
        // 22:30 UTC is 23:30 in Paris; boarding 21:50 UTC is 22:50; leaving 20:10 UTC less the 12 m walk.
        #expect(Self.value(facts, "departure_local") == .text("23:30"))
        #expect(Self.value(facts, "boarding_local") == .text("22:50"))
        #expect(Self.value(facts, "leave_by_local") == .text(BriefFacts.clock(t.leaveAt, R.cdg.timeZone)))
        #expect(Self.value(facts, "drive_minutes") == .int(35))
        #expect(Self.value(facts, "bag_drop_minutes") == .int(45))
        #expect(Self.value(facts, "security_wait_minutes") == .int(20))
        #expect(Self.value(facts, "security_live") == .flag(false))
        #expect(Self.value(facts, "walk_minutes") == .int(12))
        #expect(Self.value(facts, "terminal") == .text("2E"))
        #expect(Self.value(facts, "gate") == .text("K36"))
        #expect(Self.value(facts, "ident") == .text("AF84"))
        #expect(Self.value(facts, "origin_iata") == .text("CDG"))
        #expect(Self.value(facts, "international") == .flag(true))
        #expect(Self.value(facts, "delay_minutes") == nil)
    }

    @Test func aFixedRuleTimeHasNoInventedParts() throws {
        let f = R.af84()
        let t = try #require(LeaveTimePlanner.plan(for: f, origin: R.cdg, destination: R.sfo, aircraft: nil,
                                                   measure: nil, precheck: false))
        let facts = try #require(BriefFacts.doorToDoor(flight: f, leave: t, walk: nil, tz: R.cdg.timeZone, now: Self.now))
        for id in ["drive_minutes", "security_wait_minutes", "bag_drop_minutes", "boarding_local", "walk_minutes"] {
            #expect(!Self.ids(facts).contains(id))
        }
    }

    @Test func noDoorToDoorOnceTheFlightHasLeft() throws {
        let (f, t, walk) = try Self.computed()
        #expect(BriefFacts.doorToDoor(flight: f, leave: t, walk: walk, tz: .gmt, now: t.departure.addingTimeInterval(60)) == nil)
        #expect(BriefFacts.doorToDoor(flight: f, leave: nil, walk: walk, tz: .gmt, now: Self.now) == nil)
    }

    // MARK: Why it is late

    static func late(_ minutes: Int = 40) -> Flight {
        var f = R.af84()
        f.estimatedOut = f.scheduledOut?.addingTimeInterval(Double(minutes) * 60)
        return f
    }

    static func leg(_ delay: Int) -> InboundLeg {
        InboundLeg(id: "1", ident: "AF11", originIata: "JFK", destinationIata: "CDG",
                   scheduledOut: now, scheduledIn: now, status: .enRoute, delayMinutes: delay)
    }

    static func weather(_ c: FlightCategory) -> Weather {
        var w = PreviewData.weather["KSFO"]!
        w.category = c; w.metarRaw = "KSFO 031756Z 28012KT 2SM BR OVC008 12/11 A3002"
        return w
    }

    @Test func nothingToExplainWhenOnTimeOrWithoutACause() {
        #expect(BriefFacts.delayCause(flight: R.af84(), inbound: [Self.leg(50)], originWeather: nil, destinationWeather: nil,
                                      advisories: FlightAdvisories(), events: []) == nil)
        #expect(BriefFacts.delayCause(flight: Self.late(), inbound: [], originWeather: Self.weather(.VFR),
                                      destinationWeather: nil, advisories: FlightAdvisories(), events: []) == nil)
        #expect(BriefFacts.delayCause(flight: Self.late(10), inbound: [Self.leg(50)], originWeather: nil,
                                      destinationWeather: nil, advisories: FlightAdvisories(), events: []) == nil)
    }

    @Test func delayCauseFactsHoldOnlyWhatIsKnown() throws {
        let programs = AirportPrograms(airportIcao: "KSFO", iata: "SFO", fetchedAt: Self.now, programs: [
            AirportProgram(airport: "SFO", kind: .groundDelay, reason: "low clouds", averageMinutes: 47),
        ])
        let event = FlightEvent(flightId: UUID(), kind: .gateChange, payload: ["gate": "K40"], receivedAt: Self.now)
        let facts = try #require(BriefFacts.delayCause(
            flight: Self.late(), inbound: [Self.leg(35)], originWeather: nil, destinationWeather: Self.weather(.IFR),
            advisories: FlightAdvisories(destinationPrograms: programs), events: [event]))
        #expect(Self.value(facts, "delay_minutes") == .int(40))
        #expect(Self.value(facts, "inbound_late_minutes") == .int(35))
        #expect(Self.value(facts, "inbound_status") == .text("en_route"))
        #expect(Self.value(facts, "destination_weather_category") == .text("IFR"))
        #expect(Self.value(facts, "destination_metar") == .text("KSFO 031756Z 28012KT 2SM BR OVC008 12/11 A3002"))
        #expect(Self.value(facts, "destination_faa_program") == .text("Ground delay program, about 47 min, low clouds"))
        #expect(Self.value(facts, "gate_changes") == .int(1))
        #expect(Self.value(facts, "origin_weather_category") == nil)
    }

    @Test func aLabelKeepsToTheBackendAlphabet() {
        #expect(BriefFacts.label("Ground stop; call me @ 555\nnow") == "Ground stop call me 555 now")
        #expect(BriefFacts.label("***") == nil)
        #expect(BriefFacts.label(String(repeating: "a", count: 200))?.count == 80)
    }

    // MARK: Airport summary

    @Test func airportSummaryFacts() throws {
        let stats = (departures: PreviewData.stats("KSFO"), arrivals: PreviewData.stats("KSFO", departures: false))
        let facts = try #require(BriefFacts.airportSummary(code: "SFO", weather: Self.weather(.IFR), stats: stats,
                                                           programs: nil, security: nil, level: .minor))
        #expect(Self.value(facts, "iata") == .text("SFO"))
        #expect(Self.value(facts, "weather_category") == .text("IFR"))
        #expect(Self.value(facts, "status_level") == .text("minor"))
        #expect(Self.ids(facts).contains("departures_on_time_percent"))
        #expect(BriefFacts.airportSummary(code: "SFO", weather: nil, stats: nil, programs: nil, security: nil,
                                          level: .normal) == nil)
    }

    // MARK: Nothing personal, and only ids the backend knows

    /// The ids the backend accepts per kind, read from its source (`facts.ts`), so a fact the server would
    /// refuse (or one that could carry personal data) fails here first.
    static func backendIds(_ kind: BriefKind) throws -> Set<String> {
        let source = try String(contentsOf: functions.appending(path: "facts.ts"), encoding: .utf8)
        let start = try #require(source.range(of: "  \(kind.rawValue): {\n"))
        let end = try #require(source.range(of: "\n  },", range: start.upperBound..<source.endIndex))
        var ids: Set<String> = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "...FLIGHT_KEYS," { ids.formUnion(["ident", "origin_iata", "destination_iata"]); continue }
            if let name = t.split(whereSeparator: { ":,".contains($0) }).first { ids.insert(String(name)) }
        }
        return ids
    }

    @Test func everyIdSentIsOneTheBackendAcceptsForItsKind() throws {
        let (f, t, walk) = try Self.computed()
        let programs = AirportPrograms(airportIcao: "KSFO", iata: "SFO", fetchedAt: Self.now, programs: [
            AirportProgram(airport: "SFO", kind: .groundStop),
        ])
        let event = FlightEvent(flightId: UUID(), kind: .gateChange, receivedAt: Self.now)
        let stats = (departures: PreviewData.stats("KSFO"), arrivals: PreviewData.stats("KSFO", departures: false))
        let wait = SecurityWait(airportIcao: "KSFO", iata: "SFO", isLive: true, source: .init(id: "x", name: "x"),
                                fetchedAt: Self.now, checkpoints: [
                                    SecurityCheckpoint(id: "all", name: "All", standardMinutes: 12, precheckMinutes: nil)])
        let sets: [(BriefKind, [BriefFact])] = [
            (.doorToDoor, BriefFacts.doorToDoor(flight: Self.late(), leave: t, walk: walk, tz: .gmt, now: Self.now) ?? []),
            (.delayCause, BriefFacts.delayCause(flight: Self.late(), inbound: [Self.leg(30)], originWeather: Self.weather(.IFR),
                                                destinationWeather: Self.weather(.MVFR),
                                                advisories: FlightAdvisories(originPrograms: programs, destinationPrograms: programs),
                                                events: [event]) ?? []),
            (.airportSummary, BriefFacts.airportSummary(code: "SFO", weather: Self.weather(.IFR), stats: stats,
                                                        programs: programs, security: wait, level: .major) ?? []),
        ]
        for (kind, facts) in sets {
            #expect(facts.count >= 4, "\(kind)")
            let allowed = try Self.backendIds(kind)
            #expect(allowed.contains("ident") || kind == .airportSummary)
            for id in Self.ids(facts) { #expect(allowed.contains(id), "\(kind) sends \(id)") }
            // No fact can hold the flight's or the traveller's identity beyond the flight number.
            let sent = String(data: try JSONEncoder().encode(facts), encoding: .utf8) ?? ""
            for banned in ["name", "passport", "booking", "seat", "email", "vault", f.id.uuidString] {
                #expect(!sent.lowercased().contains(banned), "\(kind) holds \(banned)")
            }
        }
        _ = f
    }

    // MARK: Wire

    @Test func theRequestBodyHoldsKindSubjectAndFactsOnly() throws {
        let facts = [BriefFact("ident", .text("AF84")), BriefFact("walk_minutes", .int(12)),
                     BriefFact("precheck", .flag(false)), BriefFact("visibility_miles", .number(2.5))]
        let data = try SupabaseFlightBriefService.body(.doorToDoor, subject: "abc", facts: facts)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["kind", "subject", "facts"])
        #expect(json["kind"] as? String == "door_to_door")
        let list = try #require(json["facts"] as? [[String: Any]])
        #expect(list.count == 4)
        #expect(list[0]["id"] as? String == "ident" && list[0]["value"] as? String == "AF84")
        #expect(list[1]["value"] as? Int == 12)
        #expect(list[2]["value"] as? Bool == false)
        #expect(list[3]["value"] as? Double == 2.5)
    }

    @Test func decodesTheBackendContract() throws {
        let data = try Data(contentsOf: Self.functions.appending(path: "contract/door_to_door.json"))
        let answer = try SupabaseFlightBriefService.decodeAnswer(data)
        #expect(answer.kind == "door_to_door" && answer.cached == false)
        let brief = try #require(try SupabaseFlightBriefService.decode(data))
        #expect(brief.kind == .doorToDoor)
        #expect(brief.text == "Gate K45 is about a 12 minute walk from security.")
        #expect(brief.factsUsed == ["gate", "walk_minutes"])
    }

    @Test func theBackendsRefusalMapsToUnavailable() {
        let body = Data(#"{"error":{"code":"llm_unavailable","message":"x"}}"#.utf8)
        #expect(SupabaseBackend.functionError(status: 503, body: body) == .providerUnavailable)
    }

    // MARK: Fake and model

    @Test func theFakePhrasesOnlyFromItsFacts() async throws {
        let (f, t, walk) = try Self.computed()
        let facts = try #require(BriefFacts.doorToDoor(flight: f, leave: t, walk: walk, tz: R.cdg.timeZone, now: Self.now))
        let fake = FakeFlightBriefService(now: Self.now)
        let brief = try #require(try await fake.brief(.doorToDoor, subject: f.id.uuidString, facts: facts))
        #expect(brief.text.contains("about 35 minutes") && brief.text.contains("gate K36"))
        #expect(!brief.text.contains("\u{2014}"))
        let unknown = try await fake.brief(.delayCause, subject: "x", facts: [BriefFact("ident", .text("AF84"))])
        #expect(unknown == nil)
    }

    @Test func theModelShowsATextAndHidesOnAnyFailure() async throws {
        let (f, t, walk) = try Self.computed()
        let facts = BriefFacts.doorToDoor(flight: f, leave: t, walk: walk, tz: .gmt, now: Self.now)
        let fake = FakeFlightBriefService(now: Self.now)
        let model = FlightBriefModel(kind: .doorToDoor, subject: f.id.uuidString.lowercased(), service: fake)
        await model.load(facts)
        #expect(model.brief != nil)
        await fake.setNextError(.rateLimited)
        await model.load(facts)
        #expect(model.brief == nil)
        await model.load(nil)
        #expect(model.brief == nil)
        let off = FlightBriefModel(kind: .doorToDoor, subject: "x", service: UnavailableFlightBriefService())
        await off.load(facts)
        #expect(off.brief == nil)
        #expect(await fake.calls == 2)
    }

    @Test func theEnvironmentDefaultsToOff() {
        #expect(!EnvironmentValues().flightBrief.isAvailable)
        #expect(!AppEnvironment.supabase(config: SupabaseConfig(url: URL(string: "https://x.supabase.co")!, anonKey: "k"),
                                         cache: try! CacheStore.inMemory(), recents: .memory).flightBrief.isAvailable)
    }
}
