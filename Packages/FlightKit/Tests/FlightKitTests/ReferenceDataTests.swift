import Foundation
import Testing
@testable import FlightKit

@Suite struct ReferenceDataTests {
    let ref = ReferenceData.bundled()

    @Test func resolvesAirlineByNameIataIcao() {
        #expect(ref.airline("United")?.id == "UAL")
        #expect(ref.airline("UA")?.id == "UAL")
        #expect(ref.airline("ual")?.id == "UAL")
        #expect(ref.airline("ZZZ") == nil)
    }

    @Test func airlineFromIdent() {
        #expect(ref.airline(ident: "UA990")?.id == "UAL")
        #expect(ref.airline(ident: "B6417")?.id == "JBU")
    }

    @Test func typeFamily() {
        #expect(ref.type("B38M")?.family == .b737max)
        #expect(ref.type("C25B") == nil)
        #expect(AircraftFamily.b777.isWidebody && !AircraftFamily.a320.isWidebody)
    }

    @Test func everyFakeAirlineResolves() throws {
        let past: [PastFlight] = FakeSeed.load("past_flights")
        for name in Set(past.compactMap(\.airline)) {
            #expect(ref.airline(name) != nil, "\(name)")
        }
        for f in past { #expect(ref.airline(ident: f.ident) != nil, "\(f.ident)") }
    }

    @Test func gridOrderHasNine() {
        #expect(WorldRegion.gridOrder.count == 9)
        #expect(Set(WorldRegion.gridOrder) == Set(WorldRegion.allCases))
    }

    @Test func listsDecode() {
        #expect(ref.country("us")?.id == "US")
        #expect(ref.country("AD")?.name == "Andorra")
        #expect(ref.airline("UAL")?.alliance == .starAlliance)
        #expect(ref.airline("UAL")?.website != nil)
        #expect(ref.airlines.allSatisfy { $0.callsign != "" && $0.phone != "" })
        #expect(ref.aircraftNameForB77W == "Boeing 777-300ER")
    }
}

private extension ReferenceData {
    var aircraftNameForB77W: String? { type("B77W")?.name }
}
