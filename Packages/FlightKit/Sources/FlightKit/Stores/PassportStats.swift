import Foundation
import FlightCore

/// Lifetime flight totals. The numbers come from the Rust core so iOS and the backend agree.
public struct PassportStats: Equatable, Sendable {
    public var flights: Int
    public var longHaul: Int
    public var distanceKm: Int
    public var flightTime: Duration
    public var airports: Int
    public var airlines: Int
    public var delayLost: Duration
    public var avgDelayMinutes: Int
    public var mostFlownAircraft: (type: String, count: Int)?
    public var routes: [(String, String)]

    public static let empty = PassportStats(
        flights: 0, longHaul: 0, distanceKm: 0, flightTime: .zero, airports: 0, airlines: 0,
        delayLost: .zero, avgDelayMinutes: 0, mostFlownAircraft: nil, routes: [])

    public static func == (a: PassportStats, b: PassportStats) -> Bool {
        a.flights == b.flights && a.longHaul == b.longHaul && a.distanceKm == b.distanceKm
            && a.flightTime == b.flightTime && a.airports == b.airports && a.airlines == b.airlines
            && a.delayLost == b.delayLost && a.avgDelayMinutes == b.avgDelayMinutes
            && a.mostFlownAircraft?.type == b.mostFlownAircraft?.type
            && a.mostFlownAircraft?.count == b.mostFlownAircraft?.count
            && a.routes.count == b.routes.count
            && zip(a.routes, b.routes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Computes through the Rust core. Canceled flights are excluded, long haul is 4000 km or more,
    /// and `year` matches the local departure date in the origin airport's zone (`originTz`, else UTC).
    /// The core owns the calendar rules, so the `calendar` argument is accepted for call-site
    /// symmetry and not used.
    public static func compute(_ flights: [PastFlight], year: Int?, calendar: Calendar = .current) -> PassportStats {
        let core = flights.map { $0.coreFlight }
        let r = FlightCore.computePassport(flights: core, year: year.map(Int32.init))
        return PassportStats(
            flights: Int(r.flights), longHaul: Int(r.longHaul), distanceKm: Int(r.distanceKm),
            flightTime: .seconds(Int64(r.flightMinutes) * 60), airports: Int(r.airports), airlines: Int(r.airlines),
            delayLost: .seconds(Int64(r.delayLostMinutes) * 60), avgDelayMinutes: Int(r.avgDelayMinutes),
            mostFlownAircraft: r.mostFlownAircraft.map { (type: $0.aircraftType, count: Int($0.count)) },
            routes: r.routes.map { ($0.origin, $0.destination) })
    }
}

extension PastFlight {
    var coreFlight: FlightCore.PastFlight {
        let status: FlightCore.PastFlightStatus = switch self.status {
        case .completed: .completed
        case .canceled: .canceled
        case .diverted: .diverted
        }
        return FlightCore.PastFlight(
            departedAt: Int64(date.timeIntervalSince1970), tz: originTz ?? "UTC", ident: ident,
            originIcao: originIcao, destinationIcao: destinationIcao, airline: airline,
            aircraftType: aircraftType, distanceKm: UInt32(max(0, distanceKm)),
            blockMinutes: blockMinutes.map { UInt32(max(0, $0)) },
            delayMinutes: UInt32(max(0, delayMinutes)), status: status)
    }

    /// Local departure year in the origin's zone, matching the core's bucketing.
    var localYear: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: originTz ?? "UTC") ?? .gmt
        return cal.component(.year, from: date)
    }
}
