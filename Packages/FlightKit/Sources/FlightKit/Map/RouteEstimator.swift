import CoreLocation
import Foundation

/// Where a flight is in its trip, as `RouteEstimator` sees it.
public enum FlightPhase: String, Sendable, Codable, CaseIterable {
    /// Still on the ground at the origin (at the gate or taxiing out).
    case beforeTakeoff
    case climbing
    case cruise
    case descending
    /// On the ground at the destination.
    case landed

    public var isAirborne: Bool { self == .climbing || self == .cruise || self == .descending }
}

/// One estimated point of a flight: where, which way and how high at `time`.
public struct RouteFix: Sendable, Equatable {
    public var time: Date
    public var coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from true north, 0..<360, along the great circle.
    public var heading: Double
    public var phase: FlightPhase
    /// Flown so far along the great circle, km.
    public var distanceKm: Double
    /// Estimated height above the sea, metres (0 on the ground).
    public var altitudeM: Double

    public init(time: Date, coordinate: CLLocationCoordinate2D, heading: Double, phase: FlightPhase,
                distanceKm: Double, altitudeM: Double) {
        self.time = time; self.coordinate = coordinate; self.heading = heading; self.phase = phase
        self.distanceKm = distanceKm; self.altitudeM = altitudeM
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.time == b.time && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude && a.heading == b.heading && a.phase == b.phase
            && a.distanceKm == b.distanceKm && a.altitudeM == b.altitudeM
    }
}

/// The position of a flight worked out on the device from its times alone, with no live data: the great
/// circle between the two airports, flown between the take-off and the landing with a simple speed
/// profile. Pure Swift, no network, no Rust call, so it runs offline and in tests.
///
/// The profile: ground speed ramps linearly from `rampStart` of cruise speed at take-off to cruise speed
/// at the end of the climb (`climbDuration`), holds, then ramps back down over the descent
/// (`descentDuration`). Cruise speed is whatever makes the distance fit the airborne time, so the plane is
/// at the destination exactly at the landing time. Short flights shrink the climb and the descent to at
/// most 30 and 35 percent of the airborne time. Wind, holding and routing off the great circle are not
/// modelled: on a long haul the estimate can be some 100 km off.
///
/// Altitude climbs linearly to `cruiseAltitudeM` and comes down the same way; it feeds the horizon dip
/// of `SunInFlight` and the later window and landmark features.
public struct RouteEstimator: Sendable {
    public let origin: CLLocationCoordinate2D
    public let destination: CLLocationCoordinate2D
    public let takeoff: Date
    public let landing: Date
    /// Great-circle distance, km.
    public let distanceKm: Double
    /// Cruise ground speed that fits the distance into the airborne time, km/h.
    public let cruiseSpeedKmh: Double
    /// Seconds of climb and of descent actually used (shorter on short hops).
    public let climbSeconds: TimeInterval
    public let descentSeconds: TimeInterval
    /// Cruise height for this distance, metres.
    public let cruiseAltitudeM: Double

    /// Typical climb to cruise height on an airliner.
    public static let climbDuration: TimeInterval = 20 * 60
    /// Typical descent from cruise height to the runway.
    public static let descentDuration: TimeInterval = 25 * 60
    /// Ground speed at take-off and at touchdown, as a share of cruise speed.
    public static let rampStart = 0.3
    /// Gate to runway and runway to gate, when only gate times are known.
    public static let taxiOut: TimeInterval = 15 * 60
    public static let taxiIn: TimeInterval = 7 * 60
    /// Mean Earth radius, km.
    public static let earthRadiusKm = 6371.0

    /// Between two runway times. Nil when the landing is not after the take-off.
    public init?(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, takeoff: Date, landing: Date) {
        let airborne = landing.timeIntervalSince(takeoff)
        guard airborne > 0 else { return nil }
        self.origin = origin; self.destination = destination; self.takeoff = takeoff; self.landing = landing
        let d = Self.distanceKm(origin, destination)
        distanceKm = d
        climbSeconds = min(Self.climbDuration, airborne * 0.3)
        descentSeconds = min(Self.descentDuration, airborne * 0.35)
        let effective = airborne - (1 - Self.rampStart) / 2 * (climbSeconds + descentSeconds)
        cruiseSpeedKmh = effective > 0 ? d / (effective / 3600) : 0
        cruiseAltitudeM = Self.cruiseAltitude(distanceKm: d)
    }

    /// From the gate departure and the block time (gate to gate): the taxi allowances come off both ends.
    public init?(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, gateDeparture: Date,
                 blockTime: TimeInterval) {
        self.init(origin: origin, destination: destination, takeoff: gateDeparture.addingTimeInterval(Self.taxiOut),
                  landing: gateDeparture.addingTimeInterval(blockTime - Self.taxiIn))
    }

    /// From the take-off and a cruise speed (the aircraft type's, `typicalCruiseKmh`), when no landing time
    /// is known. The airborne time is the one that profile needs for the distance.
    public init?(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, takeoff: Date,
                 cruiseSpeedKmh: Double) {
        guard cruiseSpeedKmh > 0 else { return nil }
        let d = Self.distanceKm(origin, destination)
        // The climb and descent shrink on short hops, which changes the time they cost: settle it in a few rounds.
        var airborne = d / cruiseSpeedKmh * 3600 + (1 - Self.rampStart) / 2 * (Self.climbDuration + Self.descentDuration)
        for _ in 0..<4 {
            let c = min(Self.climbDuration, airborne * 0.3), s = min(Self.descentDuration, airborne * 0.35)
            airborne = d / cruiseSpeedKmh * 3600 + (1 - Self.rampStart) / 2 * (c + s)
        }
        self.init(origin: origin, destination: destination, takeoff: takeoff,
                  landing: takeoff.addingTimeInterval(max(60, airborne)))
    }

    /// The estimator for a flight from its best known times:
    /// - take-off: actual, else estimated runway time, else the gate departure (actual, estimated) plus
    ///   `taxiOut`, else the scheduled runway time, else the scheduled gate departure plus `taxiOut`;
    /// - landing: the same order on the arrival side, minus `taxiIn` from gate times;
    /// - no usable landing: the aircraft type's typical cruise speed (`typicalCruiseKmh`).
    public init?(flight f: Flight, origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
                 aircraft: AircraftType? = nil) {
        let takeoff = f.actualOff ?? f.estimatedOff ?? (f.actualOut ?? f.estimatedOut).map { $0.addingTimeInterval(Self.taxiOut) }
            ?? f.scheduledOff ?? f.scheduledOut.map { $0.addingTimeInterval(Self.taxiOut) }
        guard let takeoff else { return nil }
        let landing = f.actualOn ?? f.estimatedOn ?? (f.actualIn ?? f.estimatedIn).map { $0.addingTimeInterval(-Self.taxiIn) }
            ?? f.scheduledOn ?? f.scheduledIn.map { $0.addingTimeInterval(-Self.taxiIn) }
        if let landing, landing > takeoff.addingTimeInterval(5 * 60) {
            self.init(origin: origin, destination: destination, takeoff: takeoff, landing: landing)
        } else {
            self.init(origin: origin, destination: destination, takeoff: takeoff,
                      cruiseSpeedKmh: Self.typicalCruiseKmh(aircraft?.family))
        }
    }

    /// Typical cruise ground speed in still air by family, km/h (about Mach 0.78 to 0.85 at 11 km for jets).
    public static func typicalCruiseKmh(_ family: AircraftFamily?) -> Double {
        switch family {
        case .atr: 510
        case .crj, .ejet: 800
        case .a220, .a320, .b737, .b737max, .b757: 830
        case .a330, .a350, .a380, .b747, .b767, .b777, .b787: 900
        case .other, nil: 830
        }
    }

    /// Cruise height by trip length: 11 km from 1,000 km up, down to 6 km for a 200 km hop.
    public static func cruiseAltitude(distanceKm d: Double) -> Double {
        let t = min(max((d - 200) / 800, 0), 1)
        return 6_000 + 5_000 * t
    }

    /// Airborne time, seconds.
    public var airborneSeconds: TimeInterval { landing.timeIntervalSince(takeoff) }

    /// The phase at `t`.
    public func phase(at t: Date) -> FlightPhase {
        if t < takeoff { return .beforeTakeoff }
        if t >= landing { return .landed }
        let tau = t.timeIntervalSince(takeoff)
        if tau < climbSeconds { return .climbing }
        if landing.timeIntervalSince(t) < descentSeconds { return .descending }
        return .cruise
    }

    /// Distance flown at `t`, km, 0 before take-off and the full distance after landing.
    public func distanceFlown(at t: Date) -> Double {
        let tau = t.timeIntervalSince(takeoff)
        guard tau > 0 else { return 0 }
        guard t < landing else { return distanceKm }
        let v = cruiseSpeedKmh / 3600, k = Self.rampStart
        let c = climbSeconds, s = descentSeconds
        let s0: Double
        if tau < c {
            s0 = v * (k * tau + (1 - k) * tau * tau / (2 * c))
        } else if tau <= airborneSeconds - s {
            s0 = v * c * (1 + k) / 2 + v * (tau - c)
        } else {
            let r = airborneSeconds - tau
            s0 = distanceKm - v * (k * r + (1 - k) * r * r / (2 * s))
        }
        return min(max(s0, 0), distanceKm)
    }

    /// Estimated height at `t`, metres.
    public func altitude(at t: Date) -> Double {
        switch phase(at: t) {
        case .beforeTakeoff, .landed: return 0
        case .cruise: return cruiseAltitudeM
        case .climbing: return cruiseAltitudeM * t.timeIntervalSince(takeoff) / climbSeconds
        case .descending: return cruiseAltitudeM * landing.timeIntervalSince(t) / descentSeconds
        }
    }

    /// The estimated fix at `t`: at the origin before take-off, at the destination after landing.
    public func position(at t: Date) -> RouteFix {
        let s = distanceFlown(at: t)
        let f = distanceKm > 0 ? s / distanceKm : 1
        let c = Self.point(from: origin, to: destination, fraction: f)
        return RouteFix(time: t, coordinate: c, heading: heading(atFraction: f), phase: phase(at: t),
                        distanceKm: s, altitudeM: altitude(at: t))
    }

    /// Fixes every `step` seconds from take-off to landing, both included: the sampled track the sun,
    /// window side and landmark features read.
    public func track(every step: TimeInterval = 60) -> [RouteFix] {
        let step = max(step, 1)
        var out: [RouteFix] = []
        var t = takeoff
        while t < landing {
            out.append(position(at: t))
            t = t.addingTimeInterval(step)
        }
        out.append(position(at: landing))
        return out
    }

    /// Points along the great circle, `segments + 1` of them, endpoints included, longitudes in [-180, 180]
    /// (split them with `mapSegments` before drawing).
    public func routePoints(segments: Int = 128) -> [CLLocationCoordinate2D] {
        let n = max(1, segments)
        return (0...n).map { Self.point(from: origin, to: destination, fraction: Double($0) / Double(n)) }
    }

    /// Heading along the great circle `fraction` of the way: the bearing on to the destination, or at the
    /// very end the bearing of the last stretch.
    private func heading(atFraction f: Double) -> Double {
        if f < 0.999 {
            return Self.bearing(Self.point(from: origin, to: destination, fraction: f), destination)
        }
        return Self.bearing(Self.point(from: origin, to: destination, fraction: 0.998), destination)
    }

    // MARK: Spherical helpers

    /// Haversine distance, km.
    public static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        earthRadiusKm * angle(a, b)
    }

    /// Central angle between two points, radians.
    static func angle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// The point `fraction` of the way from `a` to `b` on the great circle (spherical interpolation),
    /// longitude in [-180, 180]. Safe across the antimeridian.
    public static func point(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                             fraction: Double) -> CLLocationCoordinate2D {
        let f = min(max(fraction, 0), 1)
        let d = angle(a, b)
        guard d > 1e-12 else { return a }
        let p1 = a.latitude * .pi / 180, l1 = a.longitude * .pi / 180
        let p2 = b.latitude * .pi / 180, l2 = b.longitude * .pi / 180
        let wa = sin((1 - f) * d) / sin(d), wb = sin(f * d) / sin(d)
        let x = wa * cos(p1) * cos(l1) + wb * cos(p2) * cos(l2)
        let y = wa * cos(p1) * sin(l1) + wb * cos(p2) * sin(l2)
        let z = wa * sin(p1) + wb * sin(p2)
        let lat = atan2(z, sqrt(x * x + y * y)) * 180 / .pi
        let lon = atan2(y, x) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: normalizedLongitude(lon))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north in 0..<360.
    public static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (p1, p2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}
