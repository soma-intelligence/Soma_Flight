import CoreLocation
import Foundation

/// Which window side to sit on, and why: the sunrise or sunset, the landmarks (`Landmarks`), and where the
/// sun sits by day. Worked out from the estimated route alone, offline.
public struct WindowAdvice: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case sunrise(region: String?)
        case sunset(region: String?)
        /// Landmark names on the side, the most notable first.
        case landmarks([String])
        /// The sun stays on the other side most of the day.
        case shade
    }

    /// `.left` or `.right`.
    public var side: WindowSide
    public var reasons: [Reason]
    /// Notable landmarks on the other side, the most notable first.
    public var otherSide: [String]
    /// The side the sun sits on for most of the daylight part of the flight; nil when it moves around,
    /// stays ahead or behind, or the flight is in the dark.
    public var sunSide: WindowSide?
}

/// The side a seat is on, from its letter.
public enum SeatSide: String, Sendable, Equatable {
    case left, right
    /// The middle block of a twin-aisle cabin, away from both windows.
    case center
}

public enum WindowAdvisor {
    /// What a sunrise or sunset weighs against landmarks (`Landmark.Kind.weight`: a peak 2, a city 1).
    public static let sunEventWeight = 3.0
    /// Sun higher than this, degrees, counts as daylight in the window (lower is the sunrise or sunset itself).
    public static let sunLow = 8.0
    /// Sun higher than this mostly lights the roof, not the side windows.
    public static let sunHigh = 60.0
    /// Within this many degrees of the nose or the tail, the sun or a sight is on neither side.
    public static let deadZone = 20.0
    /// The sun has a side when it sits there this share of the daylight minutes...
    public static let sunShare = 0.7
    /// ...over at least this long.
    public static let sunMinimum: TimeInterval = 45 * 60

    /// The advice for a route, from its landmark passes and its sun events; nil when neither side stands out.
    public static func advice(for route: RouteEstimator, passes: [LandmarkPass], events: [SunEvent],
                              regions: RegionNamer? = .bundled, step: TimeInterval = 60) -> WindowAdvice? {
        advice(track: route.track(every: step), passes: passes, events: events, regions: regions, step: step)
    }

    static func advice(track: [RouteFix], passes: [LandmarkPass], events: [SunEvent], regions: RegionNamer?,
                       step: TimeInterval) -> WindowAdvice? {
        var score: [WindowSide: Double] = [.left: 0, .right: 0]
        var sunReasons: [WindowSide: [WindowAdvice.Reason]] = [.left: [], .right: []]
        for e in events {
            let side = WindowSide.of(bearing: e.azimuth, heading: e.heading, deadZone: deadZone)
            guard side != .below else { continue }
            score[side, default: 0] += sunEventWeight
            let region = regions?.region(at: e.coordinate)?.phrase
            sunReasons[side, default: []].append(e.kind == .sunrise ? .sunrise(region: region) : .sunset(region: region))
        }
        var names: [WindowSide: [LandmarkPass]] = [.left: [], .right: []]
        for p in passes where p.isVisible && p.side != .below {
            score[p.side, default: 0] += p.landmark.kind.weight
            names[p.side, default: []].append(p)
        }
        func ranked(_ s: WindowSide) -> [String] {
            (names[s] ?? []).sorted {
                ($0.landmark.kind.weight, -$0.distanceKm) > ($1.landmark.kind.weight, -$1.distanceKm)
            }.map(\.landmark.name)
        }

        let sunSide = self.sunSide(track: track, step: step)
        let l = score[.left] ?? 0, r = score[.right] ?? 0
        let side: WindowSide
        if l > r {
            side = .left
        } else if r > l {
            side = .right
        } else if let sunSide {
            side = sunSide.opposite  // nothing to see either way, or a tie: the shade decides
        } else {
            return nil
        }
        var reasons = sunReasons[side] ?? []
        let mine = ranked(side)
        if !mine.isEmpty { reasons.append(.landmarks(Array(mine.prefix(2)))) }
        if sunSide == side.opposite { reasons.append(.shade) }
        guard !reasons.isEmpty else { return nil }
        return WindowAdvice(side: side, reasons: reasons, otherSide: Array(ranked(side.opposite).prefix(2)),
                            sunSide: sunSide)
    }

    /// The side the sun keeps by day: airborne minutes with the sun between `sunLow` and `sunHigh`, counted
    /// by side; nil unless one side holds `sunShare` of them over `sunMinimum`.
    static func sunSide(track: [RouteFix], step: TimeInterval) -> WindowSide? {
        var left = 0.0, right = 0.0, all = 0.0
        for f in track where f.phase.isAirborne {
            let s = SolarPosition.at(f.coordinate, time: f.time)
            guard s.elevation > sunLow, s.elevation < sunHigh else { continue }
            all += step
            switch WindowSide.of(bearing: s.azimuth, heading: f.heading, deadZone: deadZone) {
            case .left: left += step
            case .right: right += step
            case .below: break
            }
        }
        guard all >= sunMinimum else { return nil }
        if left >= sunShare * all { return .left }
        if right >= sunShare * all { return .right }
        return nil
    }

    /// The side of a seat ("23A") from its letter: A and B on the left everywhere, and C too except on the
    /// four-abreast types (ATR, CRJ, E-jets: A B on the left, C D on the right); on a single-aisle plane D to
    /// F (and G) on the right; on a twin-aisle plane D to G in the middle block and H to L on the right.
    /// Nil when the seat has no letter, or a middle letter on an unknown type.
    public static func seatSide(_ seat: String, family: AircraftFamily?) -> SeatSide? {
        guard let letter = seat.uppercased().last(where: \.isLetter) else { return nil }
        switch letter {
        case "A", "B": return .left
        case "C": return family.map(isFourAbreast) == true ? .right : .left
        case "H", "J", "K", "L": return .right
        case "D", "E", "F", "G":
            guard let family, family != .other else { return nil }
            return family.isWidebody ? .center : .right
        default: return nil
        }
    }

    /// Two seats each side of one aisle, lettered A B | C D on most of them.
    static func isFourAbreast(_ family: AircraftFamily) -> Bool {
        switch family {
        case .atr, .crj, .ejet: true
        default: false
        }
    }
}

/// The words of the "Window seat" card. No SwiftUI, so the tests read the exact text.
enum WindowFacts {
    static let title = "Window seat"
    static let subtitle = "Which side to pick"
    static let caption = "Estimated from the schedule along the direct route. Seat letters vary by airline and cabin."

    struct Card: Equatable {
        var side: WindowSide
        var headline: String
        var lines: [String]
        /// The one line the minimal card shows under the headline: the traveller's seat when known, else the
        /// window letter on that side.
        var short: String = ""
    }

    /// The advice for a flight between two known airports, nil when nothing stands out or for a canceled
    /// or diverted flight.
    static func advice(_ flight: Flight, origin: Airport?, destination: Airport?, aircraft: AircraftType?,
                       table: LandmarkTable = .bundled, regions: RegionNamer? = .bundled) -> WindowAdvice? {
        guard flight.status != .canceled, flight.status != .diverted, let origin, let destination,
              let route = RouteEstimator(flight: flight, origin: origin.coordinate, destination: destination.coordinate,
                                         aircraft: aircraft) else { return nil }
        return WindowAdvisor.advice(for: route, passes: Landmarks.passes(for: route, table: table),
                                    events: SunInFlight.events(for: route), regions: regions)
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func sideWord(_ s: WindowSide) -> String { s == .left ? "left" : "right" }

    /// "Sit on the left for the sunset over the North Atlantic and Mont Blanc", and the lines under it: the
    /// seat letters, the sun by day, the other side's sights, and the traveller's own seat when known.
    static func card(_ a: WindowAdvice, seat: String?, family: AircraftFamily?) -> Card {
        let side = sideWord(a.side), other = sideWord(a.side.opposite)
        var why: [String] = []
        for r in a.reasons {
            switch r {
            case .sunrise(let region): why.append("the sunrise" + (region.map { " \($0)" } ?? ""))
            case .sunset(let region): why.append("the sunset" + (region.map { " \($0)" } ?? ""))
            case .landmarks(let names): why += names
            case .shade: break
            }
        }
        let headline = why.isEmpty ? "Sit on the \(side) for the shade" : "Sit on the \(side) for \(list(why))"

        var lines: [String] = []
        lines.append(a.side == .left
                     ? "Window seats on the left are lettered A on most aircraft."
                     : "Window seats on the right take the row's last letter: F on most single-aisle planes, K on most twin-aisle ones.")
        if let sun = a.sunSide {
            lines.append(sun == a.side
                         ? "The sun stays on the \(side) for most of the day, so keep the blind handy."
                         : "The sun stays on the \(other) for most of the day, so the \(side) side is in the shade.")
        }
        if !a.otherSide.isEmpty {
            lines.append("On the \(other): \(list(a.otherSide)).")
        }
        var short = a.side == .left ? "Window seats are A" : "Window seats are F or K"
        if let seat, let s = WindowAdvisor.seatSide(seat, family: family) {
            short = s == .center ? "Your seat \(seat) is in the middle block"
                : s.rawValue == a.side.rawValue ? "Your seat \(seat) is on the good side"
                : "Your seat \(seat) is on the \(other)"
            switch s {
            case .center:
                lines.append("Your seat \(seat) is in the middle block, away from the windows.")
            case .left, .right:
                lines.append(s.rawValue == a.side.rawValue
                             ? "Your seat \(seat) is on the \(side), the good side."
                             : "Your seat \(seat) is on the \(other). A seat on the \(side) gets the better view.")
            }
        }
        return Card(side: a.side, headline: headline, lines: lines, short: short)
    }
}
