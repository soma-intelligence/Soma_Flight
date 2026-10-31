import Foundation

/// The signed-in account's alert categories (`notification_preferences`). push-sender reads them for
/// every alert; the app reads `reminders` for its own local reminders.
public protocol NotificationPreferencesService: Sendable {
    /// `.allOn` when the account has never changed anything.
    func load() async throws(APIError) -> NotificationPreferences
    func save(_ preferences: NotificationPreferences) async throws(APIError)
}
