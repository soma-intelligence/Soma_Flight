import Testing
import Foundation
import FlightCore
@testable import FlightKit

private func flight(_ day: Int, km: Int = 8_950, minutes: Int? = 640) -> FlightKit.PastFlight {
    FlightKit.PastFlight(date: Date(timeIntervalSince1970: 1_767_268_800 + Double(day) * 86_400),
                         ident: "UA\(900 + day)", originIcao: "KSFO", destinationIcao: "LFPG", airline: "United",
                         aircraftType: "B77W", registration: nil, distanceKm: km, blockMinutes: minutes, delayMinutes: 0,
                         status: .completed, originTz: "America/Los_Angeles")
}

private func detail(_ flights: [FlightKit.PastFlight]) -> PassportDetail {
    FlightCore.computePassportDetail(flights: flights.map(\.coreFlight), year: nil, countries: [])
}

@Suite struct FullPassportTests {
    private let issued = Date(timeIntervalSince1970: 1_793_275_200) // 2026-10-29T12:00Z

    @Test func mrzLinesAre44() {
        let lines = PassportFacts.mrz(name: "Quentin Caron", year: nil, flights: 57, issued: issued, timeZone: .gmt)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count == 44 })
        #expect(lines[0].hasPrefix("P<SOMAFLIGHT<<QUENTIN<CARON<"))
        #expect(lines[1].hasPrefix("ALLTIME<<FLIGHTS57<<ISSUED261029<"))
        let year = PassportFacts.mrz(name: nil, year: 2025, flights: 12, issued: issued, timeZone: .gmt)
        #expect(year[1].hasPrefix("2025<<FLIGHTS12<<"))
        // A very long name is cut, never longer than the line.
        let long = PassportFacts.mrz(name: String(repeating: "Bartholomew ", count: 8), year: nil, flights: 1, issued: issued)
        #expect(long.allSatisfy { $0.count == 44 })
    }

    @Test func mrzOnlyAllowedCharacters() {
        for name in ["José-María  de la Peña", "Zoë O'Brien", "Łukasz Żółć", "  Ana   Lúcia ", "李 小龍", "Ann 3rd!"] {
            let lines = PassportFacts.mrz(name: name, year: 2024, flights: 3, issued: issued)
            for line in lines {
                #expect(line.count == 44)
                #expect(line.allSatisfy { PassportFacts.mrzAlphabet.contains($0) }, "\(name): \(line)")
            }
        }
        #expect(PassportFacts.mrzName("José-María  de la Peña") == "JOSE<MARIA<DE<LA<PENA")
    }

    @Test func mrzDefaultName() {
        #expect(PassportFacts.mrz(name: nil, year: nil, flights: 0, issued: issued)[0].hasPrefix("P<SOMAFLIGHT<<TRAVELLER<"))
        #expect(PassportFacts.mrz(name: "  ", year: nil, flights: 0, issued: issued)[0].hasPrefix("P<SOMAFLIGHT<<TRAVELLER<"))
        #expect(PassportFacts.mrz(name: "李", year: nil, flights: 0, issued: issued)[0].hasPrefix("P<SOMAFLIGHT<<TRAVELLER<"))
    }

    @Test func ratioCopy() {
        let d = detail([flight(1, km: 280_017)])
        #expect(d.distanceKm == 280_017)
        let r = PassportFacts.ratios(d)
        #expect(r.map(\.value) == ["7.0x", "0.7x", "0.06x"])
        #expect(r.map(\.label) == ["around the Earth", "to the Moon", "around the Sun"])
        #expect(r.map(\.symbol) == ["globe.americas.fill", "moon.fill", "sun.max.fill"])
    }

    @Test func timeUnits() {
        let units = PassportFacts.timeUnits(minutes: 21_548)
        #expect(units.map(\.label) == ["Days", "Weeks", "Months", "Years"])
        #expect(units.map(\.value) == ["15.0", "2.1", "0.5", "0.04"])
        #expect(PassportFacts.hoursMinutes(21_548).map { $0.number + $0.unit } == ["359h", "8m"])
        #expect(PassportFacts.hoursMinutes(42).map { $0.number + $0.unit } == ["42m"])
    }

    @Test func landJsonUnder150KB() throws {
        let url = try #require(WorldLand.url)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 150_000)
        let land = WorldLand.load()
        #expect(land.rings.count > 100)
        #expect(land.rings.allSatisfy { $0.count >= 4 })
        #expect(land.rings.joined().allSatisfy { abs($0.x) <= 180 && abs($0.y) <= 90 })
    }

    @Test func sparseHidesShortestLongest() {
        #expect(!PassportFacts.showsExtremes(detail([])))
        #expect(!PassportFacts.showsExtremes(detail([flight(1)])))
        #expect(PassportFacts.showsExtremes(detail([flight(1), flight(2, km: 500, minutes: 70)])))
    }

    @Test func routesPairOncePerDirection() {
        let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco", city: "San Francisco", country: "US",
                          lat: 37.6, lon: -122.4, tz: "America/Los_Angeles")
        let cdg = Airport(id: "LFPG", iata: "CDG", name: "Charles de Gaulle", city: "Paris", country: "FR",
                          lat: 49.0, lon: 2.5, tz: "Europe/Paris")
        var back = flight(3)
        back.originIcao = "LFPG"; back.destinationIcao = "KSFO"
        let d = detail([flight(1), flight(2), back])
        let routes = PassportFacts.routes(d) { ["KSFO": sfo, "LFPG": cdg][$0] }
        #expect(routes.count == 1)
        #expect(PassportFacts.spacedIdent("AC413") == "AC 413")
        #expect(PassportFacts.spacedIdent("B6417") == "B6 417")
    }
}

@Suite struct PassportChartTicksTests {
    @Test func ticksCoverTheTallestBar() {
        #expect(PassportFacts.ticks(max: 11).values == [0, 5, 10, 15])
        #expect(PassportFacts.ticks(max: 9).values == [0, 5, 10])
        #expect(PassportFacts.ticks(max: 3).values == [0, 1, 2, 3])
        #expect(PassportFacts.ticks(max: 0).values == [0, 1])
        #expect(PassportFacts.ticks(max: 57).top == 60)
    }
}
