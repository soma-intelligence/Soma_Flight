import Foundation
import FlightCore

public extension DelayStats {
    /// Stats for any subset of board flights (a filtered board, or departures and arrivals together),
    /// computed by the Rust core with the same rules the backend uses for `airport_stats`.
    /// Each flight is read from the side of `kind`; pass pairs to mix both boards.
    static func compute(_ flights: [(flight: Flight, kind: BoardKind)]) -> DelayStats {
        let rows = flights.map { f, kind in
            let arrival = kind == .arrivals
            return BoardFlight(
                ident: f.ident, operator: f.operator,
                otherIcao: arrival ? f.originIcao : f.destinationIcao,
                status: f.status.core,
                scheduled: (arrival ? f.scheduledIn : f.scheduledOut).map(Self.epoch),
                estimated: (arrival ? f.estimatedIn : f.estimatedOut).map(Self.epoch),
                actual: (arrival ? f.actualIn : f.actualOut).map(Self.epoch))
        }
        let s = FlightCore.computeStats(rows: rows)
        let severity: Severity = switch s.severity { case .normal: .normal; case .moderate: .moderate; case .major: .major }
        return DelayStats(
            total: Int(s.total), onTime: Int(s.onTime), delayed15: Int(s.delayed15), canceled: Int(s.canceled),
            avgDelayMinutes: s.avgDelayMinutes,
            perHour: s.perHour.map {
                HourBucket(hour: Date(timeIntervalSince1970: TimeInterval($0.hour)), onTime: Int($0.onTime),
                           late15: Int($0.late15), late45: Int($0.late45), canceled: Int($0.canceled), diverted: Int($0.diverted))
            },
            worstRoutes: s.worstRoutes.map { RouteDelay(icao: $0.icao, delayed: Int($0.delayed), canceled: Int($0.canceled)) },
            worstAirlines: s.worstAirlines.map { AirlineDelay(operator: $0.operator, delayed: Int($0.delayed), canceled: Int($0.canceled)) },
            severity: severity)
    }

    static func compute(_ flights: [Flight], kind: BoardKind) -> DelayStats {
        compute(flights.map { ($0, kind) })
    }

    private static func epoch(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }
}

extension FlightStatus {
    var core: FlightCore.FlightStatus {
        switch self {
        case .scheduled: .scheduled
        case .departed: .departed
        case .enRoute: .enRoute
        case .landed: .landed
        case .arrived: .arrived
        case .canceled: .canceled
        case .diverted: .diverted
        case .unknown: .unknown
        }
    }
}
