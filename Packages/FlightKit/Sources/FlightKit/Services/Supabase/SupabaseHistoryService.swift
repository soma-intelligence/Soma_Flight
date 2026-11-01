import Foundation
import Supabase

/// Past flights from `past_flights` (RLS keeps them to the signed-in user), newest first. Manual and
/// imported flights are written there too; archived ones are read only (migration 20261030000013).
public final class SupabaseHistoryService: HistoryService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// True once migration 20261031000041 (signed arrival and departure delays) is on the server the app
    /// talks to. Off, the two columns are neither read nor written, so a project without them keeps
    /// working; the Delay Report then reads arrival delays from `delay_minutes` and has no departures.
    static let delayColumns = false

    static let columns = "id, date, ident, origin_icao, destination_icao, airline, aircraft_type, registration, seat, "
        + "distance_km, block_minutes, delay_minutes, status, origin_tz, seat_class, reason, booking_code, notes, "
        + "origin_country, destination_country, air_minutes, seat_position, source"
        + (delayColumns ? ", arrival_delay_minutes, departure_delay_minutes" : "")

    /// Rows per insert request of an import.
    static let batchSize = 200

    static func decode(_ data: Data) throws -> [PastFlight] {
        try FlightJSON.decoder.decode([PastFlight].self, from: data)
    }

    public func pastFlights() async throws(APIError) -> [PastFlight] {
        let data = try await backend.rows { $0.from("past_flights").select(Self.columns).order("date", ascending: false) }
        do { return try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func export(_ format: ExportFormat) async throws(APIError) -> Data {
        try PastFlightExport.data(try await pastFlights(), format: format)
    }

    // MARK: Writes

    /// The columns a client writes. Every one is sent, null included, so every row of a batch has the same
    /// keys (PostgREST requires it) and a cleared field clears the column. The derived fields go as null so
    /// the server fills them from airports (`past_flights_fill`), and so does a distance of 0. The user is
    /// the column default (`auth.uid()`); the id goes on insert only.
    struct Write: Encodable, Sendable {
        var flight: PastFlight
        var insert: Bool

        private enum CodingKeys: String, CodingKey {
            case id, date, ident, originIcao = "origin_icao", destinationIcao = "destination_icao", airline
            case aircraftType = "aircraft_type", registration, seat, distanceKm = "distance_km"
            case blockMinutes = "block_minutes", delayMinutes = "delay_minutes", status
            case originTz = "origin_tz", seatClass = "seat_class", reason, bookingCode = "booking_code", notes
            case originCountry = "origin_country", destinationCountry = "destination_country"
            case airMinutes = "air_minutes", seatPosition = "seat_position", source
            case arrivalDelayMinutes = "arrival_delay_minutes", departureDelayMinutes = "departure_delay_minutes"
        }

        func encode(to encoder: any Encoder) throws {
            let f = flight
            var c = encoder.container(keyedBy: CodingKeys.self)
            if insert { try c.encode(f.id.uuidString.lowercased(), forKey: .id) }
            try c.encode(f.date, forKey: .date)
            try c.encode(f.ident, forKey: .ident)
            try c.encode(f.originIcao, forKey: .originIcao)
            try c.encode(f.destinationIcao, forKey: .destinationIcao)
            try c.encode(f.airline, forKey: .airline)
            try c.encode(f.aircraftType, forKey: .aircraftType)
            try c.encode(f.registration, forKey: .registration)
            try c.encode(f.seat, forKey: .seat)
            try c.encode(f.distanceKm > 0 ? f.distanceKm : nil, forKey: .distanceKm)
            try c.encode(f.blockMinutes, forKey: .blockMinutes)
            try c.encode(f.delayMinutes, forKey: .delayMinutes)
            try c.encode(f.status, forKey: .status)
            try c.encode(f.seatClass, forKey: .seatClass)
            try c.encode(f.reason, forKey: .reason)
            try c.encode(f.bookingCode, forKey: .bookingCode)
            try c.encode(f.notes, forKey: .notes)
            try c.encode(f.airMinutes, forKey: .airMinutes)
            try c.encode(f.seatPosition, forKey: .seatPosition)
            if SupabaseHistoryService.delayColumns {
                try c.encode(f.arrivalDelayMinutes, forKey: .arrivalDelayMinutes)
                try c.encode(f.departureDelayMinutes, forKey: .departureDelayMinutes)
            }
            // A client row is manual or imported, never archived (the server refuses that anyway).
            try c.encode(f.source == .import ? PastFlightSource.import : .manual, forKey: .source)
            try c.encodeNil(forKey: .originTz)
            try c.encodeNil(forKey: .originCountry)
            try c.encodeNil(forKey: .destinationCountry)
        }
    }

    /// The request bodies of an import: `batchSize` rows each, in order.
    static func batches(_ flights: [PastFlight]) -> [[Write]] {
        stride(from: 0, to: flights.count, by: batchSize).map { start in
            flights[start..<min(start + batchSize, flights.count)].map { Write(flight: $0, insert: true) }
        }
    }

    public func add(_ flight: PastFlight) async throws(APIError) -> PastFlight {
        guard let stored = try await addAll([flight]).first else { throw .notFound }
        return stored
    }

    public func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] {
        var stored: [PastFlight] = []
        for batch in Self.batches(flights) {
            let data = try await backend.write { try $0.from("past_flights").insert(batch).select(Self.columns) }
            do { stored += try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
        }
        return stored
    }

    public func update(_ flight: PastFlight) async throws(APIError) -> PastFlight {
        let body = Write(flight: flight, insert: false)
        let id = flight.id.uuidString.lowercased()
        let data = try await backend.write {
            try $0.from("past_flights").update(body).eq("id", value: id).select(Self.columns)
        }
        // An update RLS filters out (archived, someone else's, gone) matches no row and succeeds silently.
        let rows: [PastFlight]
        do { rows = try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
        guard let first = rows.first else { throw .notFound }
        return first
    }

    public func delete(_ id: PastFlight.ID) async throws(APIError) {
        let key = id.uuidString.lowercased()
        let data = try await backend.rows { $0.from("past_flights").delete().eq("id", value: key).select("id") }
        // Same as update: a delete that matches no row is reported, not passed over.
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any], !rows.isEmpty else { throw .notFound }
    }
}
