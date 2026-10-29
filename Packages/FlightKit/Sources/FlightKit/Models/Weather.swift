import Foundation

public enum FlightCategory: String, Codable, Sendable, Hashable {
    case VFR, MVFR, IFR, LIFR
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
}
