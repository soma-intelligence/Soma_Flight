import Foundation
import FlightCore

/// The full Passport figures (flights, distance, time, airports, airlines, routes, countries), from the
/// Rust core's `computePassportDetail`.
public typealias PassportDetail = FlightCore.PassportDetail
/// Aircraft figures (types, manufacturers, tails, seats, ages), from the Rust core's `computeAircraftStats`.
public typealias AircraftStats = FlightCore.AircraftStats

extension PassportDetail {
    static let empty = FlightCore.computePassportDetail(flights: [], year: nil, countries: [])
}

extension AircraftStats {
    static let empty = FlightCore.computeAircraftStats(flights: [], year: nil, types: [], facts: [], asOf: 0)

    /// Ages are known for at least one airframe; without facts every age section hides.
    var hasAges: Bool { medianAgeMonths != nil }
}

extension WorldRegion {
    var core: FlightCore.Region {
        switch self {
        case .europe: .europe
        case .northAmerica: .northAmerica
        case .centralAmerica: .centralAmerica
        case .caribbean: .caribbean
        case .southAmerica: .southAmerica
        case .africa: .africa
        case .middleEast: .middleEast
        case .asia: .asia
        case .oceania: .oceania
        }
    }
}

extension Country {
    var coreInfo: FlightCore.CountryInfo { FlightCore.CountryInfo(iso2: id, region: region.core) }
}

extension AircraftFact {
    var coreFact: FlightCore.AircraftFact {
        FlightCore.AircraftFact(registration: registration, deliveredAt: deliveredOn.map { Int64($0.timeIntervalSince1970) },
                                name: name)
    }
}

/// Presentation picks over the figures the core computed: which flights a list shows and in what order.
enum PassportPicks {
    /// The delayed flights (the core's 15 minute threshold) that left latest, most late first (ties: the
    /// newest first); canceled flights left out.
    static func mostDelayed(_ flights: [PastFlight], limit: Int = 10) -> [PastFlight] {
        Array(flights
            .filter { $0.status != .canceled && $0.delayMinutes >= PassportStats.delayedThresholdMinutes }
            .sorted { $0.delayMinutes != $1.delayMinutes ? $0.delayMinutes > $1.delayMinutes : $0.date > $1.date }
            .prefix(limit))
    }

    /// The airline (ICAO, as the store maps it) that flew `type` most often in `flights`; ties go to the
    /// code first in alphabetical order. Canceled flights do not count.
    static func topAirline(for type: String, in flights: [PastFlight]) -> String? {
        var counts: [String: Int] = [:]
        for f in flights where f.status != .canceled && f.aircraftType?.uppercased() == type.uppercased() {
            if let a = f.airline, !a.isEmpty { counts[a, default: 0] += 1 }
        }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }
}
