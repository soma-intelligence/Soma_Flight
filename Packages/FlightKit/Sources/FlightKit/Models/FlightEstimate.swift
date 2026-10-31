import CoreLocation
import Foundation

/// Where a flight probably is when the app cannot hear about it: the device is offline, or the flight is
/// in the air and its last update is older than `staleAfter` (airline Wi-Fi that lets only messages
/// through). Worked out on the device from the last times it knows: the share of the best gate-to-gate
/// time elapsed (`Flight.progress(at:)`, the Live Activity's rule), placed on the great circle between
/// the two airports (the Rust core's `greatCircle`). Always shown as an estimate, with the time of the
/// last real update.
public struct FlightEstimate: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The device has no connection.
        case offline
        /// Online, but the flight in the air has had no update for a while.
        case stale
    }

    public var reason: Reason
    /// 0...1 of the trip, from the best departure to the best arrival.
    public var progress: Double
    /// On the great circle at `progress`; nil when an airport is unknown.
    public var coordinate: CLLocationCoordinate2D?
    /// Degrees clockwise from north along the great circle there.
    public var heading: Double?
    /// The flight's last real update.
    public var lastUpdate: Date
    /// The best arrival time has passed with no landing heard: probably down.
    public var probablyLanded: Bool

    /// An update older than this, in the air, is no longer live.
    public static let staleAfter: TimeInterval = 5 * 60
    /// Points on the great circle the position is read from (about 20 km apart on a long haul).
    static let segments = 512

    public static func == (a: Self, b: Self) -> Bool {
        a.reason == b.reason && a.progress == b.progress && a.heading == b.heading && a.lastUpdate == b.lastUpdate
            && a.probablyLanded == b.probablyLanded
            && a.coordinate?.latitude == b.coordinate?.latitude && a.coordinate?.longitude == b.coordinate?.longitude
    }

    /// The estimate for `flight` at `now`, or nil when the app should show what it has: the flight is not
    /// in the air (or, offline, not due to be), it is over (landed, arrived, canceled, diverted), or it is
    /// online and fresh.
    /// - Parameters:
    ///   - origin, destination: the two airports, for the position; nil leaves `coordinate` nil.
    ///   - online: the device's connection (`Connectivity`).
    public static func make(for flight: Flight, origin: CLLocationCoordinate2D?, destination: CLLocationCoordinate2D?,
                            online: Bool, now: Date) -> FlightEstimate? {
        let airborne: Bool
        switch flight.status {
        case .departed, .enRoute:
            airborne = true
        case .scheduled, .unknown:
            // Offline, a flight whose departure time passed is probably flying: the app cannot hear the
            // take-off. Online, the backend would have said, so it stays scheduled.
            guard !online, let out = flight.actualOut ?? flight.estimatedOut ?? flight.scheduledOut, out <= now,
                  let inn = flight.estimatedIn ?? flight.scheduledIn,
                  now < inn.addingTimeInterval(3 * 3600) else { return nil }
            airborne = true
        case .landed, .arrived, .canceled, .diverted:
            return nil
        }
        guard airborne else { return nil }
        let lastUpdate = max(flight.updatedAt, flight.position?.at ?? .distantPast)
        let stale = now.timeIntervalSince(lastUpdate) > staleAfter
        guard !online || stale else { return nil }

        let p = progress(of: flight, at: now)
        let due = flight.actualOn ?? flight.estimatedOn ?? flight.estimatedIn ?? flight.scheduledIn
        var estimate = FlightEstimate(reason: online ? .stale : .offline, progress: p, coordinate: nil, heading: nil,
                                      lastUpdate: lastUpdate, probablyLanded: due.map { now >= $0 } ?? false)
        if let origin, let destination {
            let (c, h) = point(from: origin, to: destination, at: p)
            estimate.coordinate = c; estimate.heading = h
        }
        return estimate
    }

    /// `Flight.progress(at:)`, with the departure read as the best estimate when the flight left on paper
    /// only (offline, no actual time).
    static func progress(of f: Flight, at now: Date) -> Double {
        f.progress(at: now)
    }

    /// The point `fraction` of the way along the great circle, and the heading there.
    static func point(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                      at fraction: Double) -> (CLLocationCoordinate2D, Double) {
        let path = greatCircle(from: a, to: b, segments: segments)
        let x = min(max(fraction, 0), 1) * Double(path.count - 1)
        let i = min(Int(x.rounded(.down)), path.count - 2)
        let t = x - Double(i)
        let p0 = path[i], p1 = path[i + 1]
        // Neighbours are close and their longitudes unwrapped, so a straight blend between them stays on the arc.
        let c = CLLocationCoordinate2D(latitude: p0.latitude + (p1.latitude - p0.latitude) * t,
                                       longitude: normalizedLongitude(p0.longitude + (p1.longitude - p0.longitude) * t))
        return (c, bearing(p0, p1))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north in 0..<360.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (p1, p2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "Estimated, last update 14:02" (the device's zone and clock setting).
    public func label(style: TimeStyle = .h24, timeZone: TimeZone = .current) -> String {
        "Estimated, last update \(Format.clock(lastUpdate, timeZone, style))"
    }

    /// One line under the label: what the estimate is based on.
    public var detail: String {
        if probablyLanded { return "Probably landed. Times and gates will update when you are back online." }
        switch reason {
        case .offline: return "No connection. Progress is worked out from the last known times."
        case .stale: return "No live update for a while. Progress is worked out from the last known times."
        }
    }
}

public extension Flight {
    /// The estimate for this flight now, with the airports from `lookup`.
    func estimate(online: Bool, now: Date = .now, lookup: (String) -> Airport?) -> FlightEstimate? {
        FlightEstimate.make(for: self, origin: lookup(originIcao)?.coordinate,
                            destination: lookup(destinationIcao)?.coordinate, online: online, now: now)
    }
}
