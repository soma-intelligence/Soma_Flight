import Foundation

public struct Flight: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var providerId: String
    public var ident: String
    public var `operator`: String?
    public var originIcao: String
    public var originIata: String?
    public var destinationIcao: String
    public var destinationIata: String?
    public var scheduledOut: Date?
    public var scheduledIn: Date?
    public var estimatedOut: Date?
    public var estimatedIn: Date?
    public var actualOut: Date?
    public var actualOff: Date?
    public var actualOn: Date?
    public var actualIn: Date?
    public var gateOrigin: String?
    public var gateDestination: String?
    public var terminalOrigin: String?
    public var terminalDestination: String?
    public var baggageBelt: String?
    public var aircraftType: String?
    public var registration: String?
    public var status: FlightStatus
    public var position: Position?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), providerId: String, ident: String, operator: String? = nil,
        originIcao: String, originIata: String? = nil, destinationIcao: String, destinationIata: String? = nil,
        scheduledOut: Date? = nil, scheduledIn: Date? = nil, estimatedOut: Date? = nil, estimatedIn: Date? = nil,
        actualOut: Date? = nil, actualOff: Date? = nil, actualOn: Date? = nil, actualIn: Date? = nil,
        gateOrigin: String? = nil, gateDestination: String? = nil,
        terminalOrigin: String? = nil, terminalDestination: String? = nil, baggageBelt: String? = nil,
        aircraftType: String? = nil, registration: String? = nil, status: FlightStatus = .scheduled,
        position: Position? = nil, updatedAt: Date = .now
    ) {
        self.id = id; self.providerId = providerId; self.ident = ident; self.operator = `operator`
        self.originIcao = originIcao; self.originIata = originIata
        self.destinationIcao = destinationIcao; self.destinationIata = destinationIata
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn
        self.estimatedOut = estimatedOut; self.estimatedIn = estimatedIn
        self.actualOut = actualOut; self.actualOff = actualOff; self.actualOn = actualOn; self.actualIn = actualIn
        self.gateOrigin = gateOrigin; self.gateDestination = gateDestination
        self.terminalOrigin = terminalOrigin; self.terminalDestination = terminalDestination
        self.baggageBelt = baggageBelt; self.aircraftType = aircraftType; self.registration = registration
        self.status = status; self.position = position; self.updatedAt = updatedAt
    }

    // Keys after .convertFromSnakeCase. Position is flat columns in the database.
    private enum CodingKeys: String, CodingKey {
        case id, providerId, ident, `operator`
        case originIcao, originIata, destinationIcao, destinationIata
        case scheduledOut, scheduledIn, estimatedOut, estimatedIn
        case actualOut, actualOff, actualOn, actualIn
        case gateOrigin, gateDestination, terminalOrigin, terminalDestination, baggageBelt
        case aircraftType, registration, status
        case positionLat, positionLon, positionAltitudeFt, positionGroundSpeedKt, positionHeading, positionAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        providerId = try c.decode(String.self, forKey: .providerId)
        ident = try c.decode(String.self, forKey: .ident)
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        originIcao = try c.decode(String.self, forKey: .originIcao)
        originIata = try c.decodeIfPresent(String.self, forKey: .originIata)
        destinationIcao = try c.decode(String.self, forKey: .destinationIcao)
        destinationIata = try c.decodeIfPresent(String.self, forKey: .destinationIata)
        scheduledOut = try c.decodeIfPresent(Date.self, forKey: .scheduledOut)
        scheduledIn = try c.decodeIfPresent(Date.self, forKey: .scheduledIn)
        estimatedOut = try c.decodeIfPresent(Date.self, forKey: .estimatedOut)
        estimatedIn = try c.decodeIfPresent(Date.self, forKey: .estimatedIn)
        actualOut = try c.decodeIfPresent(Date.self, forKey: .actualOut)
        actualOff = try c.decodeIfPresent(Date.self, forKey: .actualOff)
        actualOn = try c.decodeIfPresent(Date.self, forKey: .actualOn)
        actualIn = try c.decodeIfPresent(Date.self, forKey: .actualIn)
        gateOrigin = try c.decodeIfPresent(String.self, forKey: .gateOrigin)
        gateDestination = try c.decodeIfPresent(String.self, forKey: .gateDestination)
        terminalOrigin = try c.decodeIfPresent(String.self, forKey: .terminalOrigin)
        terminalDestination = try c.decodeIfPresent(String.self, forKey: .terminalDestination)
        baggageBelt = try c.decodeIfPresent(String.self, forKey: .baggageBelt)
        aircraftType = try c.decodeIfPresent(String.self, forKey: .aircraftType)
        registration = try c.decodeIfPresent(String.self, forKey: .registration)
        status = try c.decode(FlightStatus.self, forKey: .status)
        if let lat = try c.decodeIfPresent(Double.self, forKey: .positionLat),
           let lon = try c.decodeIfPresent(Double.self, forKey: .positionLon),
           let at = try c.decodeIfPresent(Date.self, forKey: .positionAt) {
            position = Position(
                lat: lat, lon: lon,
                altitudeFt: try c.decodeIfPresent(Int.self, forKey: .positionAltitudeFt),
                groundSpeedKt: try c.decodeIfPresent(Int.self, forKey: .positionGroundSpeedKt),
                heading: try c.decodeIfPresent(Double.self, forKey: .positionHeading),
                at: at)
        } else {
            position = nil
        }
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(ident, forKey: .ident)
        try c.encodeIfPresent(`operator`, forKey: .operator)
        try c.encode(originIcao, forKey: .originIcao)
        try c.encodeIfPresent(originIata, forKey: .originIata)
        try c.encode(destinationIcao, forKey: .destinationIcao)
        try c.encodeIfPresent(destinationIata, forKey: .destinationIata)
        try c.encodeIfPresent(scheduledOut, forKey: .scheduledOut)
        try c.encodeIfPresent(scheduledIn, forKey: .scheduledIn)
        try c.encodeIfPresent(estimatedOut, forKey: .estimatedOut)
        try c.encodeIfPresent(estimatedIn, forKey: .estimatedIn)
        try c.encodeIfPresent(actualOut, forKey: .actualOut)
        try c.encodeIfPresent(actualOff, forKey: .actualOff)
        try c.encodeIfPresent(actualOn, forKey: .actualOn)
        try c.encodeIfPresent(actualIn, forKey: .actualIn)
        try c.encodeIfPresent(gateOrigin, forKey: .gateOrigin)
        try c.encodeIfPresent(gateDestination, forKey: .gateDestination)
        try c.encodeIfPresent(terminalOrigin, forKey: .terminalOrigin)
        try c.encodeIfPresent(terminalDestination, forKey: .terminalDestination)
        try c.encodeIfPresent(baggageBelt, forKey: .baggageBelt)
        try c.encodeIfPresent(aircraftType, forKey: .aircraftType)
        try c.encodeIfPresent(registration, forKey: .registration)
        try c.encode(status, forKey: .status)
        if let p = position {
            try c.encode(p.lat, forKey: .positionLat)
            try c.encode(p.lon, forKey: .positionLon)
            try c.encodeIfPresent(p.altitudeFt, forKey: .positionAltitudeFt)
            try c.encodeIfPresent(p.groundSpeedKt, forKey: .positionGroundSpeedKt)
            try c.encodeIfPresent(p.heading, forKey: .positionHeading)
            try c.encode(p.at, forKey: .positionAt)
        }
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Best known departure vs schedule (actual, else estimated).
    public var departureDelay: Duration? { Self.delay(scheduled: scheduledOut, actual: actualOut, estimated: estimatedOut) }
    public var arrivalDelay: Duration? { Self.delay(scheduled: scheduledIn, actual: actualIn ?? actualOn, estimated: estimatedIn) }

    private static func delay(scheduled: Date?, actual: Date?, estimated: Date?) -> Duration? {
        guard let scheduled, let best = actual ?? estimated else { return nil }
        return .seconds(best.timeIntervalSince(scheduled))
    }

    public var progress: Double { progress(at: .now) }

    /// Fraction of the trip elapsed, from the best known times, clamped to 0...1.
    public func progress(at now: Date) -> Double {
        guard let start = actualOff ?? actualOut ?? estimatedOut ?? scheduledOut,
              let end = actualIn ?? actualOn ?? estimatedIn ?? scheduledIn,
              end > start else { return 0 }
        let p = now.timeIntervalSince(start) / end.timeIntervalSince(start)
        return min(1, max(0, p))
    }
}
