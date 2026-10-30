import Foundation
import Testing
@testable import FlightKit

/// Task 18: the airlines and airports the Add Flight sheet offers first.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@Suite struct FrequentlyUsedTests {
    static let ref = ReferenceData.bundled()
    static let airports: [String: Airport] = Dictionary(uniqueKeysWithValues: [
        ("KSFO", "SFO", "San Francisco", "US"), ("LFPG", "CDG", "Paris", "FR"), ("KJFK", "JFK", "New York", "US"),
        ("KATL", "ATL", "Atlanta", "US"), ("CYVR", "YVR", "Vancouver", "CA"), ("KLAX", "LAX", "Los Angeles", "US"),
        ("KAUS", "AUS", "Austin", "US"), ("KDEN", "DEN", "Denver", "US"),
    ].map { ($0.0, Airport(id: $0.0, iata: $0.1, name: "\($0.2) International", city: $0.2, country: $0.3,
                           lat: 0, lon: 0, tz: "UTC")) })
    static let lookup: @Sendable (String) -> Airport? = { airports[$0] }

    static func past(_ ident: String, _ o: String, _ d: String, _ day: String, airline: String? = nil) -> PastFlight {
        PastFlight(date: date("\(day)T12:00:00Z"), ident: ident, originIcao: o, destinationIcao: d, airline: airline,
                   distanceKm: 1000)
    }

    static func followed(_ ident: String, _ o: String, _ d: String, _ day: String, op: String? = nil) -> Flight {
        Flight(providerId: ident, ident: ident, operator: op, originIcao: o, destinationIcao: d,
               scheduledOut: date("\(day)T12:00:00Z"), status: .scheduled)
    }

    private func codes(_ items: [FrequentItem]) -> [String] {
        items.map {
            switch $0 {
            case .airline(let a, let n): "\(a.id):\(n)"
            case .airport(let a, let n): "\(a.id):\(n)"
            }
        }
    }

    @Test func frequentTopTwoEach() {
        let past = [
            Self.past("UA1", "KSFO", "LFPG", "2026-01-01"),
            Self.past("UA2", "KSFO", "KJFK", "2026-01-02", airline: "United Airlines"),
            Self.past("F8100", "CYVR", "KSFO", "2026-01-03"),
            Self.past("DL5", "KJFK", "KATL", "2026-01-04"),
        ]
        let followed = [Self.followed("F8200", "CYVR", "KSFO", "2026-11-01", op: "FLE")]
        let items = FrequentlyUsed.compute(past: past, followed: followed, reference: Self.ref, lookup: Self.lookup)
        // United 2, Flair 2 (Flair flew last), Delta 1; SFO 4, then YVR 2 and JFK 2 (YVR flew last).
        #expect(codes(items) == ["FLE:2", "UAL:2", "KSFO:4", "CYVR:2"])
    }

    @Test func frequentTieBreak() {
        // Same counts, same day: the code decides.
        let past = [
            Self.past("UA1", "KSFO", "KLAX", "2026-01-01"),
            Self.past("AA1", "KSFO", "KLAX", "2026-01-01"),
        ]
        let items = FrequentlyUsed.compute(past: past, followed: [], reference: Self.ref, lookup: Self.lookup)
        #expect(codes(items) == ["AAL:1", "UAL:1", "KLAX:2", "KSFO:2"])
        // A later flight wins the tie.
        let later = past + [Self.past("ZZ1", "KAUS", "KDEN", "2026-03-01"), Self.past("UA9", "KDEN", "KAUS", "2026-02-01")]
        let again = FrequentlyUsed.compute(past: later, followed: [], reference: Self.ref, lookup: Self.lookup)
        #expect(codes(again) == ["UAL:2", "AAL:1", "KAUS:2", "KDEN:2"])
    }

    @Test func frequentSkipsUnknown() {
        let past = [Self.past("ZZ1", "XXXX", "YYYY", "2026-01-01"), Self.past("ZZ2", "XXXX", "KSFO", "2026-01-02")]
        let items = FrequentlyUsed.compute(past: past, followed: [], reference: Self.ref, lookup: Self.lookup)
        #expect(codes(items) == ["KSFO:1"])
        #expect(FrequentlyUsed.compute(past: [], followed: [], reference: Self.ref, lookup: Self.lookup).isEmpty)
    }
}
