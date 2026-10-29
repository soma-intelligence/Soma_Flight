import Testing
import Foundation
import FlightCore
@testable import FlightKit

private func tally(_ key: String, _ flights: UInt32, _ km: UInt64) -> Tally {
    Tally(key: key, flights: flights, distanceKm: km)
}

private func detail(airports: [AirportVisits] = [], airlines: ([Tally], [Tally]) = ([], []),
                    routes: ([Tally], [Tally]) = ([], []), regions: [RegionCount] = []) -> PassportDetail {
    var d = PassportDetail.empty
    d.airports = airports
    d.airlinesByFlights = airlines.0
    d.airlinesByDistance = airlines.1
    d.routesByFlights = routes.0
    d.routesByDistance = routes.1
    d.regions = regions
    return d
}

private let airports: [String: Airport] = [
    "KSFO": Airport(id: "KSFO", iata: "SFO", name: "San Francisco", city: "San Francisco", country: "US",
                    lat: 37.6, lon: -122.4, tz: "America/Los_Angeles"),
    "LFPG": Airport(id: "LFPG", iata: "CDG", name: "Charles de Gaulle", city: "Paris", country: "FR",
                    lat: 49.0, lon: 2.5, tz: "Europe/Paris"),
    "XXNO": Airport(id: "XXNO", iata: nil, name: "No code", city: "Nowhere", country: "US", lat: 0, lon: 0, tz: "UTC"),
]

private func lookup(_ code: String) -> Airport? { airports[code] }

@Suite struct PassportListsTests {
    @Test func regionPercent() {
        #expect(PassportLists.regionPercent(visited: 6, total: 50) == 12)
        #expect(PassportLists.regionPercent(visited: 2, total: 6) == 33)
        #expect(PassportLists.regionPercent(visited: 1, total: 8) == 13) // 12.5 rounds up
        #expect(PassportLists.regionPercent(visited: 1, total: 200) == 1) // 0.5 rounds up
        #expect(PassportLists.regionPercent(visited: 0, total: 13) == 0)
        #expect(PassportLists.regionPercent(visited: 0, total: 0) == 0)
        #expect(PassportLists.regionPercent(visited: 4, total: 4) == 100)

        let d = detail(regions: [RegionCount(region: .northAmerica, visited: 2, total: 6),
                                 RegionCount(region: .europe, visited: 6, total: 50)])
        let rows = PassportLists.regions(d)
        #expect(rows.map(\.region) == WorldRegion.gridOrder)
        #expect(rows[0].visited == 6 && rows[0].percent == 12)
        #expect(rows[1].visited == 2 && rows[1].percent == 33)
        #expect(rows[2].visited == 0 && rows[2].percent == 0) // Asia missing from the core rows
    }

    @Test func routeLabelsUseIata() {
        #expect(PassportLists.routeLabel("LFPG-KSFO", lookup: lookup) == "CDG-SFO")
        #expect(PassportLists.routeLabel("KSFO-EGLL", lookup: lookup) == "SFO-EGLL") // unknown airport
        #expect(PassportLists.routeLabel("XXNO-KSFO", lookup: lookup) == "XXNO-SFO") // known, no IATA
        let d = detail(routes: ([tally("LFPG-KSFO", 3, 26_850)], []),
                       regions: [])
        #expect(PassportLists.routeBars(d, metric: .flights, units: .km, lookup: lookup).map(\.label) == [.code("CDG-SFO")])
        let a = detail(airports: [AirportVisits(icao: "KSFO", visits: 34), AirportVisits(icao: "EDDM", visits: 4)])
        let bars = PassportLists.airportBars(a, lookup: lookup)
        #expect(bars.map(\.label) == [.code("SFO"), .code("EDDM")])
        #expect(bars.map(\.value) == [34, 4])
        #expect(bars.map(\.caption) == ["34", "4"])
    }

    @Test func showMoreRevealsAll() {
        let rows = Array(1...11)
        #expect(PassportLists.visible(rows, limit: PassportLists.barLimit, expanded: false) == Array(1...8))
        #expect(PassportLists.visible(rows, limit: PassportLists.barLimit, expanded: true) == rows)
        #expect(PassportLists.hasMore(rows, limit: PassportLists.barLimit))
        #expect(!PassportLists.hasMore(Array(1...8), limit: PassportLists.barLimit))
        #expect(PassportLists.visible(Array(1...5), limit: PassportLists.countryLimit, expanded: false) == [1, 2, 3])
        #expect(PassportLists.visible(Array(1...2), limit: PassportLists.countryLimit, expanded: false) == [1, 2])
    }

    @Test func distanceToggleUsesDistanceTally() {
        let byFlights = [tally("UAL", 18, 90_000), tally("DLH", 13, 120_000)]
        let byDistance = [tally("DLH", 13, 120_000), tally("UAL", 18, 90_000)]
        let d = detail(airlines: (byFlights, byDistance),
                       routes: ([tally("LFPG-KSFO", 3, 26_850), tally("KSFO-LFPG", 2, 17_900)],
                                [tally("KSFO-LFPG", 2, 30_000), tally("LFPG-KSFO", 3, 26_850)]))
        let flights = PassportLists.airlineBars(d, metric: .flights, units: .km)
        #expect(flights.map(\.id) == ["UAL", "DLH"])
        #expect(flights.map(\.value) == [18, 13])
        #expect(flights.map(\.label) == [.airline("UAL"), .airline("DLH")])
        let distance = PassportLists.airlineBars(d, metric: .distance, units: .km)
        #expect(distance.map(\.id) == ["DLH", "UAL"])
        #expect(distance.map(\.value) == [120_000, 90_000])
        #expect(distance[0].caption == TravelFacts.distance(120_000, .km))
        let routes = PassportLists.routeBars(d, metric: .distance, units: .mi, lookup: lookup)
        #expect(routes.map(\.label) == [.code("SFO-CDG"), .code("CDG-SFO")])
        #expect(routes.map(\.value) == [30_000, 26_850])
        #expect(routes[0].caption == TravelFacts.distance(30_000, .mi))
    }

    @Test func headlines() {
        #expect(PassportLists.total(22, "airport", "airports") == ("22", " total airports"))
        #expect(PassportLists.total(1, "airline", "airlines") == ("1", " total airline"))
        #expect(PassportLists.flights(37) == "37 flights")
        #expect(PassportLists.flights(1) == "1 flight")
    }
}
