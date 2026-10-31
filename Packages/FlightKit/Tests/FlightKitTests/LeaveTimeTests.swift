import Foundation
import Testing
@testable import FlightKit

/// The computed leave time: its arithmetic, every fallback to the fixed rule, the estimator that
/// measures the drive and the queue, and the leave reminder that uses it.
@Suite @MainActor struct LeaveTimeTests {
    typealias R = ReminderTests
    static let wide = AircraftType(id: "B77W", family: .b777, manufacturer: "Boeing", name: "777-300ER")
    static let narrow = AircraftType(id: "A320", family: .a320, manufacturer: "Airbus", name: "A320")

    static func measure(drive: Double = 35, standard: Int? = 20, precheck: Int? = 5) -> LeaveTimeMeasure {
        LeaveTimeMeasure(drive: drive * 60, standardMinutes: standard, precheckMinutes: precheck, securityIsLive: false,
                         measuredAt: R.date("2026-11-03T18:00:00Z"))
    }

    static func plan(_ f: Flight, origin: Airport? = R.cdg, destination: Airport? = R.sfo,
                     aircraft: AircraftType? = wide, measure: LeaveTimeMeasure? = measure(),
                     precheck: Bool = false) -> LeaveTime? {
        LeaveTimePlanner.plan(for: f, origin: origin, destination: destination, aircraft: aircraft, measure: measure,
                              precheck: precheck)
    }

    // MARK: Planner

    @Test func aWideBodyInternationalFlightCountsBackFromBoarding() throws {
        // AF 84 leaves at 22:30 UTC: boarding 21:50, less 45m bags, 20m security, 35m drive.
        let t = try #require(Self.plan(R.af84()))
        let b = try #require(t.breakdown)
        #expect(b.boardingAt == R.date("2026-11-03T21:50:00Z"))
        #expect(b.boardingLead == 40 * 60 && b.wideBody)
        #expect(b.bagDrop == 45 * 60)
        #expect(b.securityMinutes == 20 && !b.precheck)
        #expect(t.leaveAt == R.date("2026-11-03T20:10:00Z"))
        #expect(t.international && t.isComputed)
    }

    @Test func preCheckUsesItsLaneAndFallsBackToStandardWithoutOne() throws {
        let fast = try #require(Self.plan(R.af84(), precheck: true))
        #expect(fast.breakdown?.securityMinutes == 5 && fast.breakdown?.precheck == true)
        #expect(fast.leaveAt == R.date("2026-11-03T20:25:00Z"))
        let none = try #require(Self.plan(R.af84(), measure: Self.measure(precheck: nil), precheck: true))
        #expect(none.breakdown?.securityMinutes == 20 && none.breakdown?.precheck == false)
    }

    @Test func aNarrowBodyDomesticFlightHasShorterMargins() throws {
        // UA 1 leaves SFO at 00:00 UTC: boarding 23:30, less 30m bags, 15m security, 20m drive.
        var f = R.domestic()
        f.aircraftType = "A320"
        let t = try #require(Self.plan(f, origin: R.sfo, destination: R.lax, aircraft: Self.narrow,
                                       measure: Self.measure(drive: 20, standard: 15)))
        let b = try #require(t.breakdown)
        #expect(b.boardingLead == 30 * 60 && !b.wideBody)
        #expect(b.bagDrop == 30 * 60)
        #expect(t.leaveAt == R.date("2026-11-03T22:25:00Z"))
        #expect(!t.international)
    }

    @Test func aComputedTimeAimsAtTheScheduleNotTheEstimate() throws {
        let late = R.af84(estimated: "2026-11-03T23:30:00Z")
        #expect(Self.plan(late)?.leaveAt == R.date("2026-11-03T20:10:00Z"))
        // The fixed rule follows the estimate, as the leave reminder always did.
        #expect(Self.plan(late, measure: nil)?.leaveAt == R.date("2026-11-03T20:30:00Z"))
    }

    @Test func anyMissingInputGivesTheFixedRule() throws {
        let f = R.af84()
        let fixed = R.date("2026-11-03T19:30:00Z")
        for t in [Self.plan(f, measure: nil), Self.plan(f, aircraft: nil), Self.plan(f, origin: nil),
                  Self.plan(f, measure: Self.measure(standard: nil, precheck: nil)),
                  Self.plan(f, measure: Self.measure(standard: nil), precheck: false)] {
            let t = try #require(t)
            #expect(!t.isComputed)
            #expect(t.leaveAt == fixed)
        }
        let home = try #require(Self.plan(R.domestic(), origin: R.sfo, destination: R.lax, measure: nil))
        #expect(home.leaveAt == R.date("2026-11-03T22:00:00Z"))
    }

    @Test func noLeaveTimeOnceGoneCanceledOrUnscheduled() {
        var gone = R.af84()
        gone.actualOut = R.date("2026-11-03T22:40:00Z")
        #expect(Self.plan(gone) == nil)
        var canceled = R.af84()
        canceled.status = .canceled
        #expect(Self.plan(canceled) == nil)
        var unscheduled = R.af84()
        unscheduled.scheduledOut = nil
        #expect(Self.plan(unscheduled) == nil)
    }

    // MARK: Row wording

    @Test func theRowSaysLeaveByWithItsBreakdown() throws {
        let paris = R.cdg.timeZone
        let t = try #require(Self.plan(R.af84()))
        #expect(LeaveTimeFacts.title(t, tz: paris, clock: .h24, now: R.date("2026-11-03T12:00:00Z")) == "Leave by 21:10")
        #expect(LeaveTimeFacts.title(t, tz: paris, clock: .h12, now: R.date("2026-11-03T12:00:00Z")) == "Leave by 9:10 PM")
        #expect(LeaveTimeFacts.title(t, tz: paris, clock: .h24, now: R.date("2026-11-03T20:30:00Z")) == "Time to leave")
        #expect(LeaveTimeFacts.summary(t) == "35m drive · about 20m security · 45m bag drop")
        let lines = LeaveTimeFacts.lines(try #require(t.breakdown), departure: t.departure, international: true,
                                         tz: paris, clock: .h24)
        #expect(lines.map(\.title) == ["35m drive", "45m bag drop", "About 20m at security", "Boarding at 22:50",
                                       "Departs at 23:30"])
        #expect(lines[3].text == "40m before departure on a wide-body")
        #expect(lines[2].text == "Standard lane, an estimate at 19:00")
        let fixed = try #require(Self.plan(R.af84(), measure: nil))
        #expect(LeaveTimeFacts.summary(fixed) == "3 hours before an international flight")
        #expect(LeaveTimeFacts.gapText(.location(.denied))?.contains("Settings") == true)
        #expect(LeaveTimeFacts.gapText(nil) == nil)
        let dashes = CharacterSet(charactersIn: "\u{2013}\u{2014}")
        let all = lines.map { $0.title + $0.text }.joined() + LeaveTimeFacts.computedNote
            + [LeaveTimeGap.notYet, .aircraft, .security, .route, .airport, .location(.notDetermined)]
                .compactMap { LeaveTimeFacts.gapText($0) }.joined()
        #expect(all.rangeOfCharacter(from: dashes) == nil)
    }

    // MARK: Reminder

    @Test func theLeaveReminderUsesTheComputedTimeAndSaysWhy() throws {
        let leave = try #require(Self.plan(R.af84()))
        let plan = ReminderPlanner.plan(for: R.af84(), origin: R.cdg, destination: R.sfo,
                                        now: R.date("2026-11-01T00:00:00Z"), leave: leave)
        let r = try #require(plan.first { $0.kind == .leave })
        #expect(r.fireDate == R.date("2026-11-03T20:10:00Z"))
        #expect(r.title == "Time to leave for CDG")
        #expect(r.body == "AF 84 boards at 22:50. This allows 35m to drive, about 20m at security and 45m to drop bags.")
        // A fixed leave time keeps the old words.
        let fixed = ReminderPlanner.plan(for: R.af84(), origin: R.cdg, destination: R.sfo,
                                         now: R.date("2026-11-01T00:00:00Z"), leave: Self.plan(R.af84(), measure: nil))
        #expect(fixed.first { $0.kind == .leave }?.body.contains("3 hours early") == true)
    }

    // MARK: Estimator

    /// UA 1, an A320 from SFO at 16:00 local, measured four hours before.
    static func ua1() -> Flight {
        var f = R.domestic()
        f.aircraftType = "A320"
        return f
    }

    static func estimator(travel: FakeTravelTime = FakeTravelTime(), precheck: Bool = false,
                          now: String = "2026-11-03T20:00:00Z", defaults: UserDefaults? = nil) -> LeaveTimeEstimator {
        LeaveTimeEstimator(travel: travel, security: FakeSecurityWaitService(now: R.date(now)), lookup: R.lookup,
                           reference: .bundled(), precheck: { precheck }, defaults: defaults, now: { R.date(now) })
    }

    @Test func theEstimatorMeasuresInTheWindowAndComputes() async throws {
        let travel = FakeTravelTime(drive: 25 * 60)
        let e = Self.estimator(travel: travel)
        var heard = 0
        e.onChange = { heard += 1 }
        let f = Self.ua1()
        #expect(e.leaveTime(for: f)?.isComputed == false)
        await e.measure(f)
        let m = try #require(e.measures[f.id])
        #expect(m.drive == 25 * 60)
        #expect(m.standardMinutes != nil)
        let t = try #require(e.leaveTime(for: f))
        #expect(t.isComputed)
        let minutes = TimeInterval(try #require(m.standardMinutes) * 60)
        // The walk from security to the gate counts too (SFO's table figure for the flight's gate).
        let walk = e.gateWalk(for: f)
        #expect(t.breakdown?.walk == walk)
        let walking = TimeInterval(walk.minutes * 60)
        #expect(t.leaveAt == R.date("2026-11-03T23:30:00Z").addingTimeInterval(-(30 * 60 + minutes + walking + 25 * 60)))
        #expect(heard == 1)
        // A second look within ten minutes keeps the measure.
        await e.measure(f)
        #expect(travel.requests == 1)
    }

    @Test func theEstimatorSaysWhyItCannotMeasure() async {
        let denied = FakeTravelTime(access: .denied)
        let e = Self.estimator(travel: denied)
        await e.measure(Self.ua1())
        #expect(e.gaps[Self.ua1().id] == .location(.denied))
        #expect(denied.requests == 0)

        let early = Self.estimator(now: "2026-11-01T20:00:00Z")
        await early.measure(Self.ua1())
        #expect(early.gaps[Self.ua1().id] == .notYet)

        let noType = Self.estimator()
        await noType.measure(R.domestic())
        #expect(noType.gaps[R.domestic().id] == .aircraft)

        let failing = FakeTravelTime()
        failing.failNext = true
        let offline = Self.estimator(travel: failing)
        await offline.measure(Self.ua1())
        #expect(offline.gaps[Self.ua1().id] == .route)
        #expect(offline.measures.isEmpty)

        // Paris has no security figure: the fixed rule stays.
        var paris = R.af84()
        paris.aircraftType = "B77W"
        let abroad = Self.estimator(now: "2026-11-03T18:00:00Z")
        await abroad.measure(paris)
        #expect(abroad.gaps[paris.id] == .security)
        #expect(abroad.leaveTime(for: paris)?.isComputed == false)
    }

    @Test func locationIsAskedOnlyOnRequest() async {
        let travel = FakeTravelTime(access: .notDetermined)
        let e = Self.estimator(travel: travel)
        await e.measure(Self.ua1())
        #expect(travel.access == .notDetermined)
        #expect(e.gaps[Self.ua1().id] == .location(.notDetermined))
        await e.requestLocation(for: Self.ua1())
        #expect(travel.access == .allowed)
        #expect(e.measures[Self.ua1().id] != nil)
    }

    @Test func measuresSurviveARelaunch() async throws {
        let defaults = try #require(UserDefaults(suiteName: "leave-\(UUID().uuidString)"))
        let first = Self.estimator(defaults: defaults)
        await first.measure(Self.ua1())
        let again = Self.estimator(defaults: defaults)
        #expect(again.measures == first.measures)
        #expect(again.leaveTime(for: Self.ua1())?.isComputed == true)
    }

    @Test func aNewMeasureMovesThePendingLeaveReminder() async throws {
        let center = FakeLocalNotificationCenter()
        let now = R.date("2026-11-03T20:00:00Z")
        let scheduler = ReminderScheduler(center: center, lookup: R.lookup, now: { now }, clock: { .h24 })
        let e = Self.estimator()
        scheduler.leaveTime = { e.leaveTime(for: $0) }
        e.onChange = { scheduler.resync() }
        let f = Self.ua1()
        await scheduler.sync([f])
        let id = ReminderPlanner.identifier(f.id, .leave)
        #expect(center.pending[id]?.fireDate == R.date("2026-11-03T22:00:00Z"))
        await e.measure(f)
        await scheduler.sync([f])
        let computed = try #require(e.leaveTime(for: f))
        #expect(computed.isComputed)
        #expect(center.pending[id]?.fireDate == computed.leaveAt)
    }

    @Test func theHomeHandsTheLeaveTimesToTheReminders() async throws {
        let env = try await AppEnvironment.fake()
        let home = HomeModel(env: env)
        let scheduler = ReminderScheduler(center: FakeLocalNotificationCenter(), lookup: env.lookup, clock: { .h24 })
        let e = Self.estimator()
        home.attachReminders(scheduler)
        home.attachLeaveTimes(e)
        #expect(home.leaveTimes === e)
        #expect(scheduler.leaveTime != nil)
        #expect(e.onChange != nil)
    }
}
