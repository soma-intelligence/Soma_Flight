import Foundation
import Synchronization
import Testing
import FlightImportKit
@testable import FlightKit

/// A flight service that answers lookups from a script and records every query.
final class RecordingFlights: FlightService, Sendable {
    private let calls = Mutex<[FlightQuery]>([])
    private let answer: @Sendable (FlightQuery) -> [Flight]

    init(_ answer: @escaping @Sendable (FlightQuery) -> [Flight] = { _ in [] }) { self.answer = answer }

    var queries: [FlightQuery] { calls.withLock { $0 } }

    func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] {
        calls.withLock { $0.append(query) }
        let found = answer(query)
        guard !found.isEmpty else { throw .notFound }
        return found
    }
    func followed() async throws(APIError) -> [Flight] { [] }
    func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) {}
    func unfollow(_ id: Flight.ID) async throws(APIError) {}
    func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? { nil }
    func followDetails(_ id: Flight.ID) async throws(APIError) -> FollowDetails? { nil }
    func saveFollowDetails(_ id: Flight.ID, _ details: FollowDetails) async throws(APIError) {}
    func flight(_ id: Flight.ID) async throws(APIError) -> Flight { throw .notFound }
    func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] { [] }
    func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> { AsyncStream { $0.finish() } }
}

/// A schedule service that answers from a script and records every query. `truncated` marks every
/// answer as cut at the page limit; `error` fails every call.
final class RecordingSchedules: ScheduleService, Sendable {
    private let calls = Mutex<[ScheduleQuery]>([])
    private let answer: @Sendable (ScheduleQuery) -> [ScheduledFlight]
    private let truncated: Bool
    private let error: APIError?

    init(truncated: Bool = false, error: APIError? = nil,
         _ answer: @escaping @Sendable (ScheduleQuery) -> [ScheduledFlight] = { _ in [] }) {
        self.answer = answer; self.truncated = truncated; self.error = error
    }

    var queries: [ScheduleQuery] { calls.withLock { $0 } }

    func schedules(_ q: ScheduleQuery) async throws(APIError) -> [ScheduledFlight] {
        try await scheduleDay(q).flights
    }

    func scheduleDay(_ q: ScheduleQuery) async throws(APIError) -> ScheduleDay {
        calls.withLock { $0.append(q) }
        if let error { throw error }
        return ScheduleDay(flights: answer(q), truncated: truncated)
    }
}

/// Which lookups a search makes for what it holds: today's live paths within two days, airline
/// schedules further ahead, and how the rows are filtered and ordered.
@Suite @MainActor struct SearchRoutingTests {
    nonisolated static let paris = TimeZone(identifier: "Europe/Paris")!

    /// Sunday 2026-11-01 at `hour` in Paris.
    nonisolated static func at(_ day: Int = 1, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = paris
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    nonisolated static let now = at(1, 12)

    static func store(_ flights: RecordingFlights, _ schedules: (any ScheduleService)? = nil) -> SearchStore {
        let now = Self.now
        let s = schedules.map { SearchStore(flights: flights, schedules: $0, now: { now }) }
            ?? SearchStore(flights: flights, now: { now })
        s.timeZone = paris
        s.monthFirst = false
        s.date = now
        s.suggestDelay = .milliseconds(1)
        s.liveDelay = .milliseconds(20)
        return s
    }

    nonisolated static func flight(_ ident: String, _ origin: String, _ destination: String, out: Date, operator op: String? = nil) -> Flight {
        Flight(providerId: "\(ident)-\(out.timeIntervalSince1970)", ident: ident, operator: op,
               originIcao: origin, destinationIcao: destination, scheduledOut: out)
    }

    nonisolated static func planned(_ ident: String, _ origin: String, _ destination: String, out: Date, airline: String? = nil) -> ScheduledFlight {
        ScheduledFlight(ident: ident, airline: airline, origin: origin, destination: destination, scheduledOut: out)
    }

    /// The live idents in order.
    static func idents(_ s: SearchStore) -> [String] {
        s.items.map {
            switch $0 {
            case .live(let f): f.ident
            case .planned(let p): p.ident
            }
        }
    }

    @Test func aFlightNumberTodayIsOneIdentLookup() async {
        let flights = RecordingFlights { q in
            if case .ident(let i, _) = q, i == "AF84" { return [Self.flight("AF84", "LFPG", "KSFO", out: Self.at(1, 13))] }
            return []
        }
        let schedules = RecordingSchedules()
        let s = Self.store(flights, schedules)
        s.text = "AF84"
        await s.search()
        #expect(flights.queries.count == 1)
        if case .ident(let i, _)? = flights.queries.first { #expect(i == "AF84") } else { Issue.record("not an ident lookup") }
        #expect(schedules.queries.isEmpty)
        #expect(Self.idents(s) == ["AF84"])
        #expect(s.results.map(\.ident) == ["AF84"])
        #expect(s.intent.ident == "AF84")
        #expect(s.note == nil)
    }

    @Test func twoPlacesTheDayAfterTomorrowLookUpTheirRoutes() async throws {
        // Each route answers one flight, later for later pairs, so the merge must sort.
        let flights = RecordingFlights { q in
            guard case .route(let o, let d, _) = q else { return [] }
            let hour = o == "LFPO" ? 9 : 15
            return [Self.flight("\(o.suffix(2))\(d.suffix(2))", o, d, out: Self.at(3, hour + d.count))]
        }
        let schedules = RecordingSchedules()
        let s = Self.store(flights, schedules)
        s.text = "Paris New York apres demain"
        await s.search()
        let intent = s.intent
        #expect(intent.origins.count >= 2)
        #expect(intent.destinations.count >= 1)
        var pairs: Set<String> = []
        for q in flights.queries {
            guard case .route(let o, let d, let date) = q else { Issue.record("not a route: \(q)"); continue }
            pairs.insert("\(o)-\(d)")
            #expect(LocalDay(date, in: Self.paris) == LocalDay(year: 2026, month: 11, day: 3))
        }
        let expected = Set(SearchStore.pairs(intent.origins, intent.destinations).map { "\($0.0)-\($0.1)" })
        #expect(pairs == expected)
        #expect(flights.queries.count == expected.count)
        #expect(expected.count <= SearchStore.maxCalls)
        #expect(pairs.contains("LFPG-KJFK") && pairs.contains("LFPO-KJFK"))
        #expect(schedules.queries.isEmpty)
        #expect(s.items.count == expected.count)
        let outs = s.results.compactMap(\.scheduledOut)
        #expect(outs == outs.sorted())
        #expect(s.results.first?.originIcao == "LFPO")
    }

    @Test func twoPlacesThreeWeeksOutAskTheSchedulesOncePerPair() async {
        let flights = RecordingFlights()
        let schedules = RecordingSchedules { q in
            guard let o = q.origin, q.destination == "KJFK" else { return [] }
            // One flight to New York per origin (its own number), and one to London the filter drops.
            return [Self.planned("AF\(o.suffix(2))22", o, "KJFK", out: Self.at(22, 10), airline: "AFR"),
                    Self.planned("AF1080", o, "EGLL", out: Self.at(22, 8), airline: "AFR")]
        }
        let s = Self.store(flights, schedules)
        s.text = "Paris New York 22 nov"
        await s.search()
        #expect(flights.queries.isEmpty)
        let pairs = Set(schedules.queries.map { "\($0.origin ?? "")-\($0.destination ?? "")" })
        let all = Set(s.intent.origins.flatMap { o in s.intent.destinations.map { "\(o)-\($0)" } })
        #expect(pairs.isSubset(of: all))
        #expect(schedules.queries.count == min(all.count, SearchStore.maxCalls))
        #expect(pairs.contains("LFPG-KJFK") && pairs.contains("LFPO-KJFK"))
        #expect(schedules.queries.allSatisfy { $0.day == LocalDay(year: 2026, month: 11, day: 22) })
        // Only the rows to New York stay, all planned.
        #expect(s.items.count == 2)
        #expect(s.items.allSatisfy { if case .planned(let p) = $0 { p.destination == "KJFK" } else { false } })
        #expect(s.results.isEmpty)
        #expect(s.note == nil)
    }

    @Test func aFlightNumberWeeksOutAsksTheSchedulesByItsIATADesignator() async {
        let schedules = RecordingSchedules { q in
            q.ident == "AF84" ? [Self.planned("AF84", "LFPG", "KSFO", out: Self.at(22, 13))] : []
        }
        let s = Self.store(RecordingFlights(), schedules)
        s.text = "AFR84 22 nov"
        await s.search()
        #expect(schedules.queries.map(\.ident) == ["AF84"])
        #expect(Self.idents(s) == ["AF84"])
    }

    @Test func anAirlineAndAPlaceTodayKeepThatAirlinesRows() async {
        let flights = RecordingFlights { q in
            guard case .airport(let code) = q, code == "LFPG" else { return [] }
            return [Self.flight("AF1080", "LFPG", "EGLL", out: Self.at(1, 14), operator: "AFR"),
                    Self.flight("UA57", "LFPG", "KEWR", out: Self.at(1, 15), operator: "UAL"),
                    Self.flight("AF22", "LFPG", "KJFK", out: Self.at(1, 16))]
        }
        let s = Self.store(flights, RecordingSchedules())
        s.text = "Air France CDG"
        await s.search()
        #expect(s.intent.airline?.id == "AFR")
        #expect(flights.queries == [.airport("LFPG")])
        #expect(Set(Self.idents(s)) == ["AF1080", "AF22"])
    }

    @Test func onePlaceGroupsByDestinationKnownFirst() async {
        let flights = RecordingFlights { q in
            guard case .airport("LFPG") = q else { return [] }
            return [Self.flight("AF1080", "LFPG", "EGLL", out: Self.at(2, 8)),
                    Self.flight("AF22", "LFPG", "KJFK", out: Self.at(2, 11)),
                    Self.flight("BA303", "LFPG", "EGLL", out: Self.at(2, 12)),
                    Self.flight("AF1404", "LFPG", "LIRF", out: Self.at(2, 9)),
                    Self.flight("AF6", "LFPG", "KJFK", out: Self.at(2, 10)),
                    // Another day and an arrival: not departures of 2 November.
                    Self.flight("AF1006", "LFPG", "LEMD", out: Self.at(1, 18)),
                    Self.flight("BA304", "EGLL", "LFPG", out: Self.at(2, 7))]
        }
        let s = Self.store(flights, RecordingSchedules())
        s.known = [KnownFlight(ident: "AF22", origin: "LFPG", destination: "KJFK", date: Self.at(1, 11, month: 10), followed: false)]
        s.text = "CDG demain"
        await s.search()
        #expect(Self.idents(s) == ["AF6", "AF22", "AF1080", "BA303", "AF1404"])
    }

    @Test func aTimeOfDaySortsByDistanceToIt() async {
        let flights = RecordingFlights { q in
            guard case .route = q else { return [] }
            return [Self.flight("AF1", "LFPG", "KJFK", out: Self.at(1, 8)),
                    Self.flight("AF2", "LFPG", "KJFK", out: Self.at(1, 18, 30)),
                    Self.flight("AF3", "LFPG", "KJFK", out: Self.at(1, 21)),
                    Self.flight("AF4", "LFPG", "KJFK", out: Self.at(1, 19, 10))]
        }
        let s = Self.store(flights, RecordingSchedules())
        s.text = "CDG JFK soir"
        await s.search()
        #expect(s.intent.timeOfDay == 1140)
        #expect(Self.idents(s) == ["AF4", "AF2", "AF3", "AF1"])
    }

    @Test func aFarDayWithoutTheLiveServiceSaysSo() async {
        let flights = RecordingFlights()
        let s = Self.store(flights)
        s.text = "Paris New York 22 nov"
        await s.search()
        #expect(s.items.isEmpty)
        #expect(s.note == "Future dates need the live service")
        #expect(s.error == nil)
        #expect(flights.queries.isEmpty)
    }

    @Test func aDayPastTheSchedulesReachSaysSoAndLooksNowhere() async {
        let flights = RecordingFlights { _ in [Self.flight("AF1", "LFPG", "KJFK", out: Self.at(1, 13))] }
        let schedules = RecordingSchedules()
        let s = Self.store(flights, schedules)
        s.text = "Paris New York 15 oct"
        s.textChanged()
        #expect(s.note == "Airline schedules only go 330 days ahead")
        await s.search()
        #expect(s.note == "Airline schedules only go 330 days ahead")
        #expect(s.items.isEmpty)
        #expect(flights.queries.isEmpty)
        #expect(schedules.queries.isEmpty)
        // A date in reach clears it.
        s.text = "Paris New York 15 dec"
        s.textChanged()
        #expect(s.note == nil)
    }

    @Test func aClockTimeIsNotAFarDate() async {
        let flights = RecordingFlights { q in
            switch q {
            case .route: [Self.flight("AF22", "LFPG", "KJFK", out: Self.at(1, 22, 30))]
            case .ident: [Self.flight("AF84", "LFPG", "KSFO", out: Self.at(1, 9, 30))]
            case .airport: []
            }
        }
        let s = Self.store(flights, RecordingSchedules())
        s.text = "CDG JFK 10 30 pm"
        s.textChanged()
        #expect(s.note == nil)
        await s.search()
        #expect(s.intent.timeOfDay == 1350)
        #expect(s.note == nil)
        #expect(Self.idents(s) == ["AF22"])
        s.text = "AF84 9 30 am"
        s.textChanged()
        await s.search()
        #expect(s.intent.timeOfDay == 570)
        #expect(s.note == nil)
        #expect(Self.idents(s) == ["AF84"])
        #expect(flights.queries.count == 2)
        // A far date alongside a place still says so.
        s.text = "paris 15 oct"
        s.textChanged()
        #expect(s.note == SearchStore.beyondReachNote)
    }

    @Test func aCityPairFansOutToFourCallsAtMost() async {
        let flights = RecordingFlights()
        let schedules = RecordingSchedules()
        let s = Self.store(flights, schedules)
        s.text = "London Moscow demain"
        await s.search()
        #expect(s.intent.origins.count >= 3)
        #expect(s.intent.destinations.count >= 3)
        #expect(flights.queries.count == SearchStore.maxCalls)
        // Spread over both ends: two origins and two destinations are asked.
        let routes = flights.queries.compactMap { q -> (String, String)? in
            if case .route(let o, let d, _) = q { (o, d) } else { nil }
        }
        #expect(Set(routes.map(\.0)).count == 2)
        #expect(Set(routes.map(\.1)).count == 2)
        s.text = "London Moscow 22 nov"
        await s.search()
        #expect(schedules.queries.count == SearchStore.maxCalls)
        #expect(schedules.queries.allSatisfy { $0.origin != nil && $0.destination != nil })
    }

    @Test func aRouteSendsOnlyWhenAllItsCallsFitTheBudget() {
        var gate = LiveLookupGate(budget: 10)
        let t = Self.now
        gate.didSend(now: t, cost: 7)
        #expect(gate.verdict(for: "four", cost: 4, now: t) == .wait)
        #expect(gate.verdict(for: "one", cost: 1, now: t) == .send)
        #expect(gate.verdict(for: "three", cost: 3, now: t) == .send)
    }

    @Test func schedulesTheBuildCannotReachCostNothing() async {
        let s = Self.store(RecordingFlights())
        s.text = "Paris New York 22 nov"
        await s.lookUpLive()
        #expect(s.note == SearchStore.unavailableNote)
        #expect(s.gate.sent.isEmpty)
        // A live route spends one call per pair.
        s.text = "CDG JFK demain"
        await s.lookUpLive()
        #expect(s.gate.sent.count == 1)
    }

    @Test func aTimeAloneLooksNothingUp() async {
        let flights = RecordingFlights { _ in [Self.flight("AF1", "LFPG", "KJFK", out: Self.at(1, 13))] }
        let schedules = RecordingSchedules()
        let s = Self.store(flights, schedules)
        s.text = "18h"
        s.textChanged()
        try? await Task.sleep(for: .milliseconds(80))
        await s.lookUpLive()
        await s.search()
        #expect(flights.queries.isEmpty)
        #expect(schedules.queries.isEmpty)
        #expect(s.items.isEmpty)
    }

    @Test func aPauseOnASentenceWithADayRoutesIt() async {
        let schedules = RecordingSchedules { q in
            [Self.planned("AF22", q.origin ?? "LFPG", "KJFK", out: Self.at(22, 10))]
        }
        let s = Self.store(RecordingFlights(), schedules)
        s.text = "Paris New York 22 nov"
        s.textChanged()
        for _ in 0..<200 where s.items.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!s.items.isEmpty)
        #expect(s.intent.day == LocalDay(year: 2026, month: 11, day: 22))
        // Typing on to the same intent keeps the rows, and asks nothing new.
        let asked = schedules.queries.count
        s.text = "Paris New York 22 nov "
        s.textChanged()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!s.items.isEmpty)
        #expect(schedules.queries.count == asked)
    }

    @Test func theAppSearchStoreReadsTheEnvironmentsSchedules() async throws {
        var env = try await AppEnvironment.fake()
        let schedules = RecordingSchedules()
        env.schedules = schedules
        let s = env.makeSearchStore()
        s.text = "AF84 22 dec"
        await s.search()
        #expect(schedules.queries.count == 1)
    }
}
