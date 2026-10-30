import Foundation
import Supabase

/// Past flights from `past_flights` (RLS keeps them to the signed-in user), newest first.
public final class SupabaseHistoryService: HistoryService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    static let columns = "id, date, ident, origin_icao, destination_icao, airline, aircraft_type, registration, seat, "
        + "distance_km, block_minutes, delay_minutes, status, origin_tz, seat_class, reason, booking_code, notes, "
        + "origin_country, destination_country, air_minutes, seat_position"

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
}
