import CoreLocation
import Foundation

/// A famous place a passenger can pick out from the window: a peak, a volcano, a big city, a lake.
public struct Landmark: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case mountain, volcano, city, lake, glacier, island, desert, canyon, waterfall, delta, fjord

        /// Seen only by day: a city still shows at night by its lights.
        public var needsDaylight: Bool { self != .city }

        /// How much a pass of this kind counts when choosing a window side: high relief stands out most.
        public var weight: Double {
            switch self {
            case .mountain, .volcano, .canyon, .glacier, .fjord: 2
            case .city, .lake, .island, .desert, .waterfall, .delta: 1
            }
        }
    }

    /// Wikidata item ("Q583"); nil for the few entered by hand.
    public var id: String?
    public var name: String
    public var kind: Kind
    public var lat: Double
    public var lon: Double
    /// How far from the place a passenger at cruise height still picks it out, km.
    public var radiusKm: Double

    public init(id: String? = nil, name: String, kind: Kind, lat: Double, lon: Double, radiusKm: Double) {
        self.id = id; self.name = name; self.kind = kind; self.lat = lat; self.lon = lon; self.radiusKm = radiusKm
    }

    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, lat, lon
        case radiusKm = "radius_km"
    }
}

/// Which side of the plane something is on, from the plane's heading.
public enum WindowSide: String, Sendable, Hashable, CaseIterable {
    case left, right
    /// Straight under the route: both sides see it, neither better.
    case below

    public var opposite: WindowSide {
        switch self {
        case .left: .right
        case .right: .left
        case .below: .below
        }
    }

    /// The side of a point seen from `from` flying `heading`: the bearing to it against the heading.
    /// Within `belowKm` of the point it is under the plane.
    public static func of(_ target: CLLocationCoordinate2D, from: CLLocationCoordinate2D, heading: Double,
                          belowKm: Double = 8) -> WindowSide {
        if RouteEstimator.distanceKm(from, target) < belowKm { return .below }
        return of(bearing: RouteEstimator.bearing(from, target), heading: heading)
    }

    /// Left when the bearing is to the left of the heading (counter-clockwise), right when to the right.
    /// Dead ahead or dead behind counts as `below` (no side).
    public static func of(bearing: Double, heading: Double, deadZone: Double = 0) -> WindowSide {
        let rel = relative(bearing: bearing, heading: heading)
        if abs(rel) <= deadZone || abs(rel) >= 180 - deadZone { return .below }
        return rel > 0 ? .right : .left
    }

    /// The bearing against the heading, degrees in -180...180: negative to the left, positive to the right.
    public static func relative(bearing: Double, heading: Double) -> Double {
        var r = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }
}

/// The bundled table, `landmarks.json`: built once from Wikidata (CC0) by `Scripts/world/landmarks.py`.
public struct LandmarkTable: Sendable {
    public let landmarks: [Landmark]

    public init(_ landmarks: [Landmark]) { self.landmarks = landmarks }

    private struct File: Decodable { var landmarks: [Landmark] }

    /// The bundled table, read once; empty when the file is missing.
    public static let bundled: LandmarkTable = {
        guard let url = Bundle.module.url(forResource: "landmarks", withExtension: "json", subdirectory: "Reference")
                ?? Bundle.module.url(forResource: "landmarks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return LandmarkTable([]) }
        return LandmarkTable(file.landmarks)
    }()

    public func named(_ name: String) -> Landmark? { landmarks.first { $0.name == name } }
}

/// One landmark passing the plane: when it is nearest, how near, and on which side.
public struct LandmarkPass: Sendable, Equatable, Identifiable {
    public var id: String { "\(landmark.name)@\(time.timeIntervalSince1970)" }
    public var landmark: Landmark
    /// When the plane is nearest (estimated).
    public var time: Date
    public var distanceKm: Double
    public var side: WindowSide
    /// Share of the route flown then, 0...1.
    public var fraction: Double
    /// Estimated height of the plane then, metres.
    public var altitudeM: Double
    /// The sun is up at the landmark then (civil twilight counts as light enough).
    public var inDaylight: Bool

    /// Worth a look: a city at any hour, the rest by day.
    public var isVisible: Bool { inDaylight || !landmark.kind.needsDaylight }
}

/// Landmarks along an estimated route (`RouteEstimator`): every place of the table the airborne track
/// passes within its radius, at its nearest point. Pure and offline.
public enum Landmarks {
    /// Sun elevation, degrees, above which the ground still reads (civil twilight).
    public static let daylightElevation = -6.0

    /// The passes of a route in time order, read from its track every `step` seconds.
    public static func passes(for route: RouteEstimator, table: LandmarkTable = .bundled,
                              step: TimeInterval = 60) -> [LandmarkPass] {
        passes(along: route.track(every: step), distanceKm: route.distanceKm, table: table,
               airports: [route.origin, route.destination])
    }

    /// A city this close to the departure or arrival airport, km past its radius, is where the trip starts
    /// or ends: no sight to point out.
    public static let homeCityMarginKm = 20.0

    /// The passes along any sampled track. Only airborne fixes count: from the ground the airport's own
    /// surroundings are no view. A place the track enters twice (a turn) counts once, at the nearest point.
    /// `airports`: the trip's ends, whose own cities are left out (`homeCityMarginKm`).
    public static func passes(along fixes: [RouteFix], distanceKm: Double? = nil,
                              table: LandmarkTable = .bundled,
                              airports: [CLLocationCoordinate2D] = []) -> [LandmarkPass] {
        let air = fixes.filter { $0.phase.isAirborne }
        guard !air.isEmpty else { return [] }
        let total = distanceKm ?? fixes.last?.distanceKm ?? 0
        let minLat = air.map(\.coordinate.latitude).min()!, maxLat = air.map(\.coordinate.latitude).max()!
        var out: [LandmarkPass] = []
        for l in table.landmarks {
            // A degree of latitude is 111 km: skip what the route never comes near.
            let pad = l.radiusKm / 111
            guard l.lat >= minLat - pad, l.lat <= maxLat + pad else { continue }
            if l.kind == .city,
               airports.contains(where: { RouteEstimator.distanceKm($0, l.coordinate) < l.radiusKm + homeCityMarginKm }) {
                continue
            }
            var best: (fix: RouteFix, km: Double)?
            for f in air {
                let d = RouteEstimator.distanceKm(f.coordinate, l.coordinate)
                if d <= l.radiusKm, best == nil || d < best!.km { best = (f, d) }
            }
            guard let best else { continue }
            let f = best.fix
            let sunUp = SolarPosition.at(l.coordinate, time: f.time).elevation > daylightElevation
            out.append(LandmarkPass(landmark: l, time: f.time, distanceKm: best.km,
                                    side: WindowSide.of(l.coordinate, from: f.coordinate, heading: f.heading),
                                    fraction: total > 0 ? min(1, max(0, f.distanceKm / total)) : 0,
                                    altitudeM: f.altitudeM, inDaylight: sunUp))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// The passes of a flight between two known airports; empty for a canceled or diverted flight.
    public static func passes(_ flight: Flight, origin: Airport?, destination: Airport?, aircraft: AircraftType? = nil,
                              table: LandmarkTable = .bundled) -> [LandmarkPass] {
        guard flight.status != .canceled, flight.status != .diverted, let origin, let destination,
              let route = RouteEstimator(flight: flight, origin: origin.coordinate, destination: destination.coordinate,
                                         aircraft: aircraft) else { return [] }
        return passes(for: route, table: table)
    }
}

/// The words of the "Along the way" card. No SwiftUI, so the tests read the exact text.
enum LandmarkFacts {
    static let title = "Along the way"
    static let subtitle = "What you may see from the window"
    static let caption = "Estimated from the schedule along the direct route. Clouds, haze and the real routing decide what you see."
    /// Lines on the card, the most notable first, then put back in time order.
    static let maxLines = 8

    struct Line: Equatable, Identifiable {
        var id: String
        var kind: Landmark.Kind
        var side: WindowSide
        var time: Date
        var text: String
    }

    /// The visible passes worth a line: at most `maxLines`, the heaviest kinds and nearest first when
    /// there are more, shown in time order.
    static func shown(_ passes: [LandmarkPass]) -> [LandmarkPass] {
        let visible = passes.filter(\.isVisible)
        guard visible.count > maxLines else { return visible }
        let ranked = visible.sorted {
            ($0.landmark.kind.weight, -$0.distanceKm) > ($1.landmark.kind.weight, -$1.distanceKm)
        }
        return Array(ranked.prefix(maxLines)).sorted { $0.time < $1.time }
    }

    /// "On the left", "On the right", "Below".
    static func sideWord(_ s: WindowSide) -> String {
        switch s {
        case .left: "on the left"
        case .right: "on the right"
        case .below: "below"
        }
    }

    /// "Mont Blanc on the left at 14:32 Geneva time". Times as on the sun card: in the zone of the airport
    /// the plane is nearer to along the route.
    static func lines(_ passes: [LandmarkPass], origin: Airport, destination: Airport, clock: TimeStyle) -> [Line] {
        shown(passes).map { p in
            let airport = p.fraction < 0.5 ? origin : destination
            let time = Format.clock(p.time, airport.timeZone, clock)
            return Line(id: p.id, kind: p.landmark.kind, side: p.side, time: p.time,
                        text: "\(p.landmark.name) \(sideWord(p.side)) at \(time) \(airport.city) time")
        }
    }

    /// The SF Symbol of a kind.
    static func symbol(_ k: Landmark.Kind) -> String {
        switch k {
        case .mountain: "mountain.2.fill"
        case .volcano: "mountain.2.fill"
        case .city: "building.2.fill"
        case .lake, .delta, .fjord: "water.waves"
        case .glacier: "snowflake"
        case .island: "beach.umbrella.fill"
        case .desert: "sun.dust.fill"
        case .canyon: "triangle.fill"
        case .waterfall: "drop.fill"
        }
    }
}

/// The local notifications "Mont Blanc on the left in about 5 minutes", planned ahead from the estimate so
/// they fire offline in flight. Off unless the user turns them on (`LandmarkAlertSettings`).
public enum LandmarkAlerts {
    /// How long before the nearest point the alert fires.
    public static let lead: TimeInterval = 5 * 60
    /// At most this many alerts a flight: the most notable.
    public static let maxPerFlight = 5
    /// Only flights taking off within this window get alerts now; later ones are planned at a later sync.
    /// Keeps the pending count well under the system's 64.
    public static let horizon: TimeInterval = 48 * 3600
    /// Passes lower than this (the first minutes of the climb, the last of the descent) get no alert.
    public static let minimumAltitudeM = 3_000.0

    /// `reminder.<flight id>.landmark.<n>`: under the reminders' prefix, so the scheduler's clean-up covers them.
    public static func identifier(_ flight: Flight.ID, _ n: Int) -> String {
        "\(ReminderPlanner.identifierPrefix)\(flight.uuidString.lowercased()).\(ReminderKind.landmark.rawValue).\(n)"
    }

    /// The alerts still ahead for `flight` at `now`, soonest first. Nil airports, a canceled, diverted or
    /// landed flight, or a take-off past `horizon` plan none. A flight already in the air keeps its
    /// remaining alerts, moved to its latest times.
    public static func plan(for flight: Flight, origin: Airport?, destination: Airport?, now: Date,
                            aircraft: AircraftType? = nil, table: LandmarkTable = .bundled) -> [PlannedReminder] {
        guard flight.actualOn == nil, flight.actualIn == nil,
              [.scheduled, .unknown, .departed, .enRoute].contains(flight.status),
              let origin, let destination,
              let route = RouteEstimator(flight: flight, origin: origin.coordinate,
                                         destination: destination.coordinate, aircraft: aircraft),
              route.takeoff.timeIntervalSince(now) <= horizon, route.landing > now else { return [] }
        let passes = Landmarks.passes(for: route, table: table)
            .filter { $0.isVisible && $0.altitudeM >= minimumAltitudeM && $0.time.addingTimeInterval(-lead) > now }
        let chosen = passes.sorted {
            ($0.landmark.kind.weight, -$0.distanceKm) > ($1.landmark.kind.weight, -$1.distanceKm)
        }.prefix(maxPerFlight).sorted { $0.time < $1.time }
        return chosen.enumerated().map { n, p in
            let text = ReminderCopy.landmark(p)
            return PlannedReminder(id: identifier(flight.id, n), flightId: flight.id, kind: .landmark,
                                   fireDate: p.time.addingTimeInterval(-lead), title: text.title, body: text.body)
        }
    }
}

/// The "Landmarks overflown" switch in Settings > Notifications, kept on this device. Off by default.
public enum LandmarkAlertSettings {
    public static let key = "notifications.landmarks"

    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
}
