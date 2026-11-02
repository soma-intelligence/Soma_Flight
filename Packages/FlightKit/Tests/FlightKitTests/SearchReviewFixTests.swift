import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// The search's final review fixes: the day a route or a flight number is read on, the service paths a
/// near route takes, the notes for cut and refused schedules, and what recent searches keep and show.
@Suite @MainActor struct SearchReviewFixTests {
    typealias R = SearchRoutingTests
    nonisolated static let newYork = TimeZone(identifier: "America/New_York")!

    /// `day` 2026 at `hour`:`minute` in New York.
    nonisolated static func ny(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Near routes keep their day

    /// "Tomorrow" between two places asks each pair's route for that day, never a board, and a row on
    /// another day (a board or lookup that carries neighbours) never shows.
    @Test func twoPlacesTomorrowAskDatedRoutesAndKeepThatDay() async {
        let flights = RecordingFlights { q in
            guard case .route(let o, let d, _) = q, o == "LFPG", d == "KJFK" else { return [] }
            return [R.flight("AF6", o, d, out: R.at(1, 10, 30)), R.flight("AF6", o, d, out: R.at(2, 10, 30)),
                    R.flight("AF10", o, d, out: R.at(2, 13, 30))]
        }
        let schedules = RecordingSchedules()
        let s = R.store(flights, schedules)
        s.text = "CDG JFK demain"
        await s.search()
        #expect(flights.queries.count == 1)
        guard case .route(let o, let d, let date)? = flights.queries.first else {
            Issue.record("not a route lookup: \(flights.queries)"); return
        }
        #expect((o, d) == ("LFPG", "KJFK"))
        #expect(LocalDay(date, in: R.paris) == LocalDay(year: 2026, month: 11, day: 2))
        #expect(schedules.queries.isEmpty)
        #expect(R.idents(s) == ["AF6", "AF10"])
        #expect(s.items.allSatisfy { LocalDay($0.scheduledOut!, in: R.paris) == LocalDay(year: 2026, month: 11, day: 2) })
    }

    /// A route with no day typed keeps today's rows only.
    @Test func twoPlacesTodayKeepToday() async {
        let flights = RecordingFlights { q in
            guard case .route(let o, let d, _) = q else { return [] }
            return [R.flight("AF6", o, d, out: R.at(1, 18)), R.flight("AF6", o, d, out: R.at(2, 10, 30))]
        }
        let s = R.store(flights, RecordingSchedules())
        s.text = "CDG JFK"
        await s.search()
        #expect(s.items.count == 1)
        #expect(s.items.first.flatMap(\.scheduledOut) == R.at(1, 18))
    }

    /// The live service reads a route from the origin's board only for the origin's today; any other
    /// day is a dated `flight-lookup` route search.
    @Test func theServiceUsesTheBoardForTodayOnly() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let cdg = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", country: "FR",
                          lat: 49, lon: 2.5, tz: "Europe/Paris")
        let lookup: (String) -> Airport? = { $0 == "LFPG" || $0 == "CDG" ? cdg : nil }
        let now = R.at(1, 12)
        #expect(SupabaseFlightService.boardServes(date: R.at(1, 12), origin: "LFPG", now: now, airport: lookup, timeZone: paris))
        #expect(!SupabaseFlightService.boardServes(date: R.at(2, 12), origin: "LFPG", now: now, airport: lookup, timeZone: paris))
        #expect(!SupabaseFlightService.boardServes(date: R.at(3, 12), origin: "CDG", now: now, airport: lookup, timeZone: paris))
        // Just after midnight in Paris, 23:30 the evening before in New York: Paris's today is the 2nd.
        let late = R.at(2, 0, 30)
        let ny = Self.newYork
        #expect(SupabaseFlightService.boardServes(date: Self.ny(11, 2, 12), origin: "LFPG", now: late, airport: lookup, timeZone: ny))
        #expect(!SupabaseFlightService.boardServes(date: Self.ny(11, 1, 12), origin: "LFPG", now: late, airport: lookup, timeZone: ny))
    }

    /// A phone in Los Angeles late in the afternoon is already the next day in Paris: with no day typed,
    /// a route from Paris asks the Paris day, and its rows (on that day in Paris) survive.
    @Test func noTypedDayAsksTheOriginsToday() async {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        // 16:00 in Los Angeles on 1 Nov is 01:00 on 2 Nov in Paris.
        let flights = RecordingFlights { q in
            guard case .route(let o, let d, _) = q else { return [] }
            return [R.flight("AF6", o, d, out: R.at(2, 10, 30))]
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 16))!
        let s = SearchStore(flights: flights, schedules: RecordingSchedules(), now: { now })
        s.timeZone = la
        s.monthFirst = true
        s.date = now
        s.text = "CDG JFK"
        await s.search()
        guard case .route(_, _, let date)? = flights.queries.first else {
            Issue.record("not a route lookup: \(flights.queries)"); return
        }
        #expect(SupabaseBackend.day(date, in: la) == "2026-11-02")
        #expect(R.idents(s) == ["AF6"])
    }

    // MARK: Far flight numbers keep the origin's day

    /// The schedules of a flight number span the day either side: only the flight leaving on the asked
    /// day at its own origin shows, a 20:00 New York departure (01:00Z the next day) included.
    @Test func aFarFlightNumberKeepsTheDayAtItsOrigin() async {
        let schedules = RecordingSchedules { _ in
            [R.planned("AF7", "KJFK", "LFPG", out: Self.ny(12, 11, 20)), R.planned("AF7", "KJFK", "LFPG", out: Self.ny(12, 12, 20)),
             R.planned("AF7", "KJFK", "LFPG", out: Self.ny(12, 13, 20))]
        }
        let s = R.store(RecordingFlights(), schedules)
        s.text = "AF 7 12 dec"
        await s.search()
        #expect(schedules.queries.count == 1)
        #expect(schedules.queries.first?.day == LocalDay(year: 2026, month: 12, day: 12))
        #expect(s.items.map(\.scheduledOut) == [Self.ny(12, 12, 20)])
    }

    /// "To Tokyo 12 dec": the backend reads a destination-only query on the destination's day, so the
    /// rows are not held to their origin's day, and a departure the evening before at the origin stays.
    @Test func aFarDestinationOnlySearchKeepsTheBackendsDay() async {
        let schedules = RecordingSchedules { _ in
            [R.planned("AA167", "KJFK", "RJTT", out: Self.ny(12, 11, 13)), R.planned("NH9", "KJFK", "RJTT", out: Self.ny(12, 12, 1))]
        }
        let s = R.store(RecordingFlights(), schedules)
        s.text = "to Tokyo 12 dec"
        await s.search()
        #expect(!schedules.queries.isEmpty && schedules.queries.allSatisfy { $0.destination != nil && $0.origin == nil })
        #expect(Set(R.idents(s)) == ["AA167", "NH9"])
    }

    // MARK: Time of day and cut answers

    /// A one-place search far ahead sends its time of day, so the backend reads the hours around it.
    @Test func aOnePlaceSearchSendsItsTimeOfDay() async {
        let schedules = RecordingSchedules()
        let s = R.store(RecordingFlights(), schedules)
        s.text = "Paris 22 nov soir"
        await s.search()
        #expect(!schedules.queries.isEmpty)
        #expect(schedules.queries.allSatisfy { $0.time == 1140 })
        // A route lists the whole day, closest first: no time sent.
        s.text = "Paris New York 22 nov soir"
        await s.search()
        let route = schedules.queries.filter { $0.destination != nil }
        #expect(!route.isEmpty && route.allSatisfy { $0.time == nil })
    }

    /// An answer cut at the backend's page limit says so under the field.
    @Test func aCutAnswerSaysSo() async {
        let schedules = RecordingSchedules(truncated: true) { q in
            [R.planned("AF1234", q.origin ?? "LFPG", "LFML", out: R.at(22, 9))]
        }
        let s = R.store(RecordingFlights(), schedules)
        s.text = "CDG 22 nov"
        await s.search()
        #expect(!s.items.isEmpty)
        #expect(s.note == SearchStore.truncatedNote)
        #expect(s.error == nil)
    }

    // MARK: Refusals

    /// A schedules service that is built in but refuses (the spend cap, an outage) is not "future dates
    /// need the live service".
    @Test func aLiveRefusalIsNotTheMissingServiceNote() async {
        let s = R.store(RecordingFlights(), RecordingSchedules(error: .providerUnavailable))
        s.text = "Paris New York 22 nov"
        await s.search()
        #expect(s.note == SearchStore.schedulesDownNote)
        let built = R.store(RecordingFlights())
        built.text = "Paris New York 22 nov"
        await built.search()
        #expect(built.note == SearchStore.unavailableNote)
    }

    /// `flight-schedules` never answers not found itself: a 404 is the function missing, not "no flights".
    @Test func aMissingSchedulesFunctionIsUnavailable() {
        #expect(SupabaseScheduleService.mapped(.notFound) == .providerUnavailable)
        #expect(SupabaseScheduleService.mapped(.rateLimited) == .rateLimited)
    }

    // MARK: Recent searches

    /// Recents keep what was typed (trimmed), one entry per query whatever its case.
    @Test func recentsKeepTheTypedText() async {
        let flights = RecordingFlights { _ in [R.flight("AF84", "LFPG", "KSFO", out: R.at(1, 13))] }
        let s = R.store(flights)
        s.text = "AF84"
        await s.search()
        s.text = " af84 "
        await s.search()
        #expect(s.recent == ["af84"])
    }

    /// A recent search is described by the pieces it reads as, its icon by the first.
    @Test func recentsAreDescribedByTheirChips() {
        let s = R.store(RecordingFlights())
        let route = s.intent(for: "Paris Rome 12 dec")
        #expect(SearchView.recentSubtitle(route, clock: .h24) == "Paris (CDG, ORY) · Rome (CIA, FCO) · Sat Dec 12")
        #expect(SearchView.recentIcon(route) == SearchView.routeIcon)
        let flight = s.intent(for: "af 84 demain")
        #expect(SearchView.recentSubtitle(flight, clock: .h24) == "AF 84 · Mon Nov 2")
        #expect(SearchView.recentIcon(flight) == "airplane")
        #expect(SearchView.recentIcon(s.intent(for: "CDG")) == "building.columns")
        #expect(SearchView.recentSubtitle(s.intent(for: "zzz"), clock: .h24) == nil)
        #expect(SearchView.recentIcon(s.intent(for: "zzz")) == "clock.arrow.circlepath")
    }

    // MARK: Builds without the schedules function

    @Test func schedulesFlagReadsLikeTheOthers() {
        #expect(SupabaseScheduleService.isEnabled(raw: "YES"))
        #expect(!SupabaseScheduleService.isEnabled(raw: "NO"))
        #expect(!SupabaseScheduleService.isEnabled(raw: "$(SCHEDULES_ENABLED)"))
        #expect(!SupabaseScheduleService.isEnabled(raw: nil))
    }

    /// Until `flight-schedules` is deployed (`SCHEDULES_ENABLED` NO), debug builds search the fake
    /// schedules and release builds show the note; YES asks the function.
    @Test func schedulesFollowTheirOwnFlag() throws {
        let config = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "k")
        let off = AppEnvironment.supabase(config: config, cache: try CacheStore.inMemory(), recents: .memory,
                                          authStorage: MemoryAuthStorage(), insights: true)
        #expect(off.schedules is FakeScheduleService)
        let on = AppEnvironment.supabase(config: config, cache: try CacheStore.inMemory(), recents: .memory,
                                         authStorage: MemoryAuthStorage(), schedules: true)
        #expect(on.schedules is SupabaseScheduleService)
    }

    // MARK: The fake schedules

    /// Debug builds search these: a city pair, an airline from an airport, each on the asked day at the
    /// origin, at the hour it is planned there.
    @Test func theFakeSchedulesAnswerTheExampleSearches() async {
        let s = SearchStore(flights: FakeFlightService(now: R.now), schedules: FakeScheduleService(), now: { R.now })
        s.timeZone = R.paris
        s.monthFirst = false
        s.text = "Paris New York 12 dec"
        await s.search()
        #expect(s.items.count >= 4)
        #expect(Set(s.items.map(\.origin)).isSubset(of: ["LFPG", "LFPO"]))
        #expect(Set(s.items.map(\.destination)).isSubset(of: ["KJFK", "KEWR"]))
        #expect(Set(s.items.map { SearchStore.airlinePrefix($0.ident) }).count >= 3)
        #expect(s.items.allSatisfy { LocalDay($0.scheduledOut!, in: R.paris) == LocalDay(year: 2026, month: 12, day: 12) })
        let af6 = s.items.first { $0.ident == "AF6" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = R.paris
        #expect(af6.flatMap(\.scheduledOut).map { cal.component(.hour, from: $0) } == 10)

        s.text = "Lufthansa Munich vendredi"
        await s.search()
        #expect(s.items.count >= 4)
        #expect(s.items.allSatisfy { $0.origin == "EDDM" && $0.ident.hasPrefix("LH") })
        #expect(Set(s.items.map(\.destination)).count >= 4)
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(s.items.allSatisfy { LocalDay($0.scheduledOut!, in: berlin) == LocalDay(year: 2026, month: 11, day: 6) })
    }
}
