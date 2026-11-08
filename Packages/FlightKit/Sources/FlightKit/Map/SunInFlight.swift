import CoreLocation
import Foundation

/// A sunrise or a sunset as seen from the plane.
public struct SunEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case sunrise, sunset }

    public var kind: Kind
    public var time: Date
    /// Where the plane is then (estimated).
    public var coordinate: CLLocationCoordinate2D
    /// The plane's heading then, degrees from true north.
    public var heading: Double
    /// Where the sun is then, degrees from true north (with `heading`, the window side).
    public var azimuth: Double
    /// Estimated height of the plane, metres.
    public var altitudeM: Double
    /// Share of the route flown, 0...1.
    public var fraction: Double

    public static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.time == b.time && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude && a.heading == b.heading && a.azimuth == b.azimuth
            && a.altitudeM == b.altitudeM && a.fraction == b.fraction
    }
}

/// Sunrises and sunsets along an estimated route (`RouteEstimator` plus `SolarPosition`).
///
/// The sun counts as up when its geometric centre is above `standardHorizon` (-0.833 degrees: 34 minutes
/// of refraction plus the 16 minute half disc, the almanac rule for a sea-level horizon) lowered by the
/// horizon dip at the plane's height, `horizonDip`: from 11 km the sea horizon sits about 3.4 degrees below
/// level, so the sun sets some 15 to 25 minutes later than on the ground below. The dip is the geometric
/// one; the thinner air aloft bends light a little less than at sea level, which this leaves out (well
/// under a minute). Only the airborne part of the trip is read: on the ground the airport's own times apply.
public enum SunInFlight {
    /// The almanac's sea-level horizon for the sun's centre, degrees.
    public static let standardHorizon = -0.833

    /// How far below level the sea horizon lies from `altitudeM` metres, degrees: acos(R / (R + h)).
    public static func horizonDip(altitudeM h: Double) -> Double {
        guard h > 0 else { return 0 }
        let r = RouteEstimator.earthRadiusKm * 1_000
        return acos(r / (r + h)) * 180 / .pi
    }

    /// The sun's geometric elevation at which it rises or sets as seen from `altitudeM`.
    public static func horizon(altitudeM h: Double) -> Double { standardHorizon - horizonDip(altitudeM: h) }

    /// The events of a flight, read from its track every `step` seconds and placed between samples.
    public static func events(for route: RouteEstimator, step: TimeInterval = 60) -> [SunEvent] {
        events(along: route.track(every: step), distanceKm: route.distanceKm)
    }

    /// The events along any sampled track (fixes in time order), for callers with their own fixes.
    public static func events(along fixes: [RouteFix], distanceKm: Double? = nil) -> [SunEvent] {
        guard fixes.count >= 2 else { return [] }
        let total = distanceKm ?? fixes.last!.distanceKm
        func margin(_ f: RouteFix) -> Double {
            SolarPosition.at(f.coordinate, time: f.time).geometricElevation - horizon(altitudeM: f.altitudeM)
        }
        var out: [SunEvent] = []
        var previous = fixes[0], m0 = margin(previous)
        for fix in fixes.dropFirst() {
            let m1 = margin(fix)
            if (m0 > 0) != (m1 > 0) {
                let t = m0 == m1 ? 0 : m0 / (m0 - m1)
                let time = previous.time.addingTimeInterval(fix.time.timeIntervalSince(previous.time) * t)
                let coordinate = RouteEstimator.point(from: previous.coordinate, to: fix.coordinate, fraction: t)
                let km = previous.distanceKm + (fix.distanceKm - previous.distanceKm) * t
                out.append(SunEvent(kind: m1 > 0 ? .sunrise : .sunset, time: time, coordinate: coordinate,
                                    heading: fix.heading, azimuth: SolarPosition.at(coordinate, time: time).azimuth,
                                    altitudeM: previous.altitudeM + (fix.altitudeM - previous.altitudeM) * t,
                                    fraction: total > 0 ? min(1, max(0, km / total)) : 0))
            }
            previous = fix; m0 = m1
        }
        return out
    }
}

/// The words of the "Sun in flight" card. No SwiftUI, so the tests read the exact text.
///
/// Times: each event is given in the local time of the airport the plane is nearer to along the route
/// (the origin for the first half, the destination for the second), named by its city ("Paris time"), the
/// way the sheet gives each departure and arrival time in its own airport's zone.
enum SunFacts {
    static let title = "Sun in flight"
    static let subtitle = "Seen from the plane"
    static let caption = "Estimated from the schedule along the direct route, at cruise height. Times are approximate."

    struct Line: Equatable, Identifiable {
        var id: Date { time }
        var kind: SunEvent.Kind
        var time: Date
        var text: String
    }

    /// One line per event: "Sunset over the North Atlantic at 19:42 Paris time".
    static func lines(_ events: [SunEvent], origin: Airport, destination: Airport, clock: TimeStyle,
                      regions: RegionNamer = .bundled) -> [Line] {
        events.map { e in
            let airport = e.fraction < 0.5 ? origin : destination
            let word = e.kind == .sunrise ? "Sunrise" : "Sunset"
            let place = regions.region(at: e.coordinate).map { " \($0.phrase)" } ?? ""
            let time = Format.clock(e.time, airport.timeZone, clock)
            return Line(kind: e.kind, time: e.time, text: "\(word)\(place) at \(time) \(airport.city) time")
        }
    }

    /// The events for a flight between two known airports; empty for a canceled or diverted flight.
    static func events(_ flight: Flight, origin: Airport?, destination: Airport?, aircraft: AircraftType?) -> [SunEvent] {
        guard flight.status != .canceled, flight.status != .diverted, let origin, let destination,
              let route = RouteEstimator(flight: flight, origin: origin.coordinate, destination: destination.coordinate,
                                         aircraft: aircraft) else { return [] }
        return SunInFlight.events(for: route)
    }
}
