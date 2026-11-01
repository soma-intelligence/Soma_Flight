import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// The export file of the other tracker, the calendar matcher, the plan that sorts what was read into
/// history, follows and left-outs, the waiting list and the Import screen's store.
@MainActor @Suite struct ImportSourcesTests {
    static let directory = AirportDirectory.bundled()
    static let reference = ReferenceData.bundled()
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)
    static let isAirport: (String) -> Bool = { directory.lookup($0) != nil || EmailFlightReader.plausibleAirport($0) }

    static func iso(_ s: String) -> Date { FlightJSON.parse(s)! }

    static func context(existing: [PastFlight] = [], followed: [Flight] = [], waiting: [UpcomingFlight] = []) -> FlightImportPlan.Context {
        FlightImportPlan.Context(existing: existing, followed: followed, waiting: waiting, airport: directory.lookup,
                                 reference: reference, now: now)
    }

    // MARK: Export file

    /// The header and two rows as the export writes them (all 33 columns).
    static let header = "Date,Airline,Flight,From,To,Dep Terminal,Dep Gate,Arr Terminal,Arr Gate,Canceled,Diverted To,Gate Departure (Scheduled),Gate Departure (Actual),Take off (Scheduled),Take off (Actual),Landing (Scheduled),Landing (Actual),Gate Arrival (Scheduled),Gate Arrival (Actual),Aircraft Type Name,Tail Number,PNR,Seat,Seat Type,Cabin Class,Flight Reason,Notes,Flight Flighty ID,Airline Flighty ID,Departure Airport Flighty ID,Arrival Airport Flighty ID,Diverted To Airport Flighty ID,Aircraft Type Flighty ID"
    static let fullExport = header + """

    2025-03-14,AFR,84,CDG,SFO,2E,K41,I,,false,,2025-03-14T10:15,2025-03-14T10:31,,,,,2025-03-14T12:40,2025-03-14T12:52,Boeing 777-300ER,F-GSQA,QX4T7B,32A,WINDOW,PREMIUM_ECONOMY,LEISURE,"Upgraded, nice crew",4256f3d8-2653-4977-962c-766c6d1e3041,8508d82c-f03a-4c99-88d8-46ede5aceb6d,1a0ff314-4db9-43eb-aef0-59d40b78505b,7da61aa8-3d56-411b-8be5-50a198e86c60,,2c9e7893-7be6-41cf-8cd1-56ebe0491126
    2024-07-01,UAL,990,SFO,LHR,,,,,true,,2024-07-01T17:30,,,,,,2024-07-02T11:45,,,,,,,ECONOMY,BUSINESS,,a,b,c,d,,e
    2024-08-02,UAL,901,SFO,LHR,,,,,false,JFK,2024-08-02T17:30,2024-08-02T17:40,,,,,2024-08-03T11:45,,,,,,AISLE,FIRST,CREW,,a,b,c,d,f,e
    ,AFR,85,SFO,CDG,,,,,false,,,,,,,,,,,,,,,,,,,,,,,
    2024-13-01,AFR,85,SFO,CDG,,,,,false,,,,,,,,,,,,,,,,,,,,,,,
    2026-11-20,AFR,83,SFO,CDG,,,,,false,,2026-11-20T15:35,,,,,,2026-11-21T11:05,,,,,40J,,BUSINESS,LEISURE,,,,,,,
    """

    @Test func exportRowsRead() throws {
        let rows = try FlightyImport.read(Data(Self.fullExport.utf8))
        #expect(rows.count == 6)
        let f = try rows[0].flight.get()
        #expect(f.airline == "AFR" && f.number == "84" && f.ident == "AFR84")
        #expect(f.origin == "CDG" && f.destination == "SFO")
        #expect(f.day == LocalDay(year: 2025, month: 3, day: 14))
        #expect(f.departureTime?.description == "10:31")
        #expect(f.arrivalTime?.description == "12:52")
        #expect(f.delayMinutes == 12)
        #expect(f.aircraft == "Boeing 777-300ER")
        #expect(f.registration == "F-GSQA")
        #expect(f.bookingReference == "QX4T7B")
        #expect(f.seat == "32A" && f.seatPosition == "WINDOW" && f.cabin == "PREMIUM_ECONOMY" && f.reason == "LEISURE")
        #expect(f.notes == "Upgraded, nice crew")
        #expect(try rows[1].flight.get().canceled)
        #expect(try rows[2].flight.get().divertedTo == "JFK")
        #expect(rows[3].flight == .failure(.noDate))
        #expect(rows[4].flight == .failure(.badDate("2024-13-01")))
    }

    @Test func exportNeedsItsColumns() {
        #expect(throws: FlightyImport.Failure.missingColumns(["Airline", "Flight"])) {
            try FlightyImport.read(Data("date,from,to\n2024-01-01,SFO,LAX".utf8))
        }
        #expect(throws: FlightyImport.Failure.empty) { try FlightyImport.read(Data(Self.header.utf8)) }
        #expect(FlightyImport.recognizes(Data(Self.fullExport.utf8)))
        #expect(!FlightyImport.recognizes(Data(PastFlight.csvHeader.utf8)))
    }

    @Test func exportPlannedIntoHistoryAndFollows() throws {
        let rows = try FlightyImport.read(Data(Self.fullExport.utf8))
        let items = rows.compactMap { r in (try? r.flight.get()).map { (label: "Row \(r.row)", flight: $0) } }
        let plan = FlightImportPlan.plan(items, context: Self.context())
        guard case .addPast(let af) = plan[0].action else { Issue.record("not past"); return }
        #expect(af.ident == "AF84")
        #expect(af.airline == "AFR")
        #expect(af.originIcao == "LFPG" && af.destinationIcao == "KSFO")
        #expect(af.aircraftType == "B77W")
        #expect(af.seatClass == .premiumEconomy && af.seatPosition == .window && af.reason == .personal)
        #expect(af.delayMinutes == 12)
        #expect(af.source == .import)
        #expect(af.bookingCode == "QX4T7B")
        // 10:31 Paris time.
        #expect(af.date == Self.iso("2025-03-14T09:31:00Z"))
        // Gate to gate: 10:31 CET to 12:52 PDT.
        #expect(af.blockMinutes == 621)
        #expect(PastFlightRules.problems(af, now: Self.now).isEmpty)
        guard case .addPast(let ua) = plan[1].action else { Issue.record("not past"); return }
        #expect(ua.status == .canceled && ua.ident == "UA990")
        guard case .addPast(let diverted) = plan[2].action else { Issue.record("not past"); return }
        #expect(diverted.status == .diverted && diverted.reason == .crew && diverted.seatClass == .first)
        #expect(plan[2].warnings == ["Diverted to JFK"])
        guard case .follow(let up) = plan[3].action else { Issue.record("not upcoming"); return }
        #expect(up.ident == "AF83")
        #expect(up.details.seat == "40J" && up.details.seatClass == .business && up.details.reason == .personal)
        #expect(up.origin == "KSFO")
    }

    // MARK: Plan

    @Test func duplicatesOfHistoryFollowsWaitingAndRows() {
        let existing = PastFlight(date: Self.iso("2025-03-14T09:31:00Z"), ident: "AF84", originIcao: "LFPG", destinationIcao: "KSFO",
                                  distanceKm: 8_954)
        let followed = Flight(providerId: "p", ident: "UA990", originIcao: "KSFO", originIata: "SFO", destinationIcao: "LFPG",
                              scheduledOut: Self.iso("2026-11-02T22:00:00Z"))
        let waiting = UpcomingFlight(ident: "AF83", day: LocalDay(year: 2026, month: 12, day: 1))
        let past = ImportedFlight(airline: "AF", number: "84", origin: "CDG", destination: "SFO", day: LocalDay(year: 2025, month: 3, day: 14))
        let items: [(label: String, flight: ImportedFlight)] = [
            ("a", past),
            ("b", ImportedFlight(airline: "UAL", number: "990", origin: "SFO", destination: "CDG", day: LocalDay(year: 2026, month: 11, day: 2))),
            ("c", ImportedFlight(airline: "AFR", number: "0083", day: LocalDay(year: 2026, month: 12, day: 1))),
            ("d", ImportedFlight(airline: "BA", number: "286", origin: "SFO", destination: "LHR", day: LocalDay(year: 2026, month: 12, day: 9))),
            ("e", ImportedFlight(airline: "BA", number: "286", day: LocalDay(year: 2026, month: 12, day: 9))),
            ("f", ImportedFlight(origin: "SFO", destination: "LHR", day: LocalDay(year: 2026, month: 12, day: 10))),
            ("g", ImportedFlight(airline: "BA", number: "286", day: LocalDay(year: 2026, month: 12, day: 10), canceled: true)),
            ("h", ImportedFlight(airline: "BA", number: "1", origin: "SFO", day: LocalDay(year: 2026, month: 1, day: 10))),
        ]
        let plan = FlightImportPlan.plan(items, context: Self.context(existing: [existing], followed: [followed], waiting: [waiting]))
        #expect(plan[0].action == .duplicate("Already in your history"))
        #expect(plan[1].action == .duplicate("Already following"))
        #expect(plan[2].action == .duplicate("Already waiting to be followed"))
        guard case .follow = plan[3].action else { Issue.record("d"); return }
        #expect(plan[4].action == .duplicate("Listed twice"))
        #expect(plan[5].action == .unusable("No flight number to follow"))
        #expect(plan[6].action == .unusable("Canceled"))
        #expect(plan[7].action == .unusable("No arrival airport"))
        #expect(plan.filter(\.isActionable).count == 1)
    }

    @Test func badOptionalValuesAreLeftOutWithAWarning() {
        let f = ImportedFlight(airline: "AF", number: "84", origin: "CDG", destination: "SFO",
                               day: LocalDay(year: 2024, month: 5, day: 1), seat: "aisle please", cabin: "Steerage")
        let plan = FlightImportPlan.plan([("x", f)], context: Self.context())
        guard case .addPast(let p) = plan[0].action else { Issue.record("past"); return }
        #expect(p.seat == nil && p.seatClass == nil)
        #expect(plan[0].warnings == ["Seat \u{201C}aisle please\u{201D} left out", "Class \u{201C}Steerage\u{201D} left out"])
    }

    // MARK: Calendar

    static func event(_ title: String, location: String = "", notes: String = "", start: String, hours: Double = 3,
                      allDay: Bool = false, url: URL? = nil, calendar: String = "home") -> CalendarEventSnapshot {
        let s = iso(start)
        return CalendarEventSnapshot(id: title + start, title: title, location: location, notes: notes, url: url, start: s,
                                     end: s.addingTimeInterval(hours * 3600), isAllDay: allDay,
                                     timeZone: TimeZone(identifier: "America/Los_Angeles"), calendarId: calendar,
                                     calendarTitle: calendar == "home" ? "Home" : "Soma Flight")
    }

    /// Titles as airlines, booking sites, mail apps and people write them.
    @Test(arguments: [
        ("AF 84 SFO → CDG", "", "AF84", "SFO", "CDG", CalendarFlightMatcher.Strength.strong),
        ("Flight to Paris (AF 84)", "San Francisco SFO", "AF84", "SFO", nil, .likely),
        ("✈ UA990 SFO-CDG", "", "UA990", "SFO", "CDG", .strong),
        ("Flight: BA 286 San Francisco (SFO) to London (LHR)", "", "BA286", "SFO", "LHR", .strong),
        ("Vol AF0084 CDG-SFO", "", "AF84", "CDG", "SFO", .strong),
        ("Flug LH 454 nach SFO", "Frankfurt (FRA)", "LH454", "FRA", nil, .likely),
        ("Delta 405", "JFK Terminal 4", "", "JFK", nil, .likely),
        ("DL405 JFK to LAX", "", "DL405", "JFK", "LAX", .strong),
        ("Flight SFO → JFK", "", "", "SFO", "JFK", .likely),
        ("B6 1234 JFK/BOS", "", "B61234", "JFK", "BOS", .strong),
        ("U2 8017 London Gatwick (LGW) - Geneva (GVA)", "", "U28017", "LGW", "GVA", .strong),
        ("Departure AA 100", "", "AA100", nil, nil, .likely),
    ] as [(String, String, String, String?, String?, CalendarFlightMatcher.Strength)])
    func titlesThatAreFlights(title: String, location: String, ident: String, origin: String?, destination: String?,
                              strength: CalendarFlightMatcher.Strength) throws {
        let matches = CalendarFlightMatcher.matches([Self.event(title, location: location, start: "2026-05-01T17:00:00Z")],
                                                    isAirport: Self.isAirport, airport: Self.directory.lookup)
        if title == "Delta 405" {
            // A number spelled with the airline's name is not a flight number.
            #expect(matches.isEmpty)
            return
        }
        let m = try #require(matches.first, "\(title)")
        #expect((m.flight.ident ?? "") == ident)
        #expect(m.flight.origin == origin)
        #expect(m.flight.destination == destination)
        #expect(m.strength == strength)
        #expect(m.flight.evidence.first?.contains(title.prefix(20)) == true)
    }

    @Test(arguments: ["Lunch with Ana", "Team sync Q3 2026", "Call AF re refund", "Room B2 12", "Gym 6:30",
                      "Dentist (Dr. ABC)", "SFO", "Pick up kids", "Watch F1 2026", "Flight school open day"])
    func titlesThatAreNot(title: String) {
        let matches = CalendarFlightMatcher.matches([Self.event(title, start: "2026-05-01T17:00:00Z")],
                                                    isAirport: Self.isAirport, airport: Self.directory.lookup)
        #expect(matches.isEmpty, "\(title)")
    }

    @Test func notesCarryTheNumberWhenTheTitleSaysFlight() throws {
        let e = Self.event("Flight to London", notes: "Confirmation code: XJ7K2P\nBA 286 SFO -> LHR\nSeat 32K",
                           start: "2026-03-14T02:40:00Z", hours: 10.25)
        let m = try #require(CalendarFlightMatcher.matches([e], isAirport: Self.isAirport, airport: Self.directory.lookup).first)
        #expect(m.flight.ident == "BA286")
        #expect(m.flight.bookingReference == "XJ7K2P")
        #expect(m.flight.seat == "32K")
        // 02:40 UTC is 19:40 the day before in San Francisco: the day is the origin's.
        #expect(m.flight.day == LocalDay(year: 2026, month: 3, day: 13))
        #expect(m.flight.departureTime?.description == "19:40")
    }

    @Test func numberInNotesAloneIsNotEnough() {
        let e = Self.event("Planning", notes: "Bring AB 12 forms", start: "2026-03-14T02:40:00Z")
        #expect(CalendarFlightMatcher.matches([e], isAirport: Self.isAirport).isEmpty)
    }

    @Test func ownSyncedEventsSkipped() {
        let events = [
            Self.event("AF 84 Paris to San Francisco", notes: "Departs CDG.\nKept up to date by Soma Flight.",
                       start: "2026-05-01T08:00:00Z"),
            Self.event("UA 990 SFO → CDG", start: "2026-05-02T08:00:00Z", url: URL(string: "somaflight://flight/abc")),
            Self.event("BA 286 SFO → LHR", start: "2026-05-03T08:00:00Z", calendar: "soma"),
            Self.event("LH 454 FRA → SFO", start: "2026-05-04T08:00:00Z"),
        ]
        let m = CalendarFlightMatcher.matches(events, ownCalendarId: "soma", isAirport: Self.isAirport)
        #expect(m.map { $0.flight.ident } == ["LH454"])
    }

    @Test func allDayEventHasADayNoTime() throws {
        let e = CalendarEventSnapshot(id: "x", title: "Flight AF 84 CDG → SFO", start: Self.iso("2026-05-01T07:00:00Z"),
                                      end: Self.iso("2026-05-02T07:00:00Z"), isAllDay: true)
        let m = try #require(CalendarFlightMatcher.matches([e], isAirport: Self.isAirport, airport: Self.directory.lookup,
                                                           deviceZone: TimeZone(identifier: "America/Los_Angeles")!).first)
        #expect(m.flight.day == LocalDay(year: 2026, month: 5, day: 1))
        #expect(m.flight.departureTime == nil)
        #expect(m.flight.departure == nil)
    }

    // MARK: Follow

    actor StubFlights: FlightService {
        var found: [Flight] = []
        var lookupError: APIError?
        var lookups: [FlightQuery] = []
        var follows: [Flight.ID] = []
        var saved: [Flight.ID: FollowDetails] = [:]

        init(found: [Flight] = [], lookupError: APIError? = nil) { self.found = found; self.lookupError = lookupError }

        func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight] {
            lookups.append(query)
            if let lookupError { throw lookupError }
            guard !found.isEmpty else { throw .notFound }
            return found
        }
        func followed() async throws(APIError) -> [Flight] { [] }
        func follow(_ id: Flight.ID, notify: Bool) async throws(APIError) { follows.append(id) }
        func unfollow(_ id: Flight.ID) async throws(APIError) {}
        func notifies(_ id: Flight.ID) async throws(APIError) -> Bool? { nil }
        func followDetails(_ id: Flight.ID) async throws(APIError) -> FollowDetails? { nil }
        func saveFollowDetails(_ id: Flight.ID, _ details: FollowDetails) async throws(APIError) { saved[id] = details }
        func flight(_ id: Flight.ID) async throws(APIError) -> Flight { throw .notFound }
        func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent] { [] }
        nonisolated func updates(for ids: [Flight.ID]) -> AsyncStream<Flight> { AsyncStream { $0.finish() } }
    }

    static let af83 = Flight(providerId: "AFR83-1", ident: "AF83", originIcao: "KSFO", originIata: "SFO", destinationIcao: "LFPG",
                             destinationIata: "CDG", scheduledOut: iso("2026-11-01T22:35:00Z"))
    static let utc = TimeZone(identifier: "UTC")!

    @Test func followsWithinReachAndNotesDetails() async {
        let svc = StubFlights(found: [Self.af83])
        let u = UpcomingFlight(ident: "AFR83", day: LocalDay(year: 2026, month: 11, day: 1), origin: "SFO", destination: "CDG",
                               details: FollowDetails(seat: "40J", bookingCode: "QX4T7B"))
        let out = await ImportFollower.follow(u, flights: svc, reference: Self.reference, airport: Self.directory.lookup,
                                              now: Self.now, zone: Self.utc)
        #expect(out == .followed(Self.af83))
        #expect(await svc.follows == [Self.af83.id])
        #expect(await svc.saved[Self.af83.id]?.seat == "40J")
    }

    @Test func waitsWhenTooFarAndLetsGoWhenGone() async {
        let svc = StubFlights(found: [Self.af83])
        let far = UpcomingFlight(ident: "AF83", day: LocalDay(year: 2026, month: 11, day: 20))
        #expect(await ImportFollower.follow(far, flights: svc, reference: Self.reference, airport: Self.directory.lookup,
                                            now: Self.now, zone: Self.utc) == .later)
        #expect(await svc.lookups.isEmpty)
        let gone = UpcomingFlight(ident: "AF83", day: LocalDay(year: 2026, month: 10, day: 20))
        #expect(await ImportFollower.follow(gone, flights: svc, reference: Self.reference, airport: Self.directory.lookup,
                                            now: Self.now, zone: Self.utc) == .gone)
        // Another day's flight with that number is not this one.
        let other = UpcomingFlight(ident: "AF83", day: LocalDay(year: 2026, month: 10, day: 31))
        #expect(await ImportFollower.follow(other, flights: svc, reference: Self.reference, airport: Self.directory.lookup,
                                            now: Self.now, zone: Self.utc) == .notFound)
        let offline = StubFlights(lookupError: .offline)
        #expect(await ImportFollower.follow(other, flights: offline, reference: Self.reference, airport: Self.directory.lookup,
                                            now: Self.now, zone: Self.utc) == .failed(.offline))
    }

    @Test func waitingListPersistsPerAccount() {
        let defaults = UserDefaults(suiteName: "import-tests-\(UUID().uuidString)")!
        let a = UUID(), b = UUID()
        let q = FollowLaterQueue(owner: a, defaults: defaults)
        let u = UpcomingFlight(ident: "AF83", day: LocalDay(year: 2026, month: 12, day: 1))
        q.add([u, u])
        #expect(q.items == [u])
        #expect(FollowLaterQueue(owner: a, defaults: defaults).items == [u])
        q.adopt(owner: b)
        #expect(q.items.isEmpty)
        q.adopt(owner: a)
        q.remove(u.id)
        #expect(FollowLaterQueue(owner: a, defaults: defaults).items.isEmpty)
    }

    // MARK: Store

    actor MemoryHistory: HistoryService {
        var past: [PastFlight] = []
        func pastFlights() async throws(APIError) -> [PastFlight] { past }
        func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
        func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] { past += flights; return flights }
    }

    static func store(flights: StubFlights = StubFlights(), calendar: FakeCalendarStore? = nil,
                      history: MemoryHistory = MemoryHistory()) -> ImportStore {
        ImportStore(passport: PassportStore(history: history, airports: directory.lookup), flights: flights,
                    queue: FollowLaterQueue(owner: nil, defaults: nil),
                    calendar: calendar.map { CalendarSync(store: $0, lookup: directory.lookup, defaults: nil) },
                    airport: directory.lookup, reference: reference, now: { now })
    }

    @Test func exportFileAddsAndQueues() async throws {
        let history = MemoryHistory()
        let s = Self.store(history: history)
        s.readFlighty(Data(Self.fullExport.utf8), name: "flights.csv")
        let review = try #require(s.review)
        #expect(review.past.count == 3 && review.upcoming.count == 1)
        #expect(review.skipped.map(\.label) == ["Row 5", "Row 6"])
        #expect(s.commitTitle == "Import 3, Follow 1")
        s.toggle(review.past[1].id)
        #expect(s.commitTitle == "Import 2, Follow 1")
        await s.commit()
        guard case .done(let summary) = s.phase else { Issue.record("not done"); return }
        #expect(summary.added == 2 && summary.later == 1)
        #expect(summary.message == "Added 2 flights to your history. 1 flight will be followed 2 days before it leaves.")
        #expect(await history.past.count == 2)
        #expect(s.queue.items.map(\.ident) == ["AF83"])
        // Reading the file again finds them all there.
        s.readFlighty(Data(Self.fullExport.utf8))
        #expect(s.review?.candidates.filter(\.isActionable).count == 1)
    }

    @Test func calendarAsksOnlyWhenStartedAndSkipsLikelyTicks() async throws {
        let cal = FakeCalendarStore(access: .notDetermined, grant: .full)
        cal.external = [
            Self.event("AF 84 CDG → SFO", start: "2026-03-14T09:15:00Z"),
            Self.event("Flight to Paris (UA 990)", location: "SFO", start: "2026-04-14T09:15:00Z"),
            Self.event("Lunch", start: "2026-04-15T09:15:00Z"),
            Self.event("BA 286 SFO → LHR", start: "2026-11-20T03:40:00Z"),
        ]
        let s = Self.store(calendar: cal)
        #expect(cal.access == .notDetermined)
        await s.scanCalendar()
        #expect(cal.access == .full)
        let review = try #require(s.review)
        #expect(review.candidates.count == 3)
        #expect(review.past.count == 1)
        #expect(review.upcoming.count == 1)
        // The likely one (no arrival airport) cannot go to the history and is left out.
        #expect(review.left.count == 1)
        #expect(s.selected.count == 2)
    }

    @Test func calendarRefusedSaysHow() async {
        let s = Self.store(calendar: FakeCalendarStore(access: .notDetermined, grant: .denied))
        await s.scanCalendar()
        guard case .failed(.calendar, let message) = s.phase else { Issue.record("not failed"); return }
        #expect(message.contains("Settings"))
    }

    @Test func emailFollowsWithinReachNow() async throws {
        let svc = StubFlights(found: [Self.af83])
        let s = Self.store(flights: svc)
        s.readEmail("""
        Booking reference: QX4T7B
        Sun 1 Nov 2026
        AF 83  San Francisco (SFO) 15:35 -> Paris (CDG) 11:05
        Seat 40J
        """)
        #expect(s.review?.upcoming.count == 1)
        await s.commit()
        guard case .done(let summary) = s.phase else { Issue.record("not done"); return }
        #expect(summary.followed == ["AF83"])
        #expect(await svc.saved[Self.af83.id]?.bookingCode == "QX4T7B")
    }

    @Test func homeFollowsWaitingFlightsAsTheyComeWithinReach() async throws {
        var env = try await AppEnvironment.fake(now: Self.now)
        let svc = StubFlights(found: [Self.af83])
        env.flights = svc
        let home = HomeModel(env: env)
        let soon = UpcomingFlight(ident: "AF83", day: LocalDay(Self.af83.scheduledOut!, in: Self.directory.lookup("KSFO")!.timeZone))
        let far = UpcomingFlight(ident: "AF85", day: LocalDay(year: 2027, month: 1, day: 5))
        let lost = UpcomingFlight(ident: "AF87", day: LocalDay(year: 2026, month: 10, day: 1))
        home.followLater.add([soon, far, lost])
        await home.followWaiting(now: Self.now)
        #expect(await svc.follows == [Self.af83.id])
        #expect(home.followLater.items == [far])
        #expect(home.toast == "Following AF 83")
    }

    @Test func sharedEmailOpensTheImportScreen() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake(now: Self.now))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ImportInbox(directory: dir)
        inbox.put(.init(name: "Booking.eml", text: "Sun 14 Mar 2027\nAF 84 Paris (CDG) 10:15 -> San Francisco (SFO) 12:40"))
        home.takeSharedEmails(from: inbox)
        #expect(home.showImport)
        #expect(home.imports.review?.upcoming.count == 1)
        #expect(!inbox.hasItems)
    }

    @Test func emailWithoutFlightsFails() {
        let s = Self.store()
        s.readEmail("Hello, see you at lunch.")
        guard case .failed(.email, _) = s.phase else { Issue.record("not failed"); return }
    }
}
