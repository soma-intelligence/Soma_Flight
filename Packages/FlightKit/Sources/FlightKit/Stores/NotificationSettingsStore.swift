import Foundation
import Observation

/// The Notifications screen's state: the account's alert categories, loaded from and saved to the
/// backend. A toggle shows at once and saves in the background; a failed save puts the switch back and
/// shows the error. `onChange` hears every value the store settles on (the home turns reminders on and
/// off with it).
@MainActor @Observable
public final class NotificationSettingsStore {
    public private(set) var preferences: NotificationPreferences = .allOn
    public private(set) var hasLoaded = false
    public private(set) var error: APIError?
    /// Categories whose save is running.
    public private(set) var saving: Set<NotificationPreferences.Category> = []

    @ObservationIgnored public var onChange: (@MainActor (NotificationPreferences) -> Void)?

    /// Text Me Too (the number, the code and the text switches); nil shows no text section.
    public let texts: TextAlertsStore?

    private let service: any NotificationPreferencesService
    /// Bumped by every load and toggle, so a slow answer never overwrites a newer choice.
    @ObservationIgnored private var generation = 0

    public init(service: any NotificationPreferencesService, texts: (any TextAlertsService)? = nil) {
        self.service = service
        self.texts = texts.map { TextAlertsStore(service: $0) }
    }

    public func load() async {
        generation += 1
        let gen = generation
        do {
            let p = try await service.load()
            guard gen == generation else { return }
            preferences = p
            error = nil
            hasLoaded = true
            onChange?(p)
        } catch {
            guard gen == generation else { return }
            self.error = error
            hasLoaded = true
        }
    }

    /// Turns one category on or off and saves the whole row.
    public func set(_ category: NotificationPreferences.Category, _ on: Bool) async {
        guard preferences[category] != on else { return }
        let before = preferences
        preferences[category] = on
        generation += 1
        let gen = generation
        saving.insert(category)
        onChange?(preferences)
        defer { saving.remove(category) }
        do {
            try await service.save(preferences)
            if gen == generation { error = nil }
        } catch {
            guard gen == generation else { return }
            preferences[category] = before[category]
            self.error = error
            onChange?(preferences)
        }
    }

    #if DEBUG
    /// Previews: a state without a load.
    func seed(_ p: NotificationPreferences, error: APIError? = nil) {
        preferences = p; self.error = error; hasLoaded = true
    }
    #endif
}
