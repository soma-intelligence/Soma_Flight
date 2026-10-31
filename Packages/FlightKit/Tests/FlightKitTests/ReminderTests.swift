import Foundation
import Synchronization
import Testing
@testable import FlightKit

/// Local reminders (check-in, morning of, leave for the airport), their copy, the Notifications
/// screen's store, and the `update` event kind.
@Suite @MainActor struct ReminderTests {
    nonisolated static let cdg = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", country: "FR",
                             lat: 49.0, lon: 2.55, tz: "Europe/Paris")
    nonisolated static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco", city: "San Francisco", country: "US",
                             lat: 37.6, lon: -122.4, tz: "America/Los_Angeles")
    nonisolated static let lax = Airport(id: "KLAX", iata: "LAX", name: "Los Angeles", city: "Los Angeles", country: "US",
                             lat: 33.9, lon: -118.4, tz: "America/Los_Angeles")
    nonisolated static let lookup: @Sendable (String) -> Airport? = { code in
        [cdg, sfo, lax].first { $0.id == code || $0.iata == code }
    }

    nonisolated static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// AF 84, Paris 22:30 UTC (23:30 local) on 3 Nov to San Francisco.
    static func af84(id: UUID = UUID(uuidString: "0f8fad5b-d9cb-469f-a165-70867728950e")!,
                     out: String = "2026-11-03T22:30:00Z", estimated: String? = nil) -> Flight {
        Flight(id: id, providerId: "AFR84-1", ident: "AF84", originIcao: "LFPG", originIata: "CDG",
               destinationIcao: "KSFO", destinationIata: "SFO", scheduledOut: date(out),
               scheduledIn: date(out).addingTimeInterval(11 * 3600), estimatedOut: estimated.map(date),
               gateOrigin: "K36", terminalOrigin: "2E", status: .scheduled)
    }

    /// UA 1, SFO 16:00 local (00:00 UTC) to LAX: domestic.
    static func domestic(id: UUID = UUID(uuidString: "1f8fad5b-d9cb-469f-a165-70867728950e")!) -> Flight {
        Flight(id: id, providerId: "UAL1-1", ident: "UA1", originIcao: "KSFO", originIata: "SFO",
               destinationIcao: "KLAX", destinationIata: "LAX", scheduledOut: date("2026-11-04T00:00:00Z"),
               scheduledIn: date("2026-11-04T01:30:00Z"), status: .scheduled)
    }

    // MARK: Planner

    @Test func anInternationalFlightGetsThreeRemindersAtTheRightTimes() {
        let plan = ReminderPlanner.plan(for: Self.af84(), origin: Self.cdg, destination: Self.sfo,
                                        now: Self.date("2026-11-01T00:00:00Z"))
        #expect(plan.map(\.kind) == [.checkIn, .morning, .leave])
        #expect(plan[0].fireDate == Self.date("2026-11-02T22:30:00Z"))
        // 7:00 in Paris (UTC+1 in November) on the travel day.
        #expect(plan[1].fireDate == Self.date("2026-11-03T06:00:00Z"))
        #expect(plan[2].fireDate == Self.date("2026-11-03T19:30:00Z"))
        #expect(plan[0].id == "reminder.0f8fad5b-d9cb-469f-a165-70867728950e.check-in")
    }

    @Test func aDomesticFlightLeavesTwoHoursBefore() {
        let plan = ReminderPlanner.plan(for: Self.domestic(), origin: Self.sfo, destination: Self.lax,
                                        now: Self.date("2026-11-01T00:00:00Z"))
        #expect(plan.first { $0.kind == .leave }?.fireDate == Self.date("2026-11-03T22:00:00Z"))
        // 7:00 in San Francisco on 3 Nov local (the flight leaves at 16:00 local).
        #expect(plan.first { $0.kind == .morning }?.fireDate == Self.date("2026-11-03T15:00:00Z"))
        #expect(!ReminderPlanner.isInternational(origin: Self.sfo, destination: Self.lax))
        #expect(ReminderPlanner.isInternational(origin: Self.sfo, destination: nil))
    }

    @Test func remindersFollowTheEstimateButCheckInFollowsTheSchedule() {
        let late = Self.af84(estimated: "2026-11-03T23:30:00Z")
        let plan = ReminderPlanner.plan(for: late, origin: Self.cdg, destination: Self.sfo,
                                        now: Self.date("2026-11-01T00:00:00Z"))
        #expect(plan.first { $0.kind == .checkIn }?.fireDate == Self.date("2026-11-02T22:30:00Z"))
        #expect(plan.first { $0.kind == .leave }?.fireDate == Self.date("2026-11-03T20:30:00Z"))
    }

    @Test func onlyRemindersStillAheadAndNoneOnceGoneOrCanceled() {
        let f = Self.af84()
        let soon = ReminderPlanner.plan(for: f, origin: Self.cdg, destination: Self.sfo,
                                        now: Self.date("2026-11-03T12:00:00Z"))
        #expect(soon.map(\.kind) == [.leave])
        var gone = f
        gone.actualOut = Self.date("2026-11-03T22:40:00Z")
        gone.status = .departed
        #expect(ReminderPlanner.plan(for: gone, origin: Self.cdg, destination: Self.sfo, now: .distantPast).isEmpty)
        var canceled = f
        canceled.status = .canceled
        #expect(ReminderPlanner.plan(for: canceled, origin: Self.cdg, destination: Self.sfo, now: .distantPast).isEmpty)
        var unscheduled = f
        unscheduled.scheduledOut = nil
        #expect(ReminderPlanner.plan(for: unscheduled, origin: Self.cdg, destination: Self.sfo, now: .distantPast).isEmpty)
    }

    @Test func anEarlyFlightSkipsTheMorningSummary() {
        // 8:00 Paris departure: leave at 5:00, so 7:00 would come after it.
        let early = Self.af84(out: "2026-11-03T07:00:00Z")
        let plan = ReminderPlanner.plan(for: early, origin: Self.cdg, destination: Self.sfo, now: .distantPast)
        #expect(plan.map(\.kind) == [.checkIn, .leave])
        // Unknown origin airport: no local morning to aim at.
        #expect(!ReminderPlanner.plan(for: Self.af84(), origin: nil, destination: Self.sfo, now: .distantPast)
            .contains { $0.kind == .morning })
    }

    // MARK: Copy

    @Test func reminderCopyIsShortAndSpecific() {
        let f = Self.af84(estimated: "2026-11-03T22:55:00Z")
        let paris = Self.cdg.timeZone
        let check = ReminderCopy.checkIn(f, departure: f.scheduledOut!, tz: paris, clock: .h24)
        #expect(check.title == "Check-in is open for AF 84")
        #expect(check.body == "AF 84 to SFO leaves CDG tomorrow at 23:30. Check in now to get your boarding pass.")
        let morning = ReminderCopy.morning(f, departure: f.estimatedOut!, tz: paris, arrivalTz: Self.sfo.timeZone,
                                           clock: .h12)
        #expect(morning.title == "AF 84 to SFO today")
        #expect(morning.body == "Running 25m late. Departs CDG at 11:55 PM, terminal 2E, gate K36. Arrives SFO at 1:30 AM.")
        let leave = ReminderCopy.leave(f, departure: f.estimatedOut!, tz: paris, clock: .h24, international: true)
        #expect(leave.title == "Time to leave for CDG")
        #expect(leave.body == "AF 84 departs at 23:55. Aim to be at the airport 3 hours early for an international flight.")
        let home = ReminderCopy.leave(Self.domestic(), departure: Self.domestic().scheduledOut!, tz: Self.sfo.timeZone,
                                      clock: .h12, international: false)
        #expect(home.body == "UA 1 departs at 4:00 PM. Aim to be at the airport 2 hours early for a domestic flight.")
        var bare = Self.af84()
        bare.gateOrigin = nil; bare.terminalOrigin = nil
        #expect(ReminderCopy.morning(bare, departure: bare.scheduledOut!, tz: paris, arrivalTz: nil, clock: .h24).body
            == "Departs CDG at 23:30. Arrives SFO at 10:30.")
        let dashes = CharacterSet(charactersIn: "\u{2013}\u{2014}")
        for t in [check, morning, leave, home] {
            #expect((t.title + t.body).rangeOfCharacter(from: dashes) == nil)
        }
    }

    // MARK: Scheduler

    @Test func followingSchedulesTimesChangeRewritesUnfollowRemoves() async {
        let center = FakeLocalNotificationCenter()
        let s = ReminderScheduler(center: center, lookup: Self.lookup, now: { Self.date("2026-11-01T00:00:00Z") },
                                  clock: { .h24 })
        let f = Self.af84(), g = Self.domestic()
        await s.sync([f, g])
        #expect(center.pending.count == 6)
        #expect(center.adds == 6)
        // Same list again: nothing rewritten.
        await s.sync([f, g])
        #expect(center.adds == 6)
        // A new estimate rewrites the morning summary and the leave reminder of that flight only.
        let late = Self.af84(estimated: "2026-11-03T22:50:00Z")
        await s.sync([late, g])
        #expect(center.adds == 8, "adds \(center.adds)")
        let leave = center.pending[ReminderPlanner.identifier(f.id, .leave)]
        #expect(leave?.fireDate == Self.date("2026-11-03T19:50:00Z"))
        // Unfollow.
        await s.sync([g])
        #expect(Set(center.pending.keys) == Set(ReminderKind.allCases.map { ReminderPlanner.identifier(g.id, $0) }))
    }

    @Test func turningRemindersOffRemovesThemAndOnBringsThemBack() async {
        let center = FakeLocalNotificationCenter()
        center.foreign = ["someone-else"]
        let s = ReminderScheduler(center: center, lookup: Self.lookup, now: { Self.date("2026-11-01T00:00:00Z") },
                                  clock: { .h24 })
        await s.sync([Self.af84()])
        #expect(center.pending.count == 3)
        s.enabled = false
        await s.sync([Self.af84()])
        #expect(center.pending.isEmpty)
        #expect(center.removed.allSatisfy { $0.hasPrefix("reminder.") })
        s.enabled = true
        await s.sync([Self.af84()])
        #expect(center.pending.count == 3)
    }

    @Test func theHomeWiresTheListAndTheRemindersSwitch() async throws {
        let prefs = FakeNotificationPreferencesService(NotificationPreferences(reminders: false))
        var env = try await AppEnvironment.fake()
        env.notificationPreferences = prefs
        let home = HomeModel(env: env)
        let center = FakeLocalNotificationCenter()
        let scheduler = ReminderScheduler(center: center, lookup: env.lookup, clock: { .h24 })
        home.attachReminders(scheduler)
        await home.load()
        #expect(!home.notificationSettings.preferences.reminders)
        #expect(!scheduler.enabled)
        await scheduler.sync(home.followed)
        #expect(center.pending.isEmpty)
        await home.notificationSettings.set(.reminders, true)
        #expect(scheduler.enabled)
        #expect(await prefs.stored.reminders)
        await scheduler.sync(home.followed)
        let upcoming = home.followed.filter { $0.status == .scheduled && ($0.scheduledOut ?? .distantPast) > .now }
        #expect(upcoming.isEmpty || !center.pending.isEmpty)
    }

    // MARK: Notifications screen store

    @Test func aToggleSavesAndAFailedSavePutsItBack() async {
        let service = FakeNotificationPreferencesService()
        let store = NotificationSettingsStore(service: service)
        var heard: [NotificationPreferences] = []
        store.onChange = { heard.append($0) }
        await store.load()
        #expect(store.hasLoaded && store.preferences == .allOn)
        await store.set(.gates, false)
        #expect(!store.preferences.gates)
        #expect(await service.stored.gates == false)
        await service.setNextError(.offline)
        await store.set(.baggage, false)
        #expect(store.preferences.baggage)
        #expect(store.error == .offline)
        #expect(await service.stored.baggage)
        #expect(heard.map(\.baggage) == [true, true, false, true])
        #expect(await service.saves == 1)
    }

    @Test func categoriesCoverEverySwitch() {
        var p = NotificationPreferences.allOn
        for c in NotificationPreferences.Category.allCases {
            #expect(p[c])
            p[c] = false
        }
        #expect(p == NotificationPreferences(delays: false, gates: false, takeoffLanding: false, baggage: false,
                                             cancellations: false, reminders: false))
        #expect(NotificationPreferences.Category.allCases.map(\.title) == [
            "Delays", "Gates and Terminals", "Take-off and Landing", "Baggage", "Cancellations and Diversions", "Reminders",
        ])
    }

    // MARK: Backend shapes

    @Test func preferencesDecodeFromTheTableAndDefaultToAllOn() throws {
        let row = #"[{"delays":false,"gates":true,"takeoff_landing":false,"baggage":true,"cancellations":true,"reminders":false}]"#
        let p = try SupabaseNotificationPreferencesService.decode(Data(row.utf8))
        #expect(p == NotificationPreferences(delays: false, takeoffLanding: false, reminders: false))
        #expect(try SupabaseNotificationPreferencesService.decode(Data("[]".utf8)) == .allOn)
        let encoded = try JSONEncoder().encode(SupabaseNotificationPreferencesService.Row(
            user: UUID(uuidString: "0f8fad5b-d9cb-469f-a165-70867728950e")!, p, at: Self.date("2026-11-01T00:00:00Z")))
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["user_id"] as? String == "0f8fad5b-d9cb-469f-a165-70867728950e")
        #expect(json["takeoff_landing"] as? Bool == false)
        #expect(json["updated_at"] as? String == "2026-11-01T00:00:00Z")
    }

    @Test func updateAndUnknownEventKindsDecodeWithoutATimelineRow() throws {
        let json = #"""
        [{"id":"00000000-0000-4000-8000-000000000001","flight_id":"00000000-0000-4000-8000-0000000000f1",
          "kind":"update","payload":{"changes":{}},"received_at":"2026-11-03T21:00:00.123456+00:00"},
         {"id":"00000000-0000-4000-8000-000000000002","flight_id":"00000000-0000-4000-8000-0000000000f1",
          "kind":"something_new","payload":{},"received_at":"2026-11-03T21:00:00Z"}]
        """#
        let events = try FlightJSON.decoder.decode([FlightEvent].self, from: Data(json.utf8))
        #expect(events.map(\.kind) == [.update, .update])
        #expect(events.allSatisfy { DetailFacts.eventText($0) == nil })
    }
}

/// Pending requests in memory.
final class FakeLocalNotificationCenter: LocalNotificationCenter, @unchecked Sendable {
    private let lock = Mutex(State())
    struct State {
        var pending: [String: PlannedReminder] = [:]
        var foreign: [String] = []
        var adds = 0
        var removed: [String] = []
    }

    var pending: [String: PlannedReminder] {
        get { lock.withLock { $0.pending } }
        set { lock.withLock { $0.pending = newValue } }
    }
    /// Requests of other features, which the scheduler must leave alone.
    var foreign: [String] {
        get { lock.withLock { $0.foreign } }
        set { lock.withLock { $0.foreign = newValue } }
    }
    var adds: Int { lock.withLock { $0.adds } }
    var removed: [String] { lock.withLock { $0.removed } }

    func pendingIdentifiers() async -> [String] { lock.withLock { Array($0.pending.keys) + $0.foreign } }

    func add(_ reminder: PlannedReminder) async throws {
        lock.withLock { $0.pending[reminder.id] = reminder; $0.adds += 1 }
    }

    func remove(identifiers: [String]) async {
        lock.withLock { s in
            for id in identifiers { s.pending[id] = nil; s.foreign.removeAll { $0 == id } }
            s.removed += identifiers
        }
    }
}
