import Foundation
import Testing
@testable import FlightKit

/// Task 17: the arrival forecast and the inbound plane, on fakes only.
@MainActor @Suite struct InsightsTests {
    @Test func fakeForecastDeterministic() async throws {
        let a = FakeInsightsService(flights: FakeFlightService(now: PreviewData.now))
        let b = FakeInsightsService(flights: FakeFlightService(now: PreviewData.now))
        let one = try await a.arrivalForecast(ident: "UA990")
        let two = try await b.arrivalForecast(ident: "UA990")
        #expect(one == two)
        #expect(one?.days == 60)
        #expect((20...40).contains(one?.observed ?? 0))
        #expect(one != (try await a.arrivalForecast(ident: "AF84")))
        #expect(FakeInsightsService.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(FakeInsightsService.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(ForecastSection.subtitle(one!) == "UA 990 over the last 60 days")
        #expect(ForecastBucket.allCases.map(\.title) == ["Early", "On time", "15m late", "30m late", "45m+ late", "Canceled", "Diverted"])
        #expect(ForecastBucket.of(lateMinutes: -3) == .early)
        #expect(ForecastBucket.of(lateMinutes: 0) == .onTime)
        #expect(ForecastBucket.of(lateMinutes: 14) == .onTime)
        #expect(ForecastBucket.of(lateMinutes: 15) == .late15)
        #expect(ForecastBucket.of(lateMinutes: 44) == .late30)
        #expect(ForecastBucket.of(lateMinutes: 45) == .late45)
    }

    @Test func percentsSumTo100() {
        for ident in ["UA990", "AF84", "B6417", "DL2204", "WN4410", "X", "LH400"] {
            let f = FakeInsightsService.forecast(ident: ident)
            #expect(f.percents.values.reduce(0, +) == 100)
            #expect(Set(f.percents.keys) == Set(ForecastBucket.allCases))
            #expect(f.latePercent == f.percents[.late15]! + f.percents[.late30]! + f.percents[.late45]!)
        }
        let thirds = FakeInsightsService.percentages([.early: 1, .onTime: 1, .late15: 1])
        #expect(thirds.values.reduce(0, +) == 100)
        #expect(FakeInsightsService.percentages([:]).values.reduce(0, +) == 0)
    }

    @Test func unavailableHidesSections() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let flight = PreviewData.enRoute
        let store = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: PreviewData.now))
        await store.load()
        await store.loadExtras()
        #expect(store.forecast == nil)
        #expect(store.inbound.isEmpty)
        #expect(PlaneSection.isShown(type: nil, inbound: store.inbound) == false)
        #expect(PlaneSection.isShown(type: ReferenceData.bundled().type("B77W"), inbound: []) == true)

        // The fakes fill both; a failure empties only its own.
        let insights = FakeInsightsService(flights: flights)
        let fake = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                     insights: insights)
        await fake.load()
        await fake.loadExtras()
        #expect(fake.forecast != nil)
        #expect(fake.inbound.count == 2)
        await insights.setNextError(.providerUnavailable)
        await fake.loadExtras()
        // The two calls run at once, so either one takes the error; the other still fills.
        #expect((fake.forecast == nil) != fake.inbound.isEmpty)
        #expect(fake.error == nil)

        // Live builds never get sample data.
        let live = AppEnvironment.supabase(config: SupabaseConfig(url: URL(string: "http://127.0.0.1:1")!, anonKey: "test"),
                                           cache: try! CacheStore.inMemory(), recents: .memory,
                                           authStorage: MemoryAuthStorage())
        #expect(live.insights is UnavailableInsightsService)
        let fakeEnv = try! await AppEnvironment.fake(now: PreviewData.now)
        #expect(fakeEnv.insights is FakeInsightsService)
    }

    /// Counts the paid calls a detail makes.
    actor CountingInsights: InsightsService {
        private(set) var calls = 0
        func arrivalForecast(ident: String) async throws(APIError) -> ArrivalForecast? {
            calls += 1
            return FakeInsightsService.forecast(ident: ident)
        }
        func inbound(_ id: Flight.ID) async throws(APIError) -> [InboundLeg] { calls += 1; return [] }
    }

    @Test func canceledAndDivertedMakeNoInsightsCalls() async {
        let flights = FakeFlightService(now: PreviewData.now)
        for flight in [PreviewData.canceled, PreviewData.diverted] {
            #expect(!FlightDetailStore.showsInsights(flight.status))
            let counting = CountingInsights()
            let store = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                          insights: counting)
            await store.load()
            #expect(store.flight?.status == flight.status)
            await store.loadExtras()
            #expect(await counting.calls == 0, "\(flight.status) asked for insights")
            #expect(store.forecast == nil)
            #expect(store.inbound.isEmpty)
        }
        // A flight that still flies asks for both.
        #expect(FlightDetailStore.showsInsights(.scheduled) && FlightDetailStore.showsInsights(.enRoute))
        let counting = CountingInsights()
        let store = FlightDetailStore(id: PreviewData.enRoute.id, flights: flights,
                                      airports: FakeAirportService(now: PreviewData.now), insights: counting)
        await store.load()
        await store.loadExtras()
        #expect(await counting.calls == 2)
        #expect(store.forecast != nil)
    }

    @Test func inboundOrder() async throws {
        let flights = FakeFlightService(now: PreviewData.now)
        let flight = PreviewData.enRoute
        let legs = try await FakeInsightsService(flights: flights).inbound(flight.id)
        #expect(legs.count == 2)
        // Newest first, the newest landing at this flight's origin, each leg ending where the next one began.
        #expect(legs[0].scheduledOut > legs[1].scheduledOut)
        #expect(legs[0].destinationIata == flight.originCode)
        #expect(legs[1].destinationIata == legs[0].originIata)
        #expect(legs[0].scheduledIn <= flight.scheduledOut!)
        #expect(PlaneSection.ordered(legs.reversed()) == legs)
        #expect(PlaneSection.legStatus(legs[0]).text.hasSuffix("late") || PlaneSection.legStatus(legs[0]).text == "On time")
        var canceled = legs[0]
        canceled.status = .canceled
        #expect(PlaneSection.legStatus(canceled).text == "Canceled")
        var late = legs[0]
        late.delayMinutes = 22
        #expect(PlaneSection.legStatus(late) == ("22m late", .late))
    }
}
