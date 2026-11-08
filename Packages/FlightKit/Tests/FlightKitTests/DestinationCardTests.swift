import Foundation
@testable import FlightKit
import Testing

/// The destination card: valid bundled values, shown on international flights only, every destination of
/// the demo covered.
@Suite struct DestinationCardTests {
    static let table = DestinationTable.bundled

    static func airport(_ icao: String, _ country: String) -> Airport {
        Airport(id: icao, name: icao, city: icao, country: country, lat: 0, lon: 0, tz: "UTC")
    }

    @Test func everyEntryIsValid() {
        let iso4217 = Set(Locale.Currency.isoCurrencies.map(\.identifier))
        let reference = ReferenceData.bundled()
        #expect(Self.table.countries.count >= 40)
        for c in Self.table.countries {
            #expect(reference.country(c.id) != nil, "\(c.id) is not in countries.json")
            #expect(!c.plugs.isEmpty, "\(c.id)")
            for p in c.plugs { #expect(p.count == 1 && ("A"..."N").contains(p), "\(c.id) plug \(p)") }
            #expect(Set(c.plugs).count == c.plugs.count, "\(c.id)")
            #expect(!c.volts.isEmpty && c.volts.allSatisfy { (100...240).contains($0) }, "\(c.id)")
            #expect(c.currency.wholeMatch(of: /[A-Z]{3}/) != nil, "\(c.id) \(c.currency)")
            #expect(iso4217.contains(c.currency), "\(c.id) \(c.currency) is not ISO 4217")
        }
        #expect(Set(Self.table.countries.map(\.id)).count == Self.table.countries.count)
    }

    @Test func coversTheDemoDestinations() {
        let past: [PastFlight] = FakeSeed.load("past_flights")
        var countries = Set(past.flatMap { [$0.originCountry, $0.destinationCountry] }.compactMap { $0 })
        let directory = AirportDirectory.bundled()
        for f in FakeSeed.flights("followed", shift: 0) {
            for icao in [f.originIcao, f.destinationIcao] { if let c = directory.lookup(icao)?.country { countries.insert(c) } }
        }
        #expect(countries.isSuperset(of: ["US", "FR"]))
        for c in countries { #expect(Self.table.facts(c) != nil, "\(c) missing") }
    }

    @Test func hiddenOnADomesticFlight() {
        #expect(Self.table.card(origin: Self.airport("KSFO", "US"), destination: Self.airport("KAUS", "US")) == nil)
        #expect(Self.table.card(origin: nil, destination: Self.airport("LFPG", "FR")) == nil)
        #expect(Self.table.card(origin: Self.airport("KSFO", "US"), destination: Self.airport("XXXX", "ZZ")) == nil)
        #expect(Self.table.card(origin: Self.airport("KSFO", "US"), destination: Self.airport("LFPG", "FR"))?.id == "FR")
    }

    @Test func theLineIsCompact() throws {
        let fr = try #require(Self.table.facts("fr"))
        #expect(DestinationCardFacts.line(fr) == "Plugs C, E · 230 V · EUR · Tipping: service often included")
        let gb = try #require(Self.table.facts("GB"))
        #expect(DestinationCardFacts.line(gb) == "Plug G · 230 V · GBP · Tipping: about 10%")
        let br = try #require(Self.table.facts("BR"))
        #expect(DestinationCardFacts.volts(br) == "127 V and 220 V")
        #expect(DestinationCardFacts.esim.contains("eSIM"))
    }
}
