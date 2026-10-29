import Testing
import Foundation
@testable import FlightKit

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func fixture() -> [PastFlight] {
    [
        PastFlight(date: iso("2025-03-01T18:00:00Z"), ident: "AF83", originIcao: "KSFO", destinationIcao: "LFPG",
                   airline: "Air France", aircraftType: "A359", distanceKm: 8970, blockMinutes: 640, delayMinutes: 12,
                   originTz: "America/Los_Angeles"),
        PastFlight(date: iso("2025-06-10T18:00:00Z"), ident: "UA1527", originIcao: "KAUS", destinationIcao: "KSFO",
                   airline: "United", aircraftType: "A359", distanceKm: 2400, blockMinutes: 235, delayMinutes: 0,
                   originTz: "America/Chicago"),
        PastFlight(date: iso("2026-01-01T07:30:00Z"), ident: "DL2204", originIcao: "KSFO", destinationIcao: "KAUS",
                   airline: "Delta", aircraftType: "B739", distanceKm: 2400, blockMinutes: 230, delayMinutes: 30,
                   originTz: "America/Los_Angeles"),
        PastFlight(date: iso("2025-08-01T12:00:00Z"), ident: "AS1", originIcao: "KSEA", destinationIcao: "KSFO",
                   airline: "Alaska", aircraftType: "B739", distanceKm: 1090, blockMinutes: 120, delayMinutes: 500,
                   status: .canceled, originTz: "America/Los_Angeles"),
    ]
}

@Suite struct PassportStatsTests {
    @Test func passportStatsAllTime() {
        let s = PassportStats.compute(fixture(), year: nil, calendar: .current)
        #expect(s.flights == 3)
        #expect(s.longHaul == 1)
        #expect(s.distanceKm == 8970 + 2400 + 2400)
        #expect(s.flightTime == .seconds((640 + 235 + 230) * 60))
        #expect(s.airports == 3) // KSFO, LFPG, KAUS; canceled KSEA excluded
        #expect(s.airlines == 3)
        #expect(s.delayLost == .seconds(42 * 60))
        #expect(s.mostFlownAircraft?.count == 2)
        #expect(s.mostFlownAircraft?.type == "A359")
    }

    @Test func passportStatsYearFilter() {
        // DL2204 departs 2026-01-01 UTC but 2025-12-31 in Los Angeles.
        let s25 = PassportStats.compute(fixture(), year: 2025, calendar: .current)
        #expect(s25.flights == 3)
        let s26 = PassportStats.compute(fixture(), year: 2026, calendar: .current)
        #expect(s26.flights == 0)
        let utc = fixture().map { var f = $0; f.originTz = nil; return f }
        #expect(PassportStats.compute(utc, year: 2026, calendar: .current).flights == 1)
    }

    @Test func passportStatsEmpty() {
        let s = PassportStats.compute([], year: nil, calendar: .current)
        #expect(s == PassportStats.empty)
        #expect(s.flights == 0 && s.distanceKm == 0 && s.flightTime == .zero)
        #expect(s.mostFlownAircraft == nil)
    }
    @Test func coreFlightCarriesDetailFields() {
        let f = PastFlight(date: iso("2025-03-01T18:00:00Z"), ident: "AF83", originIcao: "KSFO", destinationIcao: "LFPG",
                           airline: "AFR", registration: "F-HTYA", seat: "7A", distanceKm: 8970, blockMinutes: 640,
                           seatClass: .premiumEconomy, reason: .business, originCountry: "US",
                           destinationCountry: "FR", airMinutes: 615)
        let c = f.coreFlight
        #expect(c.originCountry == "US" && c.destinationCountry == "FR")
        #expect(c.airMinutes == 615 && c.registration == "F-HTYA" && c.seat == "7A")
        #expect(c.seatClass == .premiumEconomy && c.reason == .business)
        var bare = f
        bare.originCountry = nil; bare.airMinutes = -5; bare.seatClass = nil; bare.reason = nil
        #expect(bare.coreFlight.originCountry == nil && bare.coreFlight.airMinutes == 0)
        #expect(bare.coreFlight.seatClass == nil && bare.coreFlight.reason == nil)
    }
    @Test func coreTypeInfoCarriesFamilyCode() {
        let t = AircraftType(id: "B38M", family: .b737max, manufacturer: "Boeing", name: "Boeing 737 MAX 8")
        let c = t.coreTypeInfo
        #expect(c.icaoType == "B38M" && c.family == "b737max" && c.manufacturer == "Boeing")
    }
    @Test func everyFamilyCodeIsKnownToTheCore() {
        // Seat A is a window in every economy cabin the core knows; `.other` has none.
        for family in AircraftFamily.allCases {
            #expect((family.seatPosition("1A") == .window) == (family != .other), "\(family)")
        }
        #expect(AircraftFamily.a320.seatPosition("12B") == .middle)
        #expect(AircraftFamily.b777.seatPosition("40G") == .aisle)
        #expect(AircraftFamily.crj.seatPosition("3E") == nil)
    }
}
