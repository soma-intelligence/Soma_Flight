import Foundation
import Testing
@testable import FlightKit

/// The Airports feature: the `airport-weather` and `airport-stats` answers decoded from the backend's
/// contract files, the status rules, the list store, the fakes with and without a board provider, the
/// airport store's data plan path, and the user's history at an airport.
@MainActor @Suite struct AirportsTests {
    static let root = FAATests.root

    private func contract(_ fn: String, _ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appending(path: "\(fn)/contract/\(name).json"))
    }

    let now = PreviewData.now

    // MARK: Contracts

    @Test func decodesWeatherList() throws {
        let list = try SupabaseAirportOverviewService.decodeOverviews(contract("airport-weather", "list"))
        let sfo = try #require(list.first { $0.icao == "KSFO" })
        #expect(sfo.iata == "SFO")
        #expect(sfo.weather?.condition == "Partly cloudy")
        #expect(sfo.weather?.summary == "Partly cloudy with light winds.")
        #expect(sfo.weather?.category == .VFR)
        #expect(sfo.programs?.first?.kind == .groundDelay)
        #expect(sfo.programs?.first?.averageMinutes == 47)
        // The ground delay of 47 minutes is a minor issue, worded for the list.
        let status = AirportStatus.of(sfo)
        #expect(status.level == .minor)
        #expect(status.line?.hasPrefix("Ground delay program") == true)
    }

    @Test func decodesStatsList() throws {
        let list = try SupabaseAirportOverviewService.decodeSummaries(contract("airport-stats", "list"))
        #expect(list.available)
        let sfo = try #require(list.airports.first { $0.icao == "KSFO" })
        #expect(sfo.departures?.total == 5)
        #expect(sfo.departures?.onTimePercent == 40)
        #expect(sfo.arrivals?.total == 0)
        #expect(sfo.arrivals?.onTimePercent == nil)
    }

    @Test func decodesStatsDetail() throws {
        let live = try #require(try SupabaseAirportOverviewService.decodeLiveStats(contract("airport-stats", "detail")))
        #expect(live.available)
        #expect(live.icao == "KSFO")
        let dep = try #require(live.departures)
        #expect(dep.trend.count == 3)
        #expect(dep.trend.last?.estimated == true)
        #expect(dep.worstRoutes.first?.icao == "CYVR")
        #expect(dep.delayStats.total == 5)
        #expect(live.today != nil)
        #expect(live.next7Days == nil)
    }

    @Test func decodesNoProvider() throws {
        let live = try #require(try SupabaseAirportOverviewService.decodeLiveStats(contract("airport-stats", "no_provider")))
        #expect(!live.available)
        #expect(live.departures == nil && live.today == nil)
    }

    // MARK: Status rules

    @Test func noDataIsNormal() {
        #expect(AirportStatus.of(nil) == .normal)
        #expect(AirportStatus.of(AirportOverview(icao: "KATL")).level == .normal)
    }

    @Test func boardNumbersSetTheLevel() {
        let calm = AirportBrief(total: 100, onTime: 90, delayed: 10, canceled: 0, avgDelayMinutes: 6)
        let late = AirportBrief(total: 100, onTime: 70, delayed: 30, canceled: 0, avgDelayMinutes: 20)
        let bad = AirportBrief(total: 100, onTime: 60, delayed: 28, canceled: 12, avgDelayMinutes: 30)
        #expect(AirportStatus.of(nil, live: .init(icao: "X", departures: calm, arrivals: calm)).level == .normal)
        #expect(AirportStatus.of(nil, live: .init(icao: "X", departures: late, arrivals: calm)).level == .minor)
        #expect(AirportStatus.of(nil, live: .init(icao: "X", departures: calm, arrivals: bad)).level == .major)
        // Too few flights say nothing.
        let few = AirportBrief(total: 3, onTime: 0, delayed: 3, canceled: 0, avgDelayMinutes: 90)
        #expect(AirportStatus.of(nil, live: .init(icao: "X", departures: few, arrivals: nil)).level == .normal)
    }

    @Test func programsWinOverNumbers() {
        let stop = AirportProgram(airport: "EWR", kind: .groundStop)
        let late = AirportBrief(total: 100, onTime: 70, delayed: 30, canceled: 0, avgDelayMinutes: 20)
        let s = AirportStatus.of(AirportOverview(icao: "KEWR", programs: [stop]),
                                 live: .init(icao: "KEWR", departures: late, arrivals: nil))
        #expect(s == AirportStatus(level: .major, line: "Ground stop"))
    }

    // MARK: List store

    private func listStore(live: Bool, favorites: [String] = ["EGLL"], trips: [String] = []) -> AirportsListStore {
        let directory = AirportDirectory.bundled()
        return AirportsListStore(service: FakeAirportOverviewService(now: now, live: live), lookup: directory.lookup,
                                 favorites: AirportFavorites(defaults: nil, seed: favorites), tripAirports: { trips })
    }

    @Test func listSectionsPutTheUserFirst() async {
        let store = listStore(live: true, trips: ["KAUS"])
        await store.load()
        #expect(store.error == nil)
        #expect(store.liveAvailable)
        let sections = store.sections
        #expect(sections.first?.kind == .yours)
        #expect(Set(sections.first?.rows.map(\.id) ?? []) == ["EGLL", "KAUS"])
        // Worst first, and each airport in one section only.
        #expect(sections.dropFirst().first?.kind == .major)
        let all = sections.flatMap(\.rows).map(\.id)
        #expect(all.count == Set(all).count)
        #expect(all.contains("KEWR"))
        #expect(sections.first { $0.kind == .major }?.rows.contains { $0.id == "KEWR" } == true)
    }

    @Test func listFiltersByRegion() async {
        let store = listStore(live: true)
        await store.load()
        store.region = .europe
        #expect(!store.filtered.isEmpty)
        #expect(store.filtered.allSatisfy { $0.region == .europe })
        #expect(store.globe.airports.count == store.filtered.count)
        #expect(store.globe.status["EGLL"] != nil)
    }

    @Test func listWithoutProviderKeepsWeather() async {
        let store = listStore(live: false)
        await store.load()
        #expect(!store.liveAvailable)
        #expect(store.live.isEmpty)
        #expect(store.rows.allSatisfy { $0.overview?.weather != nil })
        // FAA programs and weather still colour the list: EWR's ground stop is still major.
        #expect(store.rows.first { $0.id == "KEWR" }?.status.level == .major)
    }

    @Test func favoritesToggleAndPersist() throws {
        let suite = "airports-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favs = AirportFavorites(defaults: defaults)
        favs.toggle("KSFO")
        #expect(AirportFavorites(defaults: defaults).codes == ["KSFO"])
        favs.toggle("KSFO")
        #expect(AirportFavorites(defaults: defaults).codes.isEmpty)
    }

    // MARK: Airport store

    @Test func storeWithoutProviderSkipsBoards() async {
        let store = AirportStore(code: "KSFO", airports: FakeAirportService(now: now), faa: FakeFAAService(now: now),
                                 overview: FakeAirportOverviewService(now: now, live: false))
        await store.load()
        #expect(store.needsDataPlan)
        #expect(store.departures == nil && store.arrivals == nil && store.stats == nil)
        #expect(store.weather != nil)
        #expect(store.overview?.weather != nil)
        #expect(store.error == nil)
    }

    @Test func storeFillsStatsFromProvider() async {
        // EGLL has no board in the seed: the provider's summary stands in.
        let store = AirportStore(code: "EGLL", airports: FakeAirportService(now: now),
                                 overview: FakeAirportOverviewService(now: now))
        await store.load()
        #expect(!store.needsDataPlan)
        #expect(store.stats != nil)
        #expect(store.liveStats?.today?.busiestAirlines.isEmpty == false)
        #expect(store.regulars.count == 3)
        #expect(store.regulars.first { $0.isMe }?.name == "You")
    }

    // MARK: History

    @Test func historyCountsFlightsThroughTheAirport() {
        func flight(_ o: String, _ d: String, _ days: Double, _ status: PastFlightStatus = .completed) -> PastFlight {
            PastFlight(id: UUID(), date: now.addingTimeInterval(-days * 86_400), ident: "UA1", originIcao: o,
                       destinationIcao: d, distanceKm: 1000, delayMinutes: 0, status: status)
        }
        let past = [flight("KSFO", "KJFK", 30), flight("KJFK", "KSFO", 25), flight("KSFO", "EGLL", 10),
                    flight("KSFO", "KJFK", 5, .canceled), flight("KAUS", "KDEN", 2)]
        let h = AirportHistory.of(past, icao: "KSFO")
        #expect(h?.flights == 3)
        #expect(h?.departures == 2 && h?.arrivals == 1)
        #expect(h?.last?.destinationIcao == "EGLL")
        #expect(h?.topEnds.first?.icao == "KJFK")
        #expect(AirportHistory.of(past, icao: "RJTT") == nil)
    }
}
