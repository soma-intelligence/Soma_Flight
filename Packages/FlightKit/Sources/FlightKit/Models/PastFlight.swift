import Foundation

public enum PastFlightStatus: String, Codable, Sendable, Hashable {
    case completed, canceled, diverted
}

/// Where a past flight comes from: archived from a followed flight, added by hand, or imported from a file.
/// Only manual and imported flights can be edited or deleted; archived ones are read only.
public enum PastFlightSource: String, Codable, Sendable, Hashable {
    case archive, manual
    case `import`
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
    /// IANA zone of the origin airport. The core buckets years by local departure date; nil falls back to UTC.
    public var originTz: String?
    public var seatClass: SeatClass?
    public var reason: TripReason?
    public var bookingCode: String?
    public var notes: String?
    /// ISO 3166-1 alpha-2 of the two airports; nil when the airport is unknown.
    public var originCountry: String?
    public var destinationCountry: String?
    /// Wheels up to wheels down; nil when the times are not known.
    public var airMinutes: Int?
    /// Where the traveller says they sat; nil leaves it to the seat number.
    public var seatPosition: SeatPosition?
    /// Where the row comes from; nil (payloads older than the column, the seed) reads as archived.
    public var source: PastFlightSource?

    /// True for the flights the traveller added or imported: those they may edit and delete.
    public var isEditable: Bool { source == .manual || source == .import }

    public init(
        id: UUID = UUID(), date: Date, ident: String, originIcao: String, destinationIcao: String,
        airline: String? = nil, aircraftType: String? = nil, registration: String? = nil, seat: String? = nil,
        distanceKm: Int, blockMinutes: Int? = nil, delayMinutes: Int = 0, status: PastFlightStatus = .completed,
        originTz: String? = nil, seatClass: SeatClass? = nil, reason: TripReason? = nil,
        bookingCode: String? = nil, notes: String? = nil, originCountry: String? = nil,
        destinationCountry: String? = nil, airMinutes: Int? = nil, seatPosition: SeatPosition? = nil,
        source: PastFlightSource? = nil
    ) {
        self.id = id; self.date = date; self.ident = ident
        self.originIcao = originIcao; self.destinationIcao = destinationIcao
        self.airline = airline; self.aircraftType = aircraftType; self.registration = registration; self.seat = seat
        self.distanceKm = distanceKm; self.blockMinutes = blockMinutes
        self.delayMinutes = delayMinutes; self.status = status; self.originTz = originTz
        self.seatClass = seatClass; self.reason = reason; self.bookingCode = bookingCode; self.notes = notes
        self.originCountry = originCountry; self.destinationCountry = destinationCountry; self.airMinutes = airMinutes
        self.seatPosition = seatPosition; self.source = source
    }
}
