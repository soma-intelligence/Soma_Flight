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

    public init(hour: Date, onTime: Int, late15: Int, late45: Int, canceled: Int, diverted: Int) {
        self.hour = hour; self.onTime = onTime; self.late15 = late15
        self.late45 = late45; self.canceled = canceled; self.diverted = diverted
    }

    private enum CodingKeys: String, CodingKey { case hour, onTime, late15, late45, canceled, diverted }

    /// The core emits the hour as integer epoch seconds.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = Date(timeIntervalSince1970: TimeInterval(try c.decode(Int64.self, forKey: .hour)))
        onTime = try c.decode(Int.self, forKey: .onTime)
        late15 = try c.decode(Int.self, forKey: .late15)
        late45 = try c.decode(Int.self, forKey: .late45)
        canceled = try c.decode(Int.self, forKey: .canceled)
        diverted = try c.decode(Int.self, forKey: .diverted)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Int64(hour.timeIntervalSince1970), forKey: .hour)
        try c.encode(onTime, forKey: .onTime)
        try c.encode(late15, forKey: .late15)
        try c.encode(late45, forKey: .late45)
        try c.encode(canceled, forKey: .canceled)
        try c.encode(diverted, forKey: .diverted)
    }
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
