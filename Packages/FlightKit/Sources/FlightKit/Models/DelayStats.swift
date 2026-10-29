import Foundation

public enum Severity: String, Codable, Sendable, Hashable {
    case normal, moderate, major
}

public struct HourBucket: Codable, Sendable, Hashable {
    public var hour: Date
    public var onTime: Int
    public var late15: Int
    public var late45: Int
    public var canceled: Int
    public var diverted: Int
}

public struct RouteDelay: Codable, Sendable, Hashable {
    public var icao: String
    public var delayed: Int
    public var canceled: Int
}

public struct AirlineDelay: Codable, Sendable, Hashable {
    public var `operator`: String
    public var delayed: Int
    public var canceled: Int
}

/// Mirrors the core's `computeStats` JSON (camelCase).
public struct DelayStats: Codable, Sendable, Hashable {
    public var total: Int
    public var onTime: Int
    public var delayed15: Int
    public var canceled: Int
    public var avgDelayMinutes: Double
    public var perHour: [HourBucket]
    public var worstRoutes: [RouteDelay]
    public var worstAirlines: [AirlineDelay]
    public var severity: Severity
}
