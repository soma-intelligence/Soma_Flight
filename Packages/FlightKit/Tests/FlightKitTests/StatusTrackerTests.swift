import Foundation
import Testing
@testable import FlightKit

/// Plan 38: the traveller's own status goals counted from the history.
@Suite struct StatusTrackerTests {
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    /// 2026-11-08 12:00 in California.
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!

    static func on(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))! }

    static func flight(_ ident: String, _ date: Date, airline: String? = nil, km: Int = 1_000,
                       status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(date: date, ident: ident, originIcao: "KSFO", destinationIcao: "LFPG", airline: airline,
                   distanceKm: km, status: status)
    }

    static let history = [
        flight("UAL990", on(2026, 4, 25)),                     // United: Star Alliance
        flight("DLH455", on(2026, 2, 1), airline: "Lufthansa"), // Star Alliance
        flight("AFR83", on(2026, 9, 14)),                      // SkyTeam
        flight("UAL991", on(2025, 12, 20)),                     // last year, inside 12 months
        flight("UAL837", on(2025, 10, 1)),                      // more than 12 months ago
        flight("UAL1527", on(2026, 7, 2), status: .canceled),
        flight("UAL1882", on(2026, 12, 1)),                     // still to come
    ]

    static let star = StatusProgram(name: "Gold", airlines: .alliance(.starAlliance), segmentGoal: 30, distanceGoal: 50_000,
                                    distanceUnit: .mi)

    @Test func countsTheAllianceInTheCalendarYear() {
        let p = StatusTracker.progress(Self.star, flights: Self.history, now: Self.now, calendar: Self.cal)
        #expect(p.segments == 2)
        #expect(p.distanceKm == 2_000)
        #expect(p.since == Self.cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
    }

    @Test func rollingTwelveMonthsReachesIntoLastYear() {
        var rolling = Self.star
        rolling.period = .rolling12Months
        let p = StatusTracker.progress(rolling, flights: Self.history, now: Self.now, calendar: Self.cal)
        #expect(p.segments == 3)
    }

    @Test func pickedAirlinesCountOnlyThem() {
        let skyteam = StatusProgram(name: "Flying Blue", airlines: .airlines(["AFR", "KLM"]), segmentGoal: 10)
        #expect(StatusTracker.progress(skyteam, flights: Self.history, now: Self.now, calendar: Self.cal).segments == 1)
        let united = StatusProgram(name: "MileagePlus", airlines: .airlines(["ual"]), segmentGoal: 10)
        #expect(StatusTracker.progress(united, flights: Self.history, now: Self.now, calendar: Self.cal).segments == 1)
    }

    @Test func canceledFlightsNeverCount() {
        #expect(!StatusTracker.qualifies(Self.flight("UAL1", Self.now, status: .canceled), Self.star))
        #expect(StatusTracker.qualifies(Self.flight("UAL1", Self.now, status: .diverted), Self.star))
    }

    @Test func unknownAirlinesDoNotCount() {
        #expect(!StatusTracker.qualifies(Self.flight("ZZZ12", Self.now), Self.star))
    }

    @Test func distanceConvertsBetweenUnits() {
        #expect(StatusTracker.distance(StatusTracker.km(50_000, from: .mi), in: .km) == 80_467)
        #expect(StatusTracker.distance(StatusTracker.km(80_467, from: .km), in: .mi) == 50_000)
        let p = StatusProgress(segments: 18, distanceKm: 66_305, since: Self.now)
        #expect(StatusFacts.distance(p, goal: 50_000, goalUnit: .mi, in: .mi) == "41,200 of 50,000 mi")
        #expect(StatusFacts.distance(p, goal: 50_000, goalUnit: .mi, in: .km) == "66,305 of 80,467 km")
        #expect(StatusFacts.segments(18, of: 30) == "18 of 30 segments")
    }

    @Test func shareIsClamped() {
        #expect(StatusTracker.share(45, of: 30) == 1)
        #expect(StatusTracker.share(15, of: 30) == 0.5)
        #expect(StatusTracker.share(5, of: 0) == 0)
    }

    @Test func aProgrammeNeedsANameAirlinesAndAGoal() {
        #expect(Self.star.isValid)
        #expect(!StatusProgram(name: " ", airlines: .alliance(.oneworld), segmentGoal: 4).isValid)
        #expect(!StatusProgram(name: "X", airlines: .airlines([]), segmentGoal: 4).isValid)
        #expect(!StatusProgram(name: "X", airlines: .alliance(.oneworld)).isValid)
    }

    @Test func scopeNamesTheAirlines() {
        #expect(StatusFacts.scope(Self.star) == "Star Alliance \u{00B7} This calendar year")
        let picked = StatusProgram(name: "X", airlines: .airlines(["AFR", "KLM"]), period: .rolling12Months, segmentGoal: 1)
        #expect(StatusFacts.scope(picked) == "Air France, KLM Royal Dutch Airlines \u{00B7} Last 12 months")
    }

    @MainActor @Test func programmesPersistOnTheDevice() throws {
        let suite = "status-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StatusPrograms(defaults: defaults)
        store.save(Self.star)
        store.save(StatusProgram(name: "", airlines: .alliance(.oneworld), segmentGoal: 3))
        #expect(StatusPrograms(defaults: defaults).programs == [Self.star])
        var edited = Self.star
        edited.segmentGoal = 25
        store.save(edited)
        #expect(StatusPrograms(defaults: defaults).programs.first?.segmentGoal == 25)
        store.remove(Self.star.id)
        #expect(StatusPrograms(defaults: defaults).programs.isEmpty)
    }

    @MainActor @Test func goalsBelongToTheAccountThatSavedThem() throws {
        let suite = "status.owner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        StatusPrograms(defaults: defaults, owner: a).save(Self.star)
        #expect(StatusPrograms(defaults: defaults, owner: a).programs == [Self.star])
        // Another account reads none, and its own save leaves the first account's goal out.
        let theirs = StatusPrograms(defaults: defaults, owner: b)
        #expect(theirs.programs.isEmpty)
        theirs.save(StatusProgram(name: "Mine", airlines: .alliance(.skyteam), segmentGoal: 4))
        #expect(StatusPrograms(defaults: defaults, owner: b).programs.map(\.name) == ["Mine"])
        #expect(StatusPrograms(defaults: defaults, owner: a).programs.isEmpty)
        #expect(StatusPrograms(defaults: defaults, owner: nil).programs.isEmpty)
    }

    @MainActor @Test func eachAccountsPassportCarriesItsOwnerForTheGoals() async throws {
        let env = try await AppEnvironment.fake()
        let a = UUID(), b = UUID()
        let first = env.makePassportStore(owner: a), second = env.makePassportStore(owner: b)
        #expect(first.owner == a)
        #expect(second.owner == b)
        // The Settings section is keyed by the store, and reads the goals of the store's owner.
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        #expect(StatusPrograms(defaults: nil, owner: second.owner).owner == b)
    }

    @MainActor @Test func programmesStopAtTheLimit() {
        let store = StatusPrograms(defaults: nil)
        for i in 0..<5 { store.save(StatusProgram(name: "P\(i)", airlines: .alliance(.skyteam), segmentGoal: 1)) }
        #expect(store.programs.count == StatusPrograms.limit)
        #expect(!store.canAdd)
    }
}
