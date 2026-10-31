import Foundation
import Testing
@testable import FlightKit

/// The security wait: `security-wait` answers decoded (the backend's contract files), the four hours before
/// departure, the shortest checkpoint for the passenger's terminal, the words on screen, the fakes and the
/// stores. The contract files are read from `supabase/functions/security-wait/contract/` in the repository
/// (written by the backend's tests), so a change on the backend side that the app cannot read fails here.
@MainActor @Suite struct SecurityWaitTests {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/security-wait/contract")

    private func contract(_ name: String) throws -> Data {
        try Data(contentsOf: Self.contract.appending(path: "\(name).json"))
    }

    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let iso = ISO8601DateFormatter()

    /// UA1527 from SFO terminal 3, as in the seed: 19:22Z, the seed's clock 15:42Z.
    static var ua1527: Flight { PreviewData.followed.first { $0.ident == "UA1527" }! }

    /// A wait with the given checkpoints, estimated at 07:30 in San Francisco.
    static func wait(_ cps: [SecurityCheckpoint], live: Bool = false) -> SecurityWait {
        SecurityWait(airportIcao: "KSFO", iata: "SFO", isLive: live, source: .init(id: "x", name: "Test source"),
                     fetchedAt: iso.date(from: "2026-11-03T15:30:00Z")!, checkpoints: cps)
    }

    // MARK: Decoding

    @Test func decodesTheEstimateContract() throws {
        let w = try #require(try SupabaseSecurityWaitService.decode(try contract("estimate")))
        #expect(w.airportIcao == "KSFO")
        #expect(w.iata == "SFO")
        #expect(w.isLive == false)
        #expect(w.source.id == "estimate_tsa_throughput")
        #expect(w.source.url == URL(string: "https://www.tsa.gov/foia/readingroom"))
        #expect(w.fetchedAt == Self.iso.date(from: "2026-11-03T15:30:00Z"))
        // SFO's real TSA checkpoints, by terminal then name.
        #expect(w.checkpoints.map(\.id) == ["security-checkpoint-b", "security-checkpoint-t1-b-mezzanine",
                                            "security-checkpoint-d", "security-checkpoint-f-1",
                                            "security-checkpoint-a", "security-checkpoint-g"])
        let f = try #require(w.checkpoints.first { $0.id == "security-checkpoint-f-1" })
        #expect(f.name == "Security Checkpoint F-1")
        #expect(f.terminal == "3")
        // The TSA report does not say which checkpoints have PreCheck: unknown, with a figure.
        #expect(f.precheck == nil)
        #expect(f.precheckMinutes.map { $0 >= 5 } == true)
        #expect(f.standardMinutes.map { $0 >= 5 && $0 % 5 == 0 } == true)
        #expect(SecurityWaitFacts.sameTerminal("I", w.checkpoints.last?.terminal))
        #expect(w.checkpoints.allSatisfy { !$0.isWholeAirport })
    }

    @Test func decodesTheTypicalDayAndLiveContracts() throws {
        let typical = try #require(try SupabaseSecurityWaitService.decode(try contract("typical")))
        #expect(typical.isLive == false)
        #expect(typical.source.id == "estimate_typical_day")
        #expect(typical.source.url == nil)
        #expect(typical.checkpoints.count == 1)
        #expect(typical.checkpoints[0].isWholeAirport)
        #expect(typical.checkpoints[0].precheck == nil)
        #expect(AirportSecuritySection.subtitle(typical) == "Typical wait at this hour")

        let live = try #require(try SupabaseSecurityWaitService.decode(try contract("live")))
        #expect(live.isLive)
        #expect(live.checkpoints.map(\.standardMinutes) == [14, 22])
        #expect(AirportSecuritySection.subtitle(live) == "Checkpoint waits right now")
    }

    @Test func outsideTheUSIsNil() throws {
        #expect(try SupabaseSecurityWaitService.decode(try contract("not_available")) == nil)
    }

    /// An available answer that does not say where its figures come from cannot be shown honestly.
    @Test func anAvailableAnswerNeedsASource() throws {
        var json = try JSONSerialization.jsonObject(with: try contract("estimate")) as! [String: Any]
        json["source"] = NSNull()
        let broken = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try SupabaseSecurityWaitService.decode(broken) }
    }

    // MARK: The window

    @Test func showsFromFourHoursBeforeDepartureUntilItLeaves() {
        var f = Self.ua1527
        let dep = f.scheduledOut!
        f.estimatedOut = nil
        #expect(!SecurityWaitFacts.isInWindow(f, now: dep.addingTimeInterval(-4 * 3600 - 60)))
        #expect(SecurityWaitFacts.isInWindow(f, now: dep.addingTimeInterval(-4 * 3600)))
        #expect(SecurityWaitFacts.isInWindow(f, now: dep.addingTimeInterval(-60)))
        #expect(!SecurityWaitFacts.isInWindow(f, now: dep))
        // A later estimate moves the window with it.
        f.estimatedOut = dep.addingTimeInterval(3600)
        #expect(SecurityWaitFacts.isInWindow(f, now: dep.addingTimeInterval(30 * 60)))
        #expect(!SecurityWaitFacts.isInWindow(f, now: dep.addingTimeInterval(-4 * 3600)))
        // Pushed back, gone, canceled or diverted: never.
        var pushed = f
        pushed.actualOut = dep
        #expect(!SecurityWaitFacts.isInWindow(pushed, now: dep.addingTimeInterval(-60)))
        for status in [FlightStatus.departed, .enRoute, .landed, .arrived, .canceled, .diverted] {
            var other = f
            other.status = status
            #expect(!SecurityWaitFacts.isInWindow(other, now: dep.addingTimeInterval(-60)))
        }
        var unscheduled = f
        unscheduled.scheduledOut = nil; unscheduled.estimatedOut = nil
        #expect(!SecurityWaitFacts.isInWindow(unscheduled, now: dep))
        // The seed's own clock is 3h40m before UA1527: inside.
        #expect(SecurityWaitFacts.isInWindow(Self.ua1527, now: PreviewData.now))
    }

    @Test func loadsOnlyForAFlightLeavingWithinTwelveHours() {
        let f = Self.ua1527
        let dep = f.estimatedOut ?? f.scheduledOut!
        #expect(SecurityWaitFacts.worthLoading(f, now: dep.addingTimeInterval(-12 * 3600)))
        #expect(!SecurityWaitFacts.worthLoading(f, now: dep.addingTimeInterval(-12 * 3600 - 60)))
        #expect(!SecurityWaitFacts.worthLoading(f, now: dep))
        #expect(!SecurityWaitFacts.worthLoading(PreviewData.enRoute, now: PreviewData.now))
    }

    // MARK: Picking the checkpoint

    @Test func terminalsCompareByName() {
        #expect(SecurityWaitFacts.terminalKey("Terminal 4") == "4")
        #expect(SecurityWaitFacts.terminalKey("T4") == "4")
        #expect(SecurityWaitFacts.terminalKey(" 4 ") == "4")
        #expect(SecurityWaitFacts.terminalKey("TB") == "tb")
        #expect(SecurityWaitFacts.terminalKey("") == nil)
        #expect(SecurityWaitFacts.terminalKey(nil) == nil)
        #expect(SecurityWaitFacts.sameTerminal("T3", "3"))
        #expect(SecurityWaitFacts.sameTerminal("I", "International"))
        #expect(SecurityWaitFacts.sameTerminal("b", "B"))
        #expect(!SecurityWaitFacts.sameTerminal("3", "International"))
        #expect(!SecurityWaitFacts.sameTerminal("2E", "2"))
        #expect(!SecurityWaitFacts.sameTerminal(nil, nil))
    }

    @Test func picksTheShortestForTheTerminal() {
        let w = Self.wait([
            .init(id: "t1", name: "Terminal 1", terminal: "1", precheck: true, standardMinutes: 10, precheckMinutes: 5),
            .init(id: "t3-e", name: "Terminal 3 E", terminal: "3", precheck: false, standardMinutes: 15, precheckMinutes: nil),
            .init(id: "t3-f", name: "Terminal 3 F", terminal: "3", precheck: true, standardMinutes: 25, precheckMinutes: 10),
            .init(id: "t3-x", name: "Terminal 3 X", terminal: "3", precheck: nil, standardMinutes: nil, precheckMinutes: nil),
        ])
        let three = SecurityWaitFacts.shortest(w, terminal: "3")
        #expect(three.standard?.id == "t3-e")
        #expect(three.precheck?.id == "t3-f")
        #expect(SecurityWaitFacts.candidates(w, terminal: "T3").matched)
        // Unknown terminal, or one no checkpoint serves: the whole airport.
        #expect(SecurityWaitFacts.shortest(w, terminal: nil).standard?.id == "t1")
        #expect(SecurityWaitFacts.shortest(w, terminal: "9").standard?.id == "t1")
        #expect(!SecurityWaitFacts.candidates(w, terminal: "9").matched)
        // A tie goes to the first in list order.
        let tie = Self.wait([
            .init(id: "a", name: "A", standardMinutes: 10, precheckMinutes: 5),
            .init(id: "b", name: "B", standardMinutes: 10, precheckMinutes: 5),
        ])
        #expect(SecurityWaitFacts.shortest(tie, terminal: nil).standard?.id == "a")
        // No figures at all: no row.
        let empty = Self.wait([.init(id: "a", name: "A", standardMinutes: nil, precheckMinutes: nil)])
        #expect(SecurityWaitFacts.shortest(empty, terminal: nil).standard == nil)
        #expect(SecurityWaitFacts.row(empty, terminal: nil, timeZone: Self.la) == nil)
    }

    // MARK: Words

    @Test func estimatesSayEstimateAndLiveSaysLive() {
        let cps: [SecurityCheckpoint] = [
            .init(id: "t3-e", name: "Terminal 3 E", terminal: "3", precheck: false, standardMinutes: 15, precheckMinutes: nil),
            .init(id: "t3-f", name: "Terminal 3 F", terminal: "3", precheck: true, standardMinutes: 25, precheckMinutes: 10),
        ]
        let estimate = SecurityWaitFacts.row(Self.wait(cps), terminal: "3", timeZone: Self.la)
        #expect(estimate?.title == "About 15m at security")
        #expect(estimate?.text == "Terminal 3 E · PreCheck about 10m at Terminal 3 F · Estimate for 07:30")
        let live = SecurityWaitFacts.row(Self.wait(cps, live: true), terminal: "3", timeZone: Self.la, clock: .h12)
        #expect(live?.title == "15m at security")
        #expect(live?.text.hasPrefix("Terminal 3 E · PreCheck 10m at Terminal 3 F · Live at 7:30") == true)
        // The same checkpoint for both: no repeated name.
        let one = Self.wait([.init(id: "t1", name: "Terminal 1", terminal: "1", precheck: true, standardMinutes: 20,
                                   precheckMinutes: 5)])
        #expect(SecurityWaitFacts.row(one, terminal: "1", timeZone: Self.la)?.text
            == "Terminal 1 · PreCheck about 5m · Estimate for 07:30")
        // The whole-airport estimate names no checkpoint and hedges PreCheck.
        let all = Self.wait([.init(id: SecurityCheckpoint.allId, name: "All checkpoints", standardMinutes: 10,
                                   precheckMinutes: 5)])
        #expect(SecurityWaitFacts.row(all, terminal: "2", timeZone: Self.la)?.text
            == "PreCheck about 5m where offered · Estimate for 07:30")
        #expect(SecurityWaitFacts.checkpointText(cps[0], live: false) == "About 15m")
        #expect(SecurityWaitFacts.checkpointText(cps[1], live: true) == "25m · PreCheck 10m")
        #expect(SecurityWaitFacts.checkpointText(.init(id: "x", name: "X", standardMinutes: nil, precheckMinutes: nil),
                                                 live: false) == "No figure")
        #expect(SecurityWaitFacts.terminalCaption(cps[0]) == "Terminal 3")
        #expect(SecurityWaitFacts.terminalCaption(.init(id: "g", name: "G", terminal: "International",
                                                        standardMinutes: 5, precheckMinutes: 5)) == "International")
        #expect(SecurityWaitFacts.footnote(Self.wait(cps)).contains("not a live measurement"))
        #expect(SecurityWaitFacts.footnote(Self.wait(cps, live: true)) == "Live from Test source.")
    }

    // MARK: Fakes and stores

    @Test func fakesGiveBelievableEstimates() async throws {
        let fake = FakeSecurityWaitService(now: PreviewData.now)
        // Friday 08:42 in San Francisco: the morning rush.
        let sfo = try #require(try await fake.securityWait(airport: "SFO"))
        #expect(!sfo.isLive)
        #expect(sfo.checkpoints.count == 6)
        #expect(sfo.checkpoints.allSatisfy { ($0.standardMinutes ?? 0) >= 5 && ($0.standardMinutes ?? 0) <= 45 })
        #expect(sfo.checkpoints.allSatisfy { $0.precheck == false ? $0.precheckMinutes == nil
            : ($0.precheckMinutes ?? 99) <= ($0.standardMinutes ?? 0) })
        let row = try #require(SecurityWaitFacts.row(sfo, terminal: Self.ua1527.terminalOrigin, timeZone: Self.la))
        #expect(row.title == "About 15m at security")
        #expect(row.text == "Terminal 3 E · PreCheck about 10m at Terminal 3 F · Estimate for 08:42")
        #expect(try await fake.securityWait(airport: "KAUS")?.checkpoints.count == 3)
        #expect(try await fake.securityWait(airport: "JFK")?.checkpoints.count == 5)
        // Another US airport: one typical row. Paris: none.
        let den = try #require(try await fake.securityWait(airport: "DEN"))
        #expect(den.checkpoints.map(\.id) == [SecurityCheckpoint.allId])
        #expect(den.source.id == "estimate_typical_day")
        #expect(try await fake.securityWait(airport: "CDG") == nil)
        // At 03:00 the lines are short.
        let night = FakeSecurityWaitService.wait(PreviewData.airport("KSFO")!,
                                                 at: Self.iso.date(from: "2026-10-23T10:00:00Z")!)!
        #expect(night.checkpoints.allSatisfy { $0.standardMinutes == 5 })
        await fake.setNextError(.providerUnavailable)
        await #expect(throws: APIError.self) { try await fake.securityWait(airport: "SFO") }
    }

    @Test func storesLoadTheWait() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let airports = FakeAirportService(now: PreviewData.now)
        let security = FakeSecurityWaitService(now: PreviewData.now)
        let f = Self.ua1527
        let store = FlightDetailStore(id: f.id, flights: flights, airports: airports, security: security)
        await store.load()
        await store.loadExtras(now: PreviewData.now)
        #expect(store.securityWait?.airportIcao == "KSFO")
        // Too early to matter, or already gone: no call, nothing shown.
        let early = FlightDetailStore(id: f.id, flights: flights, airports: airports, security: security)
        await early.load()
        await early.loadExtras(now: f.scheduledOut!.addingTimeInterval(-13 * 3600))
        #expect(early.securityWait == nil)
        let gone = FlightDetailStore(id: PreviewData.enRoute.id, flights: flights, airports: airports, security: security)
        await gone.load()
        await gone.loadExtras(now: PreviewData.now)
        #expect(gone.securityWait == nil)
        // A failure hides the row only.
        await security.setNextError(.providerUnavailable)
        let failed = FlightDetailStore(id: f.id, flights: flights, airports: airports, security: security)
        await failed.load()
        await failed.loadExtras(now: PreviewData.now)
        #expect(failed.securityWait == nil)
        #expect(failed.error == nil)

        let sfo = AirportStore(code: "KSFO", airports: airports, security: security)
        await sfo.load()
        #expect(sfo.security?.checkpoints.count == 6)
        #expect(sfo.error == nil)
        let cdg = AirportStore(code: "LFPG", airports: airports, security: security)
        await cdg.load()
        #expect(cdg.security == nil)
        // Without a service: no section.
        let plain = AirportStore(code: "KSFO", airports: airports)
        await plain.load()
        #expect(plain.security == nil)
    }

    @Test func environmentsWireTheService() async throws {
        let fake = try await AppEnvironment.fake(now: PreviewData.now)
        #expect(fake.security is FakeSecurityWaitService)
        let store = fake.makeAirportStore(code: "KSFO")
        await store.load()
        #expect(store.security != nil)
    }
}
