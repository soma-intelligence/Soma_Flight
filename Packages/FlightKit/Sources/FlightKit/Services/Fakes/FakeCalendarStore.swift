import Foundation

/// Calendars in memory: the seeded "Home" and "Work", for screenshot runs (`-useFakes`) and tests.
/// Counts its writes so the tests can tell an update from a duplicate.
@MainActor public final class FakeCalendarStore: CalendarStore {
    public var access: CalendarAccess
    /// What `requestFullAccess` turns `notDetermined` into.
    public var grant: CalendarAccess
    public private(set) var all: [CalendarInfo] = [
        CalendarInfo(id: "home", title: "Home", source: "iCloud", red: 0.2, green: 0.6, blue: 1),
        CalendarInfo(id: "work", title: "Work", source: "iCloud", red: 0.6, green: 0.4, blue: 0.9),
    ]
    public private(set) var events: [String: (draft: CalendarEventDraft, calendarId: String)] = [:]
    public private(set) var creates = 0
    public private(set) var updates = 0
    public private(set) var removals = 0
    private var serial = 0

    public init(access: CalendarAccess = .notDetermined, grant: CalendarAccess = .full) {
        self.access = access; self.grant = grant
    }

    public func requestFullAccess() async -> CalendarAccess {
        if access == .notDetermined { access = grant }
        return access
    }

    public func calendars() -> [CalendarInfo] { all }

    public func createCalendar(named title: String) throws -> CalendarInfo {
        let c = CalendarInfo(id: "cal-\(all.count + 1)", title: title, source: "iCloud", red: 1, green: 0.42, blue: 0.21)
        all.append(c)
        return c
    }

    /// The traveller deletes a calendar in the Calendar app.
    public func deleteCalendar(_ id: String) {
        all.removeAll { $0.id == id }
        events = events.filter { $0.value.calendarId != id }
    }

    /// The traveller deletes an event in the Calendar app.
    public func deleteEvent(_ id: String) { events[id] = nil }

    public func event(_ id: String) -> (draft: CalendarEventDraft, calendarId: String)? { events[id] }

    public func save(_ draft: CalendarEventDraft, in calendarId: String, replacing id: String?) throws -> String {
        guard all.contains(where: { $0.id == calendarId }) else { throw CalendarStoreError.noCalendar }
        if let id, events[id] != nil {
            events[id] = (draft, calendarId)
            updates += 1
            return id
        }
        serial += 1
        let id = "event-\(serial)"
        events[id] = (draft, calendarId)
        creates += 1
        return id
    }

    public func remove(_ id: String) throws {
        if events.removeValue(forKey: id) != nil { removals += 1 }
    }
}
