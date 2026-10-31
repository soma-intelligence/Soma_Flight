import CoreGraphics
import CoreLocation
import EventKit
import Foundation

/// What the app may do with the traveller's calendars. Syncing needs `full`: it reads its events back
/// to update them, which write-only access does not allow.
public enum CalendarAccess: Sendable, Equatable {
    case notDetermined, denied, writeOnly, full
}

/// A calendar events can be written to.
public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The account it belongs to: "iCloud", "On My iPhone", an Exchange address.
    public var source: String
    /// Its colour in sRGB, 0 to 1.
    public var red: Double, green: Double, blue: Double

    public init(id: String, title: String, source: String, red: Double = 0.5, green: Double = 0.5, blue: Double = 0.5) {
        self.id = id; self.title = title; self.source = source; self.red = red; self.green = green; self.blue = blue
    }
}

/// The device's calendars, behind a protocol so the sync rules are tested on a fake.
@MainActor public protocol CalendarStore: AnyObject {
    var access: CalendarAccess { get }
    /// Asks for full access (iOS 17 and macOS 14 API) and returns the answer.
    func requestFullAccess() async -> CalendarAccess
    /// The calendars that take new events.
    func calendars() -> [CalendarInfo]
    /// Makes a calendar named `title` in the default account.
    func createCalendar(named title: String) throws -> CalendarInfo
    /// The event with `id` as it stands, and its calendar; nil when it is gone.
    func event(_ id: String) -> (draft: CalendarEventDraft, calendarId: String)?
    /// Writes `draft` into `calendarId`, over the event `replacing` when it still exists, and returns
    /// the event's identifier (which can change when it moves calendar).
    func save(_ draft: CalendarEventDraft, in calendarId: String, replacing id: String?) throws -> String
    /// Deletes the event; nothing when it is already gone.
    func remove(_ id: String) throws
    /// Every event between the two dates in every calendar, read only (the calendar import). Needs full access.
    func events(from start: Date, to end: Date) -> [CalendarEventSnapshot]
}

public enum CalendarStoreError: Error, Equatable {
    case noCalendar, noSource
}

/// EventKit. One store for the app's life, as Apple advises; it keeps working after access is granted.
@MainActor public final class SystemCalendarStore: CalendarStore {
    private let store = EKEventStore()

    public init() {}

    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .full
        case .writeOnly: .writeOnly
        default: .denied
        }
    }

    public func requestFullAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).filter(\.allowsContentModifications).map(Self.info)
    }

    public func createCalendar(named title: String) throws -> CalendarInfo {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        // Ember, the app's accent.
        calendar.cgColor = CGColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1)
        // The account new events go to (iCloud for most), else a local one.
        guard let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw CalendarStoreError.noSource }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return Self.info(calendar)
    }

    public func event(_ id: String) -> (draft: CalendarEventDraft, calendarId: String)? {
        guard let e = store.event(withIdentifier: id), let url = e.url else { return nil }
        let geo = e.structuredLocation?.geoLocation?.coordinate
        let draft = CalendarEventDraft(title: e.title ?? "", location: e.location ?? "", latitude: geo?.latitude,
                                       longitude: geo?.longitude, notes: e.notes ?? "", url: url, start: e.startDate,
                                       end: e.endDate, timeZone: e.timeZone ?? .gmt)
        return (draft, e.calendar.calendarIdentifier)
    }

    public func save(_ draft: CalendarEventDraft, in calendarId: String, replacing id: String?) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarId) else { throw CalendarStoreError.noCalendar }
        let e = id.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        e.calendar = calendar
        e.title = draft.title
        e.notes = draft.notes
        e.url = draft.url
        e.timeZone = draft.timeZone
        e.startDate = draft.start
        e.endDate = draft.end
        e.isAllDay = false
        if let lat = draft.latitude, let lon = draft.longitude {
            let place = EKStructuredLocation(title: draft.location)
            place.geoLocation = CLLocation(latitude: lat, longitude: lon)
            e.structuredLocation = place
        } else {
            e.structuredLocation = nil
            e.location = draft.location
        }
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier
    }

    public func remove(_ id: String) throws {
        guard let e = store.event(withIdentifier: id) else { return }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    public func events(from start: Date, to end: Date) -> [CalendarEventSnapshot] {
        guard access == .full, start < end else { return [] }
        // EventKit answers at most four years per predicate: ask a year at a time.
        var out: [String: CalendarEventSnapshot] = [:]
        var from = start
        while from < end {
            let to = min(end, from.addingTimeInterval(365 * 86_400))
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            for e in store.events(matching: predicate) {
                guard let id = e.eventIdentifier else { continue }
                let key = "\(id) \(e.startDate.timeIntervalSince1970)"
                out[key] = CalendarEventSnapshot(id: key, title: e.title ?? "", location: e.location ?? "",
                                                 notes: e.notes ?? "", url: e.url, start: e.startDate, end: e.endDate,
                                                 isAllDay: e.isAllDay, timeZone: e.timeZone,
                                                 calendarId: e.calendar.calendarIdentifier, calendarTitle: e.calendar.title)
            }
            from = to
        }
        return out.values.sorted { $0.start < $1.start }
    }

    private static func info(_ c: EKCalendar) -> CalendarInfo {
        let rgb = c.cgColor.flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) }?
            .components ?? [0.5, 0.5, 0.5]
        return CalendarInfo(id: c.calendarIdentifier, title: c.title, source: c.source?.title ?? "",
                            red: Double(rgb[0]), green: Double(rgb.count > 2 ? rgb[1] : rgb[0]),
                            blue: Double(rgb.count > 2 ? rgb[2] : rgb[0]))
    }
}
