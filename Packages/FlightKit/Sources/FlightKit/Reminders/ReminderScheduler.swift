import Foundation
import os
import UserNotifications

/// The pending local notifications the scheduler manages, behind a protocol for tests.
public protocol LocalNotificationCenter: Sendable {
    /// Identifiers of every pending request.
    func pendingIdentifiers() async -> [String]
    /// Adds the reminder, replacing a pending one with the same identifier.
    func add(_ reminder: PlannedReminder) async throws
    func remove(identifiers: [String]) async
}

/// `UNUserNotificationCenter`. A reminder carries `flightId` like a server alert, so a tap opens the
/// flight through the same `PushInbox` path, and shares its thread.
public struct SystemLocalNotificationCenter: LocalNotificationCenter {
    public init() {}

    public func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    public func add(_ reminder: PlannedReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = reminder.flightId.uuidString.lowercased()
        content.userInfo = ["flightId": reminder.flightId.uuidString.lowercased(), "reminder": reminder.kind.rawValue]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let when = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    public func remove(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Keeps the pending reminders in line with the followed list: scheduled when a flight is followed,
/// rewritten when its times change, removed on unfollow, all removed when reminders are off or nobody is
/// signed in. Work runs one sync after another, in the order asked, so the latest list wins.
@MainActor
public final class ReminderScheduler {
    static let log = Logger(subsystem: "me.somalabs.flight", category: "reminders")

    private let center: any LocalNotificationCenter
    private let lookup: @Sendable (String) -> Airport?
    private let now: @Sendable () -> Date
    private let clock: @Sendable () -> TimeStyle
    private var tail: Task<Void, Never>?
    private var lastFlights: [Flight] = []
    /// What was added last, by identifier, so an unchanged reminder is not rewritten on every sync.
    private var scheduled: [String: PlannedReminder] = [:]

    /// The user's Reminders switch (`NotificationPreferences.reminders`). Turning it off removes every
    /// pending reminder; turning it on schedules the last list again.
    public var enabled = true {
        didSet { if enabled != oldValue { scheduleSync(lastFlights) } }
    }

    /// The flight's computed leave time (`LeaveTimeEstimator.leaveTime(for:)`), read at each sync; nil keeps
    /// the fixed rule for every flight. The home sets it when it has an estimator.
    public var leaveTime: (@MainActor (Flight) -> LeaveTime?)?

    /// - Parameter clock: the user's clock style, read at each sync (12 or 24 hour times in the text).
    public init(center: any LocalNotificationCenter = SystemLocalNotificationCenter(),
                lookup: @escaping @Sendable (String) -> Airport?,
                now: @escaping @Sendable () -> Date = { .now },
                clock: @escaping @Sendable () -> TimeStyle = { SharedSettings.twelveHour() ? .h12 : .h24 }) {
        self.center = center; self.lookup = lookup; self.now = now; self.clock = clock
    }

    /// `sync` without waiting; the store's change hook uses it.
    public func scheduleSync(_ flights: [Flight]) {
        lastFlights = flights
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            await self?.apply(flights)
        }
    }

    /// Runs the last list again: the leave times changed (a new measure), not the flights.
    public func resync() { scheduleSync(lastFlights) }

    /// Brings the pending reminders in line with `flights` and waits until it is done.
    public func sync(_ flights: [Flight]) async {
        scheduleSync(flights)
        await tail?.value
    }

    /// The reminders `flights` should have now.
    func plan(_ flights: [Flight]) -> [PlannedReminder] {
        guard enabled else { return [] }
        let at = now(), style = clock()
        return flights.flatMap {
            ReminderPlanner.plan(for: $0, origin: lookup($0.originIcao), destination: lookup($0.destinationIcao),
                                 now: at, clock: style, leave: leaveTime?($0))
        }
    }

    private func apply(_ flights: [Flight]) async {
        let wanted = plan(flights)
        let ids = Set(wanted.map(\.id))
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(ReminderPlanner.identifierPrefix) }
        let stale = pending.filter { !ids.contains($0) }
        if !stale.isEmpty { await center.remove(identifiers: stale) }
        for id in stale { scheduled[id] = nil }
        let live = Set(pending)
        for r in wanted where scheduled[r.id] != r || !live.contains(r.id) {
            do {
                try await center.add(r)
                scheduled[r.id] = r
            } catch {
                Self.log.error("reminder not scheduled: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
