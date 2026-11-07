import Foundation
import Testing
@testable import FlightKit

/// The follow list behind the bell on the airport sheet: the store, the fake, the backend's row shapes.
@Suite @MainActor struct FavoriteAirportAlertsTests {
    @Test func loadsTheStateOfOneAirportAndFlipsIt() async {
        let service = FakeFavoriteAirportAlertsService(["KJFK"])
        let store = FavoriteAirportAlertsStore(service: service)
        #expect(!store.isAvailable)
        await store.load(icao: "KSFO")
        #expect(store.isAvailable && !store.isFollowing)
        await store.toggle()
        #expect(store.isFollowing)
        #expect(await service.stored == ["KJFK", "KSFO"])
        await store.toggle()
        #expect(!store.isFollowing)
        #expect(await service.stored == ["KJFK"])
        await store.load(icao: "KJFK")
        #expect(store.isFollowing)
    }

    @Test func aFailedSaveTurnsTheSwitchBack() async {
        let service = FakeFavoriteAirportAlertsService()
        let store = FavoriteAirportAlertsStore(service: service)
        await store.load(icao: "KSFO")
        await service.setNextError(.offline)
        await store.toggle()
        #expect(!store.isFollowing)
        #expect(store.error == .offline)
        #expect(await service.stored.isEmpty)
    }

    @Test func aBackendWithoutTheListShowsNoSwitch() async {
        let store = FavoriteAirportAlertsStore(service: UnavailableFavoriteAirportAlertsService())
        await store.load(icao: "KSFO")
        #expect(!store.isAvailable)
        await store.toggle()
        #expect(!store.isFollowing)
        let service = FakeFavoriteAirportAlertsService()
        let failing = FavoriteAirportAlertsStore(service: service)
        await service.setNextError(.offline)
        await failing.load(icao: "KSFO")
        #expect(!failing.isAvailable && failing.error == nil)
        await failing.load(icao: nil)
        #expect(!failing.isAvailable)
    }

    @Test func onlyTheFAAsAirportsCanAlert() {
        #expect(FavoriteAirportAlertsStore.covers(country: "US"))
        #expect(FavoriteAirportAlertsStore.covers(country: "pr"))
        #expect(!FavoriteAirportAlertsStore.covers(country: "FR"))
    }

    @Test func rowsDecodeAndEncodeLikeTheTable() throws {
        let rows = #"[{"airport_icao":"KSFO"},{"airport_icao":"KJFK"}]"#
        #expect(try SupabaseFavoriteAirportAlertsService.decode(Data(rows.utf8)) == ["KSFO", "KJFK"])
        let data = try JSONEncoder().encode(SupabaseFavoriteAirportAlertsService.Insert(
            user_id: "0f8fad5b-d9cb-469f-a165-70867728950e", airport_icao: "KSFO"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["airport_icao"] as? String == "KSFO")
        #expect(json["user_id"] as? String == "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    @Test func theFakeEnvironmentHasTheService() async throws {
        let env = try await AppEnvironment.fake()
        let all = try await env.favoriteAirportAlerts.followed()
        #expect(all.isEmpty)
    }
}
