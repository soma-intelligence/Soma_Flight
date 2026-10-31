import Foundation
@testable import FlightKit
import Supabase
import Testing

/// The live insights: `flight-insights` answers decoded by the same functions the service uses, the
/// Info.plist switch, and the wiring in `AppEnvironment.supabase`. The example answers are read from
/// `supabase/functions/flight-insights/contract/` in the repository (written by the backend's tests),
/// so a change on the backend side that the app cannot read fails here.
@MainActor @Suite struct SupabaseInsightsTests {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/flight-insights/contract")

    private func contract(_ name: String) throws -> Data {
        try Data(contentsOf: Self.contract.appending(path: "\(name).json"))
    }

    @Test func decodesTheForecastContract() throws {
        let data = try contract("arrival_forecast")
        let answer = try SupabaseInsightsService.decodeForecastAnswer(data)
        #expect(answer.ident == "AF84")
        #expect(answer.stale == false)
        let f = try #require(try SupabaseInsightsService.decodeForecast(data))
        #expect(f.ident == "AF84")
        #expect(f.days == 60)
        #expect(f.observed == 13)
        #expect(f.latePercent == 45)
        #expect(f.averageLateMinutes == 42)
        #expect(f.percents == [.early: 16, .onTime: 23, .late15: 15, .late30: 15, .late45: 15, .canceled: 8, .diverted: 8])
        // The same invariants as the fakes: every bucket, 100 in all, late is the three late buckets.
        #expect(Set(f.percents.keys) == Set(ForecastBucket.allCases))
        #expect(f.percents.values.reduce(0, +) == 100)
        #expect(f.latePercent == f.percents[.late15]! + f.percents[.late30]! + f.percents[.late45]!)
        #expect(ForecastSection.subtitle(f) == "AF 84 over the last 60 days")
    }

    @Test func noForecastIsNil() throws {
        let none = Data(#"{"ident":"ZZ1","fetched_at":"2026-11-03T10:00:00.000Z","stale":false,"forecast":null}"#.utf8)
        #expect(try SupabaseInsightsService.decodeForecast(none) == nil)
    }

    /// A bucket the backend forgot fails the decode instead of reading as 0.
    @Test func aMissingBucketFails() throws {
        var json = try JSONSerialization.jsonObject(with: try contract("arrival_forecast")) as! [String: Any]
        var forecast = json["forecast"] as! [String: Any]
        var percents = forecast["percents"] as! [String: Any]
        percents.removeValue(forKey: "on_time")
        forecast["percents"] = percents
        json["forecast"] = forecast
        let broken = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try SupabaseInsightsService.decodeForecast(broken) }
    }

    @Test func decodesTheInboundContract() throws {
        let data = try contract("inbound")
        let answer = try SupabaseInsightsService.decodeInboundAnswer(data)
        #expect(answer.flightId == UUID(uuidString: "c2000000-0000-0000-0000-000000000001"))
        let legs = try SupabaseInsightsService.decodeInbound(data)
        try #require(legs.count == 3)
        #expect(legs.map(\.ident) == ["AF1145", "AF1144", "AF11"])
        #expect(legs.map { "\($0.originIata)-\($0.destinationIata)" } == ["LHR-CDG", "CDG-LHR", "JFK-CDG"])
        #expect(legs.map(\.delayMinutes) == [12, 0, 35])
        #expect(legs.allSatisfy { $0.status == .arrived })
        #expect(legs[0].id == "AFR1145-1793689200-schedule-0001p")
        #expect(legs[0].scheduledOut == ISO8601DateFormatter().date(from: "2026-11-03T07:00:00Z"))
        #expect(legs[0].scheduledIn == ISO8601DateFormatter().date(from: "2026-11-03T08:15:00Z"))
        // Newest first, each leg ending where the newer one began, as the Plane section expects.
        #expect(PlaneSection.ordered(legs.reversed()) == legs)
        #expect(legs[1].destinationIata == legs[0].originIata)
        #expect(PlaneSection.legStatus(legs[0]).text == "12m late")
        #expect(PlaneSection.legStatus(legs[2]) == ("35m late", .late))
        #expect(PlaneSection.legStatus(legs[1]).text == "On time")
    }

    @Test func unknownStatusesAndEmptyChainsDecode() throws {
        let empty = Data(#"{"flight_id":"c2000000-0000-0000-0000-000000000001","fetched_at":"2026-11-03T10:00:00Z","stale":true,"legs":[]}"#.utf8)
        #expect(try SupabaseInsightsService.decodeInbound(empty).isEmpty)
        let odd = Data(#"""
        {"flight_id":"c2000000-0000-0000-0000-000000000001","fetched_at":"2026-11-03T10:00:00Z","stale":false,
         "legs":[{"id":"X-1","ident":"AF1","origin_iata":"CDG","destination_iata":"LHR",
                  "scheduled_out":"2026-11-03T05:00:00.000Z","scheduled_in":"2026-11-03T06:15:00.000Z",
                  "status":"something_new","delay_minutes":0}]}
        """#.utf8)
        #expect(try SupabaseInsightsService.decodeInbound(odd).first?.status == .unknown)
    }

    @Test(arguments: [
        ("YES", true), ("yes", true), ("true", true), ("1", true), (" YES ", true),
        ("NO", false), ("no", false), ("", false), ("$(INSIGHTS_ENABLED)", false), ("maybe", false),
    ])
    func readsTheSwitch(raw: String, on: Bool) {
        #expect(SupabaseInsightsService.isEnabled(raw: raw) == on)
    }

    @Test func switchTakesPlistTypesAndAMissingKeyIsOff() {
        #expect(SupabaseInsightsService.isEnabled(raw: true))
        #expect(!SupabaseInsightsService.isEnabled(raw: false))
        #expect(SupabaseInsightsService.isEnabled(raw: NSNumber(value: 1)))
        #expect(!SupabaseInsightsService.isEnabled(raw: nil))
        // The test bundle has no InsightsEnabled key.
        #expect(!SupabaseInsightsService.isEnabled(in: Bundle(for: BundleToken.self)))
    }

    private func env(insights: Bool? = nil) -> AppEnvironment {
        let config = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "test")
        if let insights {
            return AppEnvironment.supabase(config: config, cache: try! CacheStore.inMemory(), recents: .memory,
                                           authStorage: MemoryAuthStorage(), insights: insights)
        }
        return AppEnvironment.supabase(config: config, cache: try! CacheStore.inMemory(), recents: .memory,
                                       authStorage: MemoryAuthStorage())
    }

    @Test func theSwitchPicksTheService() {
        #expect(env(insights: true).insights is SupabaseInsightsService)
        #expect(env(insights: false).insights is UnavailableInsightsService)
        // Off unless asked: a caller that says nothing pays for nothing.
        #expect(env().insights is UnavailableInsightsService)
    }

    /// The backend refusing (the spend cap) or out of reach empties both sections and is no screen error.
    @Test func aFailingBackendHidesBothSections() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let live = env(insights: true)
        let store = FlightDetailStore(id: PreviewData.enRoute.id, flights: flights,
                                      airports: FakeAirportService(now: PreviewData.now), insights: live.insights)
        await store.load()
        await store.loadExtras()
        #expect(store.forecast == nil)
        #expect(store.inbound.isEmpty)
        #expect(store.error == nil)
        let refused = Data(#"{"error":{"code":"provider_unavailable","message":"Insights are unavailable right now"}}"#.utf8)
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 503, data: refused)) == .providerUnavailable)
    }
}

/// Finds the test bundle.
private final class BundleToken {}
