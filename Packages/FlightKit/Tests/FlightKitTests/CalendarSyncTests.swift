import Foundation
import Testing
@testable import FlightKit

/// Calendar sync: the event a flight becomes, and the sync's create, update, move, dedupe and remove
/// rules on a fake event store.
@Suite @MainActor struct CalendarSyncTests {
    typealias R = ReminderTests

    // MARK: Builder

    @Test func aFlightBecomesOneEventFromDepartureToArrival() throws {
        let f = R.af84()
        let d = try #require(CalendarEventBuilder.draft(for: f, origin: R.cdg, destination: R.sfo,
                                                        details: FollowDetails(seat: "32A", bookingCode: "ABC123")))
        #expect(d.title == "AF 84 Paris to San Francisco")
        #expect(d.location == "Paris Charles de Gaulle (CDG)")
        #expect(d.latitude == 49.0 && d.longitude == 2.55)
        #expect(d.start == R.date("2026-11-03T22:30:00Z"))
        #expect(d.end == R.date("2026-11-04T09:30:00Z"))
        #expect(d.timeZone.identifier == "Europe/Paris")
        #expect(d.url.absoluteString == "somaflight://flight/0f8fad5b-d9cb-469f-a165-70867728950e")
        #expect(d.notes == """
            Departs CDG at 23:30 Paris time, terminal 2E, gate K36.
            Arrives SFO at 01:30 San Francisco time.
            Seat 32A. Booking code ABC123.
            Kept up to date by Soma Flight.
            """)
        let dashes = CharacterSet(charactersIn: "\u{2013}\u{2014}")
        #expect((d.title + d.notes).rangeOfCharacter(from: dashes) == nil)
    }

    @Test func theEventFollowsTheBestTimesAndTheStatus() throws {
        var f = R.af84(estimated: "2026-11-03T23:00:00Z")
        f.estimatedIn = R.date("2026-11-04T10:05:00Z")
        f.status = .canceled
        let d = try #require(CalendarEventBuilder.draft(for: f, origin: R.cdg, destination: R.sfo, details: nil, clock: .h12))
        #expect(d.start == R.date("2026-11-03T23:00:00Z"))
        #expect(d.end == R.date("2026-11-04T10:05:00Z"))
        #expect(d.title == "Canceled: AF 84 Paris to San Francisco")
        #expect(d.notes.hasPrefix("This flight is canceled.\nDeparts CDG at 12:00 AM Paris time"))
        #expect(!d.notes.contains("Seat"))
    }

    @Test func unknownAirportsAndMissingTimes() throws {
        var f = R.af84()
        f.scheduledIn = nil
        let d = try #require(CalendarEventBuilder.draft(for: f, origin: nil, destination: nil, details: nil))
        #expect(d.title == "AF 84 CDG to SFO")
        #expect(d.location == "CDG")
        #expect(d.latitude == nil)
        #expect(d.end == d.start.addingTimeInterval(3600))
        f.scheduledOut = nil
        #expect(CalendarEventBuilder.draft(for: f, origin: R.cdg, destination: R.sfo, details: nil) == nil)
    }

    // MARK: Sync

    static func sync(_ store: FakeCalendarStore, defaults: UserDefaults? = nil,
                     details: @escaping @Sendable (Flight.ID) async -> FollowDetails? = { _ in nil }) -> CalendarSync {
        CalendarSync(store: store, lookup: R.lookup, details: details, clock: { .h24 }, defaults: defaults)
    }

    @Test func turningItOnAsksMakesTheCalendarAndAddsEveryFlight() async throws {
        let store = FakeCalendarStore()
        let s = Self.sync(store)
        await s.sync([R.af84(), R.domestic()])
        #expect(store.events.isEmpty, "nothing before the switch")
        await s.setEnabled(true)
        await s.sync([R.af84(), R.domestic()])
        #expect(s.access == .full && s.isEnabled)
        let made = try #require(store.all.first { $0.title == "Soma Flight" })
        #expect(s.calendarId == made.id && s.appCalendarId == made.id)
        #expect(store.events.count == 2 && store.creates == 2)
        #expect(store.events.values.allSatisfy { $0.calendarId == made.id })
        // The same list again writes nothing.
        await s.sync([R.af84(), R.domestic()])
        #expect(store.creates == 2 && store.updates == 0)
    }

    @Test func aChangeUpdatesTheSameEventAndUnfollowRemovesIt() async throws {
        let store = FakeCalendarStore()
        let s = Self.sync(store)
        await s.setEnabled(true)
        let f = R.af84(), g = R.domestic()
        await s.sync([f, g])
        var moved = f
        moved.gateOrigin = "L22"
        moved.estimatedOut = R.date("2026-11-03T23:10:00Z")
        await s.sync([moved, g])
        #expect(store.creates == 2 && store.updates == 1)
        let event = try #require(store.events.values.first { $0.draft.url == FlightLink.url(for: f.id) })
        #expect(event.draft.notes.contains("gate L22"))
        #expect(event.draft.start == R.date("2026-11-03T23:10:00Z"))
        var canceled = moved
        canceled.status = .canceled
        await s.sync([canceled, g])
        #expect(store.events.values.contains { $0.draft.title == "Canceled: AF 84 Paris to San Francisco" })
        #expect(store.events.count == 2 && store.creates == 2)
        await s.sync([g])
        #expect(store.events.count == 1 && store.removals == 1)
        #expect(s.eventCount == 1)
    }

    @Test func aRelaunchNeverDuplicatesAndADeletedEventComesBackOnce() async throws {
        let defaults = try #require(UserDefaults(suiteName: "calendar-\(UUID().uuidString)"))
        let store = FakeCalendarStore()
        let first = Self.sync(store, defaults: defaults)
        await first.setEnabled(true)
        await first.sync([R.af84(), R.domestic()])
        // A new launch reads the kept identifiers.
        let again = Self.sync(store, defaults: defaults)
        #expect(again.isEnabled)
        await again.sync([R.af84(), R.domestic()])
        #expect(store.creates == 2 && store.updates == 0)
        // Deleted in the Calendar app: the next sync adds it again, once.
        let id = try #require(store.events.first { $0.value.draft.url == FlightLink.url(for: R.af84().id) }?.key)
        store.deleteEvent(id)
        await again.sync([R.af84(), R.domestic()])
        await again.sync([R.af84(), R.domestic()])
        #expect(store.creates == 3 && store.events.count == 2)
    }

    @Test func choosingAnotherCalendarMovesTheEvents() async {
        let store = FakeCalendarStore()
        let s = Self.sync(store)
        await s.setEnabled(true)
        await s.sync([R.af84()])
        s.choose(calendar: "work")
        await s.sync([R.af84()])
        #expect(store.events.count == 1 && store.creates == 1 && store.updates == 1)
        #expect(store.events.values.first?.calendarId == "work")
    }

    @Test func turningItOffRemovesEveryEvent() async {
        let store = FakeCalendarStore()
        let s = Self.sync(store)
        await s.setEnabled(true)
        await s.sync([R.af84(), R.domestic()])
        await s.setEnabled(false)
        await s.sync([R.af84(), R.domestic()])
        #expect(store.events.isEmpty && store.removals == 2)
        #expect(!s.isEnabled && s.eventCount == 0)
    }

    @Test func refusedAccessLeavesItOffAndTouchesNothing() async {
        let store = FakeCalendarStore(grant: .denied)
        let s = Self.sync(store)
        await s.setEnabled(true)
        await s.sync([R.af84()])
        #expect(s.access == .denied && !s.isEnabled)
        #expect(store.events.isEmpty && store.all.count == 2)
        let writeOnly = FakeCalendarStore(grant: .writeOnly)
        let w = Self.sync(writeOnly)
        await w.setEnabled(true)
        #expect(w.access == .writeOnly && !w.isEnabled)
    }

    @Test func aDeletedCalendarIsReportedAndAPickFixesIt() async throws {
        let store = FakeCalendarStore()
        let s = Self.sync(store)
        await s.setEnabled(true)
        await s.sync([R.af84()])
        store.deleteCalendar(try #require(s.calendarId))
        await s.sync([R.af84()])
        #expect(s.calendarMissing)
        s.choose(calendar: "home")
        await s.sync([R.af84()])
        #expect(!s.calendarMissing)
        #expect(store.events.values.map(\.calendarId) == ["home"])
    }

    @Test func seatAndBookingCodeAreAskedOnceInAWhile() async throws {
        let store = FakeCalendarStore()
        let calls = CalendarCallCounter()
        let s = Self.sync(store) { _ in
            await calls.bump()
            return FollowDetails(seat: "12A", bookingCode: "XYZ789")
        }
        await s.setEnabled(true)
        await s.sync([R.af84()])
        await s.sync([R.af84()])
        #expect(await calls.value == 1)
        #expect(store.events.values.first?.draft.notes.contains("Seat 12A. Booking code XYZ789.") == true)
    }

    @Test func theHomeFeedsTheList() async throws {
        let env = try await AppEnvironment.fake()
        let home = HomeModel(env: env)
        let store = FakeCalendarStore()
        let s = CalendarSync(store: store, lookup: env.lookup, clock: { .h24 }, defaults: nil)
        home.attachCalendar(s)
        await s.setEnabled(true)
        await home.load()
        await s.idle()
        let dated = home.followed.filter { $0.scheduledOut != nil || $0.estimatedOut != nil || $0.actualOut != nil }
        #expect(store.events.count == dated.count)
        #expect(!dated.isEmpty)
    }
}

actor CalendarCallCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
