import Foundation
@testable import FlightKit
import Testing

/// CO2 per flight (docs/co2-method.md): DESNZ 2025 passenger factors with RF, by haul and seat class.
@Suite struct FlightEmissionsTests {
    /// kg CO2e per passenger.km from the DESNZ 2025 flat file ("Business travel- air", With RF).
    static let reference: [(FlightEmissions.Haul, SeatClass, Double)] = [
        (.shortHaul, .economy, 0.12576), (.shortHaul, .business, 0.18863),
        (.longHaul, .economy, 0.11704), (.longHaul, .premiumEconomy, 0.18726),
        (.longHaul, .business, 0.33940), (.longHaul, .first, 0.46814),
        (.domestic, .economy, 0.22928),
    ]

    @Test func factorsMatchTheTableToOnePercent() {
        for (haul, seat, value) in Self.reference {
            let f = FlightEmissions.factor(haul, seatClass: seat)!
            #expect(abs(f - value) / value < 0.01, "\(haul) \(seat)")
        }
    }

    @Test func referenceFlightsMatchToOnePercent() {
        // Paris to Rome, 1,105 km, economy: 1,105 x 0.12576 = 138.96 kg.
        let rome = FlightEmissions.kilograms(km: 1_105, seatClass: .economy, origin: "FR", destination: "IT")!
        #expect(abs(rome - 138.96) / 138.96 < 0.01)
        // San Francisco to Paris, 8,950 km, business: 8,950 x 0.33940 = 3,037.6 kg.
        let sfo = FlightEmissions.kilograms(km: 8_950, seatClass: .business, origin: "US", destination: "FR")!
        #expect(abs(sfo - 3_037.6) / 3_037.6 < 0.01)
        // London to Edinburgh, 534 km: domestic, one factor for all classes.
        let edi = FlightEmissions.kilograms(km: 534, seatClass: .first, origin: "GB", destination: "GB")!
        #expect(abs(edi - 122.44) / 122.44 < 0.01)
    }

    @Test func haulFollowsTheDistanceAndTheUK() {
        #expect(FlightEmissions.haul(km: 3_699) == .shortHaul)
        #expect(FlightEmissions.haul(km: 3_700) == .longHaul)
        #expect(FlightEmissions.haul(km: 600, origin: "gb", destination: "GB") == .domestic)
        // Only the UK has a domestic factor; a long US domestic flight is long-haul by distance.
        #expect(FlightEmissions.haul(km: 4_150, origin: "US", destination: "US") == .longHaul)
        #expect(FlightEmissions.haul(km: 600, origin: "US", destination: "US") == .shortHaul)
    }

    @Test func classDefaults() {
        // Unknown class: economy.
        #expect(FlightEmissions.factor(.longHaul, seatClass: nil) == FlightEmissions.factor(.longHaul, seatClass: .economy))
        // Short-haul has economy and business only.
        #expect(FlightEmissions.factor(.shortHaul, seatClass: .premiumEconomy) == FlightEmissions.factor(.shortHaul, seatClass: .economy))
        #expect(FlightEmissions.factor(.shortHaul, seatClass: .first) == FlightEmissions.factor(.shortHaul, seatClass: .business))
        // No factor for a private flight.
        #expect(FlightEmissions.factor(.longHaul, seatClass: .private) == nil)
        #expect(FlightEmissions.kilograms(km: 900, seatClass: .private) == nil)
    }

    @Test func zeroDistanceIsZero() {
        #expect(FlightEmissions.kilograms(km: 0, seatClass: .business) == 0)
        #expect(FlightEmissions.kilograms(km: -5, seatClass: nil) == 0)
    }

    @Test func totalsSkipCanceledAndPrivateFlights() {
        let d = Date(timeIntervalSince1970: 1_780_000_000)
        let flights = [
            PastFlight(date: d, ident: "AF1", originIcao: "LFPG", destinationIcao: "LIRF", distanceKm: 1_000, seatClass: .economy),
            PastFlight(date: d, ident: "AF2", originIcao: "LFPG", destinationIcao: "LIRF", distanceKm: 1_000, status: .canceled),
            PastFlight(date: d, ident: "N1", originIcao: "LFPG", destinationIcao: "LIRF", distanceKm: 1_000, seatClass: .private),
            PastFlight(date: d, ident: "AF3", originIcao: "LFPG", destinationIcao: "KJFK", distanceKm: 5_840),
        ]
        let t = FlightEmissions.total(flights)
        #expect(t.flights == 2)
        #expect(abs(t.kilograms - (1_000 * 0.12576 + 5_840 * 0.11704)) < 0.001)
    }

    @Test func amountsReadPlainly() {
        #expect(EmissionsFacts.amount(0) == "0 kg")
        #expect(EmissionsFacts.amount(7.6) == "8 kg")
        #expect(EmissionsFacts.amount(138.96) == "140 kg")
        #expect(EmissionsFacts.amount(3_037.6) == "3.0 t")
        #expect(EmissionsFacts.amount(12_480) == "12 t")
        #expect(EmissionsFacts.basis(nil) == "One passenger in Economy, non-CO2 effects included")
        #expect(!EmissionsFacts.source.contains("\u{2014}"))
    }

    @MainActor @Test func passportTotalsTheSelectedYear() async {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        let all = store.emissions
        store.year = 2025
        let year = store.emissions
        #expect(all.flights > year.flights && year.flights > 0)
        #expect(all.kilograms > year.kilograms && year.kilograms > 0)
    }

    @Test func theMethodDocumentStatesTheFactors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/co2-method.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        for (_, _, value) in Self.reference { #expect(text.contains(String(format: "%.5f", value)), "\(value)") }
        #expect(!text.contains("\u{2014}"))
    }
}
