import Foundation
import Supabase

/// `notification_preferences` through PostgREST. RLS keeps the row to its owner; the row is written on
/// the first save (an upsert on `user_id`), so an account that never changed anything has none.
public final class SupabaseNotificationPreferencesService: NotificationPreferencesService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    static let columns = "delays, gates, takeoff_landing, baggage, cancellations, reminders, boarding, aircraft, favorite_airports"

    /// The row as PostgREST takes it (snake_case keys written out, since the encoder does not convert).
    struct Row: Encodable {
        var user_id: String
        var delays, gates, takeoff_landing, baggage, cancellations, reminders: Bool
        var boarding, aircraft, favorite_airports: Bool
        var updated_at: String

        init(user: UUID, _ p: NotificationPreferences, at: Date) {
            user_id = user.uuidString.lowercased()
            delays = p.delays; gates = p.gates; takeoff_landing = p.takeoffLanding
            baggage = p.baggage; cancellations = p.cancellations; reminders = p.reminders
            boarding = p.boarding; aircraft = p.aircraft; favorite_airports = p.favoriteAirports
            updated_at = ISO8601DateFormatter().string(from: at)
        }
    }

    /// The first row of a select, or `.allOn` when there is none.
    static func decode(_ data: Data) throws -> NotificationPreferences {
        try FlightJSON.decoder.decode([NotificationPreferences].self, from: data).first ?? .allOn
    }

    public func load() async throws(APIError) -> NotificationPreferences {
        let data = try await backend.rows { $0.from("notification_preferences").select(Self.columns).limit(1) }
        do { return try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
    }

    public func save(_ preferences: NotificationPreferences) async throws(APIError) {
        let user: UUID
        do { user = try await backend.client.auth.session.user.id } catch { throw .unauthorized }
        let row = Row(user: user, preferences, at: .now)
        _ = try await backend.write {
            try $0.from("notification_preferences").upsert(row, onConflict: "user_id")
        }
    }
}
