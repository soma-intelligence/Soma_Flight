import Foundation

public enum PastFlightStatus: String, Codable, Sendable, Hashable {
    case completed, canceled, diverted
}

public struct PastFlight: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var ident: String
    public var originIcao: String
    public var destinationIcao: String
    public var airline: String?
    public var aircraftType: String?
    public var registration: String?
    public var seat: String?
    public var distanceKm: Int
    public var blockMinutes: Int?
    public var delayMinutes: Int
    public var status: PastFlightStatus

    public init(
        id: UUID = UUID(), date: Date, ident: String, originIcao: String, destinationIcao: String,
        airline: String? = nil, aircraftType: String? = nil, registration: String? = nil, seat: String? = nil,
        distanceKm: Int, blockMinutes: Int? = nil, delayMinutes: Int = 0, status: PastFlightStatus = .completed
    ) {
        self.id = id; self.date = date; self.ident = ident
        self.originIcao = originIcao; self.destinationIcao = destinationIcao
        self.airline = airline; self.aircraftType = aircraftType; self.registration = registration; self.seat = seat
        self.distanceKm = distanceKm; self.blockMinutes = blockMinutes
        self.delayMinutes = delayMinutes; self.status = status
    }
}
