import Foundation

/// In memory, for `-useFakes`, previews and tests.
public actor FakeNotificationPreferencesService: NotificationPreferencesService {
    public private(set) var stored: NotificationPreferences
    public private(set) var saves = 0
    public var nextError: APIError?

    public init(_ stored: NotificationPreferences = .allOn) { self.stored = stored }

    public func setNextError(_ error: APIError?) { nextError = error }

    public func load() async throws(APIError) -> NotificationPreferences {
        if let e = nextError { nextError = nil; throw e }
        return stored
    }

    public func save(_ preferences: NotificationPreferences) async throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
        stored = preferences
        saves += 1
    }
}
