import FlightImportKit
import Foundation
@testable import FlightKit
import Testing

/// `ScheduleService`: the live decoder against the backend's example answer, the fake's rows and the
/// unavailable service.
struct ScheduleServiceTests {
    private static let day = LocalDay(year: 2026, month: 11, day: 20)

    /// `flight-schedules` answers as its tests write them, read by the decoder the live service uses.
    @Test func decodesTheSchedulesContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "supabase/functions/flight-schedules/contract/schedules.json"))
        let flights = try SupabaseScheduleService.decode(data)
        #expect(flights.map(\.ident) == ["UA2306", "AA1781", "UA1958", "AS1314"])
        let ua = try #require(flights.first { $0.ident == "UA1958" })
        #expect(ua.airline == "UAL")
        #expect(ua.origin == "KSFO" && ua.destination == "KORD")
        #expect(ua.scheduledOut == FlightJSON.parse("2026-11-03T20:00:00Z"))
        #expect(ua.scheduledIn == FlightJSON.parse("2026-11-04T00:15:00Z"))
        #expect(ua.aircraftType == "B772")
        #expect(Set(flights.map(\.id)).count == 4)
        #expect(try !SupabaseScheduleService.decodeDay(data).truncated)
    }

    @Test func buildsTheRequestBody() throws {
        let q = ScheduleQuery(origin: "KSFO", airline: "UAL", ident: "UA1958", day: Self.day)
        let json = try #require(JSONSerialization.jsonObject(with: SupabaseScheduleService.body(q)) as? [String: String])
        #expect(json == ["origin": "KSFO", "airline": "UAL", "ident": "UA1958", "date": "2026-11-20"])
        // A time of day goes as a number of minutes.
        let timed = ScheduleQuery(origin: "KSFO", day: Self.day, time: 1140)
        let raw = try #require(JSONSerialization.jsonObject(with: SupabaseScheduleService.body(timed)) as? [String: Any])
        #expect(raw["time"] as? Int == 1140)
        #expect(raw["date"] as? String == "2026-11-20")
    }

    /// The answer's `truncated` flag, false when absent.
    @Test func decodesTheTruncatedFlag() throws {
        let cut = #"{"date":"2026-11-20","fetched_at":"2026-11-01T12:00:00Z","stale":false,"truncated":true,"flights":[]}"#
        #expect(try SupabaseScheduleService.decodeDay(Data(cut.utf8)).truncated)
        let old = #"{"date":"2026-11-20","fetched_at":"2026-11-01T12:00:00Z","stale":false,"flights":[]}"#
        #expect(try !SupabaseScheduleService.decodeDay(Data(old.utf8)).truncated)
    }

    @Test func theFakeAnswersRowsOnTheAskedDay() async throws {
        let fake = FakeScheduleService()
        let rows = try await fake.schedules(ScheduleQuery(origin: "KSFO", day: Self.day))
        #expect(!rows.isEmpty)
        var sf = Calendar(identifier: .gregorian)
        sf.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for r in rows {
            #expect(r.origin == "KSFO")
            let c = sf.dateComponents([.year, .month, .day], from: r.scheduledOut)
            #expect((c.year, c.month, c.day) == (2026, 11, 20))
        }
        let ua = try #require(rows.first { $0.ident == "UA1527" })
        #expect(ua.airline == "UAL" && ua.destination == "KAUS")
        // The seed has UA1527 out at 19:22Z on 23 Oct, 12:22 in San Francisco: the local time stays.
        let c = sf.dateComponents([.hour, .minute], from: ua.scheduledOut)
        #expect((c.hour, c.minute) == (12, 22))
        #expect(try #require(ua.scheduledIn) > ua.scheduledOut)
    }

    @Test func theFakeFilters() async throws {
        let fake = FakeScheduleService()
        let byDestination = try await fake.schedules(ScheduleQuery(destination: "KSFO", day: Self.day))
        #expect(Set(byDestination.map(\.ident)).isSuperset(of: ["AF84", "AS312"]))
        #expect(byDestination.allSatisfy { $0.destination == "KSFO" })
        let all = try await fake.schedules(ScheduleQuery(origin: "KSFO", day: Self.day))
        let byAirline = try await fake.schedules(ScheduleQuery(origin: "KSFO", airline: "UAL", day: Self.day))
        #expect(!byAirline.isEmpty && byAirline.count < all.count)
        #expect(byAirline.allSatisfy { $0.airline == "UAL" && $0.origin == "KSFO" })
        let byIdent = try await fake.schedules(ScheduleQuery(ident: "ua 1527", day: Self.day))
        #expect(byIdent.map(\.ident) == ["UA1527"])
        let none = try await fake.schedules(ScheduleQuery(origin: "KXXX", day: Self.day))
        #expect(none.isEmpty)
    }

    @Test func theFakeThrowsItsNextErrorOnce() async throws {
        let fake = FakeScheduleService()
        await fake.setNextError(.rateLimited)
        await #expect(throws: APIError.rateLimited) { try await fake.schedules(ScheduleQuery(origin: "KSFO", day: Self.day)) }
        #expect(try await !fake.schedules(ScheduleQuery(origin: "KSFO", day: Self.day)).isEmpty)
    }

    @Test func theUnavailableServiceThrows() async {
        await #expect(throws: APIError.providerUnavailable) {
            try await UnavailableScheduleService().schedules(ScheduleQuery(origin: "KSFO", day: Self.day))
        }
    }
}
