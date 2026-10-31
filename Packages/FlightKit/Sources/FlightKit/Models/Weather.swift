import Foundation

public enum FlightCategory: String, Codable, Sendable, Hashable {
    case VFR, MVFR, IFR, LIFR
}

/// One cloud layer of a METAR or TAF period: FEW, SCT, BKN, OVC, VV and so on, base in feet.
public struct CloudLayer: Codable, Sendable, Hashable {
    public var cover: String
    public var baseFt: Int?

    public init(cover: String, baseFt: Int?) { self.cover = cover; self.baseFt = baseFt }
}

/// How a TAF period starts. TEMPO and PROB periods overlap the base or FM period they sit in.
public enum ForecastChange: String, Codable, Sendable, Hashable {
    case FM, BECMG, TEMPO, PROB
}

public struct ForecastPeriod: Codable, Sendable, Hashable {
    public var from: Date
    public var to: Date
    public var category: FlightCategory
    public var windDirDeg: Int?
    public var windKt: Int?
    public var gustKt: Int?
    public var visibilitySm: Double?
    public var ceilingFt: Int?
    // Optional so payloads cached before these fields existed still decode.
    /// Nil for the base forecast.
    public var change: ForecastChange?
    /// Percent, for PROB30 and PROB40 periods.
    public var probability: Int?
    /// Present weather groups ("-RA BR").
    public var wx: String?
    public var clouds: [CloudLayer]?
}

public struct Weather: Codable, Sendable, Hashable {
    public var metarRaw: String
    public var tafRaw: String?
    public var tempC: Double?
    public var windDirDeg: Int?
    public var windKt: Int?
    public var gustKt: Int?
    public var visibilitySm: Double?
    public var ceilingFt: Int?
    public var category: FlightCategory
    public var observedAt: Date
    public var forecast: [ForecastPeriod]
    // Optional so payloads cached before these fields existed still decode.
    /// Present weather groups of the METAR ("-RA BR"); nil when none or not sent (read from `metarRaw` then).
    public var wx: String?
    public var clouds: [CloudLayer]?
    public var dewpointC: Double?
    /// Altimeter setting in hectopascals.
    public var altimeterHpa: Double?
    /// When the TAF was issued.
    public var tafIssuedAt: Date?
}
