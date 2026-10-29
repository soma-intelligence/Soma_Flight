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
    /// Flights that left 15 minutes late or more (the core's threshold).
    public var delayedFlights: Int
    /// Mean delay of those flights, whole minutes.
    public var avgDelayedMinutes: Int
    public var mostFlownAircraft: (type: String, count: Int)?
    public var routes: [(String, String)]

    public static let empty = PassportStats(
        flights: 0, longHaul: 0, distanceKm: 0, flightTime: .zero, airports: 0, airlines: 0,
        delayLost: .zero, avgDelayMinutes: 0, delayedFlights: 0, avgDelayedMinutes: 0, mostFlownAircraft: nil, routes: [])

    public static func == (a: PassportStats, b: PassportStats) -> Bool {
        a.flights == b.flights && a.longHaul == b.longHaul && a.distanceKm == b.distanceKm
            && a.flightTime == b.flightTime && a.airports == b.airports && a.airlines == b.airlines
            && a.delayLost == b.delayLost && a.avgDelayMinutes == b.avgDelayMinutes
            && a.delayedFlights == b.delayedFlights && a.avgDelayedMinutes == b.avgDelayedMinutes
            && a.mostFlownAircraft?.type == b.mostFlownAircraft?.type
            && a.mostFlownAircraft?.count == b.mostFlownAircraft?.count
            && a.routes.count == b.routes.count
            && zip(a.routes, b.routes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Computes through the Rust core. Canceled flights are excluded, long haul is 4000 km or more,
    /// and `year` matches the local departure date in the origin airport's zone (`originTz`, else UTC).
    /// The core owns the calendar rules, so the `calendar` argument is accepted for call-site
    /// symmetry and not used.
    /// Airlines are mapped to ICAO codes first (`PassportStore.mapped`, bundled reference), so the
    /// counts agree with the store's.
    public static func compute(_ flights: [PastFlight], year: Int?, calendar: Calendar = .current) -> PassportStats {
        let mapped = PassportStore.mapped(flights, reference: .bundled(), airport: PassportStore.bundledAirports)
        return compute(core: mapped.map { $0.coreFlight }, year: year)
    }

    /// A flight this many minutes late or more counts as delayed: the core's threshold
    /// (`DELAYED_MINUTES` in passport.rs), restated for lists that must agree with `delayedFlights`.
    static let delayedThresholdMinutes = 15

    /// The same over flights already in the core's shape (the store maps them once per load).
    static func compute(core: [FlightCore.PastFlight], year: Int?) -> PassportStats {
        let r = FlightCore.computePassport(flights: core, year: year.map(Int32.init))
        return PassportStats(
            flights: Int(r.flights), longHaul: Int(r.longHaul), distanceKm: Int(r.distanceKm),
            flightTime: .seconds(Int64(r.flightMinutes) * 60), airports: Int(r.airports), airlines: Int(r.airlines),
            delayLost: .seconds(Int64(r.delayLostMinutes) * 60), avgDelayMinutes: Int(r.avgDelayMinutes),
            delayedFlights: Int(r.delayedFlights), avgDelayedMinutes: Int(r.avgDelayedMinutes),
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
        let seatClass: FlightCore.SeatClass? = self.seatClass.map {
            switch $0 {
            case .economy: .economy
            case .premiumEconomy: .premiumEconomy
            case .business: .business
            case .first: .first
            }
        }
        let reason: FlightCore.TripReason? = self.reason.map {
            switch $0 {
            case .personal: .personal
            case .business: .business
            }
        }
        return FlightCore.PastFlight(
            departedAt: Int64(date.timeIntervalSince1970), tz: originTz ?? "UTC", ident: ident,
            originIcao: originIcao, destinationIcao: destinationIcao, airline: airline,
            aircraftType: aircraftType, distanceKm: UInt32(max(0, distanceKm)),
            blockMinutes: blockMinutes.map { UInt32(max(0, $0)) },
            delayMinutes: UInt32(max(0, delayMinutes)), status: status,
            originCountry: originCountry, destinationCountry: destinationCountry,
            airMinutes: airMinutes.map { UInt32(max(0, $0)) }, registration: registration,
            seatClass: seatClass, seat: seat, reason: reason)
    }

    /// Local departure year in the origin's zone, matching the core's bucketing.
    var localYear: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: originTz ?? "UTC") ?? .gmt
        return cal.component(.year, from: date)
    }
}

extension AircraftType {
    /// The core's view of a reference type, behind aircraft stats (manufacturers, seat positions).
    var coreTypeInfo: FlightCore.TypeInfo {
        FlightCore.TypeInfo(icaoType: id, family: family.rawValue, manufacturer: manufacturer)
    }
}

extension AircraftFamily {
    /// Window, middle or aisle for a seat ("23A") in this family's economy cabin, from the core;
    /// nil for `.other` and for letters the cabin does not have.
    func seatPosition(_ seat: String) -> FlightCore.SeatPosition? {
        FlightCore.seatPosition(seat: seat, family: rawValue)
    }
}
