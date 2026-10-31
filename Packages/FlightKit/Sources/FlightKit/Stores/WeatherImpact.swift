import Foundation
import FlightCore

/// Whether the weather is likely slowing an airport, read by the Rust core (`impact.rs`) with the same
/// rules Deno uses. FlightKit's own copy of the core's answer, so views never import FlightCore.
public struct WeatherImpact: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable {
        case none, minor, moderate, severe
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Side: Sendable, Hashable { case arrivals, departures, both }

    public enum HazardKind: Sendable, Hashable {
        case thunderstorm, freezingPrecip, snow, lowCeiling, fog, lowVisibility, wind, heavyRain
    }

    public struct Hazard: Sendable, Hashable {
        public var kind: HazardKind
        public var level: Level
        public var affects: Side
        /// Lowercase noun phrase: "low clouds", "thunderstorms nearby".
        public var label: String
    }

    public var level: Level
    /// True from `moderate` up: the weather is likely slowing the airport.
    public var slows: Bool
    public var affects: Side?
    public var hazards: [Hazard]
    /// One line: "Low clouds and fog: arrivals likely slowed".
    public var reason: String

    /// The impact of explicit conditions. `wx` holds weather groups ("-RA BR") or a whole METAR body.
    public static func of(ceilingFt: Int?, visibilitySm: Double?, windKt: Int?, gustKt: Int?, wx: String) -> WeatherImpact {
        let i = FlightCore.weatherImpact(conditions: WeatherConditions(
            ceilingFt: ceilingFt.map(Self.i32), visibilitySm: visibilitySm,
            windKt: windKt.map(Self.i32), gustKt: gustKt.map(Self.i32), wx: wx))
        return WeatherImpact(
            level: Level(i.level), slows: i.slows, affects: i.affects.map(Side.init),
            hazards: i.hazards.map { Hazard(kind: HazardKind($0.kind), level: Level($0.level), affects: Side($0.affects), label: $0.label) },
            reason: i.reason)
    }

    /// The current conditions of a snapshot. Without the payload's `wx` the groups come from the raw METAR.
    public static func of(_ w: Weather) -> WeatherImpact {
        of(ceilingFt: w.ceilingFt, visibilitySm: w.visibilitySm, windKt: w.windKt, gustKt: w.gustKt,
           wx: w.wx ?? FlightCore.presentWeather(report: w.metarRaw))
    }

    /// One TAF period.
    public static func of(_ p: ForecastPeriod) -> WeatherImpact {
        of(ceilingFt: p.ceilingFt, visibilitySm: p.visibilitySm, windKt: p.windKt, gustKt: p.gustKt, wx: p.wx ?? "")
    }

    /// "light rain and mist" for "-RA BR"; empty without weather groups.
    public static func describe(_ wx: String) -> String { FlightCore.describeWeather(wx: wx) }

    /// The weather groups of a METAR body, without trend groups or remarks.
    public static func groups(in report: String) -> String { FlightCore.presentWeather(report: report) }

    /// Values beyond Int32 are bad data; clamp rather than trap.
    private static func i32(_ v: Int) -> Int32 { Int32(clamping: v) }
}

extension Weather {
    /// Present weather groups of the observation: the payload's, else read from the raw METAR.
    var presentWeather: String { wx ?? WeatherImpact.groups(in: metarRaw) }

    /// The forecast periods in force at `date`: the base or FM period plus any TEMPO or PROB overlay.
    func periods(at date: Date) -> [ForecastPeriod] {
        forecast.filter { $0.from <= date && date < $0.to }
    }

    /// The worst forecast impact at `date` and the period it comes from; nil when no period covers it.
    func forecastImpact(at date: Date) -> (impact: WeatherImpact, period: ForecastPeriod)? {
        periods(at: date)
            .map { (WeatherImpact.of($0), $0) }
            .max { $0.0.level < $1.0.level }
    }
}

private extension WeatherImpact.Level {
    init(_ l: ImpactLevel) {
        self = switch l { case .clear: .none; case .minor: .minor; case .moderate: .moderate; case .severe: .severe }
    }
}

private extension WeatherImpact.Side {
    init(_ a: Affects) {
        self = switch a { case .arrivals: .arrivals; case .departures: .departures; case .both: .both }
    }
}

private extension WeatherImpact.HazardKind {
    init(_ k: FlightCore.HazardKind) {
        self = switch k {
        case .thunderstorm: .thunderstorm
        case .freezingPrecip: .freezingPrecip
        case .snow: .snow
        case .lowCeiling: .lowCeiling
        case .fog: .fog
        case .lowVisibility: .lowVisibility
        case .wind: .wind
        case .heavyRain: .heavyRain
        }
    }
}
