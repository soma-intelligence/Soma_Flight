import Foundation
import CoreLocation

/// When a followed flight is over, and the history row it becomes. An hour after it reached the gate (or
/// was due to, for a canceled one) it leaves My Flights and shows in Passport straight away; the server's
/// hourly archive (`archive_landed_flights`, same hour) then stores the real row, which takes its place.
public enum LandedFlights {
    /// How long a finished flight stays in My Flights after its arrival.
    public static let grace: TimeInterval = 60 * 60

    /// True once `f` has arrived, landed, been canceled or diverted, and its arrival (actual, else
    /// estimated, else scheduled) is more than `grace` ago. A finished flight with no arrival time at all
    /// stays, as it does on the server.
    public static func isOver(_ f: Flight, now: Date) -> Bool {
        let finished: Set<FlightStatus> = [.arrived, .landed, .canceled, .diverted]
        let end: Date? = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn
        guard finished.contains(f.status), let end else { return false }
        return end.addingTimeInterval(grace) < now
    }

    /// `f` as the archive would store it: departure time, airline, aircraft, distance between the
    /// airports, block and air times, delays. Read only (`source` archive), its id the flight's.
    public static func pastFlight(_ f: Flight, airport: (String) -> Airport?) -> PastFlight {
        let from = airport(f.originIcao), to = airport(f.destinationIcao)
        let flown = f.status != .canceled
        let left: Date? = f.actualOut ?? f.scheduledOut ?? f.estimatedOut
        let came: Date? = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn
        let date = left ?? came ?? f.updatedAt
        let distance = from.flatMap { a in to.map { b in
            Int(distanceKm(CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                           CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)).rounded())
        } } ?? 0
        let block = flown ? minutes(f.actualOut, f.actualIn).flatMap { $0 > 0 ? $0 : nil } : nil
        let air = flown ? minutes(f.actualOff, f.actualOn).flatMap { $0 > 0 ? $0 : nil } : nil
        let arrival = flown ? (minutes(f.scheduledIn, f.actualIn) ?? minutes(f.scheduledOn, f.actualOn)) : nil
        let departure = flown ? (minutes(f.scheduledOut, f.actualOut) ?? minutes(f.scheduledOff, f.actualOff)) : nil
        let status: PastFlightStatus = switch f.status {
        case .canceled: .canceled
        case .diverted: .diverted
        default: .completed
        }
        return PastFlight(id: f.id, date: date, ident: f.ident, originIcao: f.originIcao,
                          destinationIcao: f.destinationIcao, airline: f.operator, aircraftType: f.aircraftType,
                          registration: f.registration, distanceKm: distance, blockMinutes: block,
                          delayMinutes: status == .completed ? max(0, arrival ?? 0) : 0, status: status,
                          originTz: from?.tz, originCountry: from?.country, destinationCountry: to?.country,
                          airMinutes: air, source: .archive,
                          arrivalDelayMinutes: status == .completed ? arrival : nil,
                          departureDelayMinutes: departure)
    }

    /// True when `a` and `b` are the same flight: same number, same airports, leaving within 12 hours of
    /// each other. How a landed row finds the archived one that replaces it.
    public static func same(_ a: PastFlight, _ b: PastFlight) -> Bool {
        key(a.ident) == key(b.ident) && a.originIcao == b.originIcao && a.destinationIcao == b.destinationIcao
            && abs(a.date.timeIntervalSince(b.date)) < 12 * 60 * 60
    }

    private static func key(_ ident: String) -> String {
        ident.uppercased().filter { !$0.isWhitespace }
    }

    private static func minutes(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to else { return nil }
        return Int((to.timeIntervalSince(from) / 60).rounded())
    }
}
