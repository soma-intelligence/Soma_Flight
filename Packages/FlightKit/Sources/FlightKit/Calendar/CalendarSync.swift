import Foundation
import Observation
import os

/// Keeps one calendar event per followed flight, on the device and nowhere else: created when the flight
/// is followed, rewritten when its times, gates or status change, removed on unfollow, all removed when
/// syncing is turned off or nobody is signed in. A flight's event identifier is kept, so a sync never
/// adds a second event for a flight that has one. Work runs one sync after another, in the order asked,
/// so the latest list wins. Settings > Calendar drives it.
@MainActor @Observable
public final class CalendarSync {
    static let log = Logger(subsystem: "me.somalabs.flight", category: "calendar")
    static let defaultsKey = "calendar.sync"
    /// The name of the calendar the app makes when the traveller has not picked one.
    public static let appCalendarTitle = "Soma Flight"
    /// How long a flight's seat and booking code are trusted before they are asked for again.
    static let detailsTTL: TimeInterval = 30 * 60

    /// What is kept between launches.
    struct State: Codable, Equatable {
        var enabled = false
        var calendarId: String?
        /// The calendar the app made, so the list can say so.
        var appCalendarId: String?
        /// Flight id (lower case) to event identifier.
        var events: [String: String] = [:]
    }

    public private(set) var access: CalendarAccess
    public private(set) var calendars: [CalendarInfo] = []
    /// The last sync could not reach the chosen calendar (deleted in the Calendar app).
    public private(set) var calendarMissing = false
    /// The last thing that went wrong, for the screen; nil when the last sync worked.
    public private(set) var failure: String?
    private var state: State

    public var isEnabled: Bool { state.enabled }
    public var calendarId: String? { state.calendarId }
    public var appCalendarId: String? { state.appCalendarId }
    /// How many flights have an event now.
    public var eventCount: Int { state.events.count }

    @ObservationIgnored private let store: any CalendarStore
    @ObservationIgnored private let lookup: @Sendable (String) -> Airport?
    @ObservationIgnored private let details: @Sendable (Flight.ID) async -> FollowDetails?
    @ObservationIgnored private let clock: @Sendable () -> TimeStyle
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var lastFlights: [Flight] = []
    @ObservationIgnored private var detailsCache: [Flight.ID: (value: FollowDetails?, at: Date)] = [:]

    /// - Parameters:
    ///   - details: the seat and booking code noted on a followed flight (`FlightService.followDetails`).
    ///   - defaults: where the switch, the calendar and the event identifiers are kept; nil keeps them in memory.
    public init(store: any CalendarStore, lookup: @escaping @Sendable (String) -> Airport?,
                details: @escaping @Sendable (Flight.ID) async -> FollowDetails? = { _ in nil },
                clock: @escaping @Sendable () -> TimeStyle = { SharedSettings.twelveHour() ? .h12 : .h24 },
                defaults: UserDefaults? = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store; self.lookup = lookup; self.details = details; self.clock = clock
        self.defaults = defaults; self.now = now
        state = defaults?.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        access = store.access
        if access == .full { calendars = store.calendars() }
    }

    /// The sync a launch runs on: EventKit, or the in-memory calendars with the fakes (`-useFakes`).
    public static func forLaunch(env: AppEnvironment,
                                 arguments: [String] = ProcessInfo.processInfo.arguments) -> CalendarSync {
        let fakes = AppEnvironment.usesFakes(arguments)
        let flights = env.flights
        return CalendarSync(store: fakes ? FakeCalendarStore() : SystemCalendarStore(), lookup: env.lookup,
                            details: { id in (try? await flights.followDetails(id)) ?? nil },
                            defaults: fakes ? nil : .standard)
    }

    // MARK: Settings

    /// Turns syncing on: asks for full calendar access the first time, makes the "Soma Flight" calendar
    /// when none is chosen, then adds every followed flight. Stays off when access is refused. Off
    /// removes every event it added.
    public func setEnabled(_ on: Bool) async {
        guard on else {
            state.enabled = false
            persist()
            scheduleSync(lastFlights)
            return
        }
        var a = store.access
        if a == .notDetermined { a = await store.requestFullAccess() }
        access = a
        guard a == .full else {
            state.enabled = false
            persist()
            return
        }
        calendars = store.calendars()
        if state.calendarId == nil || !calendars.contains(where: { $0.id == state.calendarId }) {
            do {
                let made = try store.createCalendar(named: Self.appCalendarTitle)
                state.calendarId = made.id
                state.appCalendarId = made.id
                calendars = store.calendars()
            } catch {
                Self.log.error("calendar not made: \(String(describing: error), privacy: .public)")
                failure = "Couldn't make the Soma Flight calendar. Pick one below."
                state.calendarId = calendars.first?.id
            }
        }
        state.enabled = true
        persist()
        scheduleSync(lastFlights)
    }

    /// Moves every event to `id` on the next sync.
    public func choose(calendar id: String) {
        guard id != state.calendarId else { return }
        state.calendarId = id
        calendarMissing = false
        persist()
        scheduleSync(lastFlights)
    }

    /// Reads the access and the calendars again (the screen appearing, the app coming back from Settings).
    public func refresh() {
        access = store.access
        calendars = access == .full ? store.calendars() : []
    }

    // MARK: Sync

    /// `sync` without waiting; the store's change hook uses it.
    public func scheduleSync(_ flights: [Flight]) {
        lastFlights = flights
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            await self?.apply(flights)
        }
    }

    /// Brings the calendar in line with `flights` and waits until it is done.
    public func sync(_ flights: [Flight]) async {
        scheduleSync(flights)
        await tail?.value
    }

    /// Waits for the syncs already asked for (tests).
    func idle() async { await tail?.value }

    /// The events `flights` should have, by flight id; none while syncing is off.
    func drafts(_ flights: [Flight]) async -> [Flight.ID: CalendarEventDraft] {
        guard state.enabled else { return [:] }
        let style = clock()
        var out: [Flight.ID: CalendarEventDraft] = [:]
        for f in flights {
            let noted = await followDetails(f.id)
            if let d = CalendarEventBuilder.draft(for: f, origin: lookup(f.originIcao), destination: lookup(f.destinationIcao),
                                                  details: noted, clock: style) {
                out[f.id] = d
            }
        }
        return out
    }

    private func followDetails(_ id: Flight.ID) async -> FollowDetails? {
        if let hit = detailsCache[id], now().timeIntervalSince(hit.at) < Self.detailsTTL { return hit.value }
        let value = await details(id)
        detailsCache[id] = (value, now())
        return value
    }

    private func apply(_ flights: [Flight]) async {
        // Without full access nothing can be read back, updated or removed: the identifiers are kept for later.
        access = store.access
        guard access == .full else { return }
        let wanted = await drafts(flights)
        let wantedKeys = Set(wanted.keys.map(Self.key))
        for (flight, event) in state.events where !wantedKeys.contains(flight) {
            do { try store.remove(event) } catch {
                Self.log.error("event not removed: \(String(describing: error), privacy: .public)")
            }
            state.events[flight] = nil
        }
        defer { persist() }
        guard !wanted.isEmpty else { failure = nil; return }
        guard let calendarId = state.calendarId, store.calendars().contains(where: { $0.id == calendarId }) else {
            calendarMissing = true
            return
        }
        calendarMissing = false
        var failed = false
        for (id, draft) in wanted.sorted(by: { $0.value.start < $1.value.start }) {
            let key = Self.key(id)
            let existing = state.events[key].flatMap { store.event($0) }
            if let existing, existing.draft == draft, existing.calendarId == calendarId { continue }
            do {
                state.events[key] = try store.save(draft, in: calendarId, replacing: existing == nil ? nil : state.events[key])
            } catch {
                failed = true
                Self.log.error("event not saved: \(String(describing: error), privacy: .public)")
            }
        }
        failure = failed ? "Some flights couldn't be added to the calendar." : nil
    }

    private static func key(_ id: Flight.ID) -> String { id.uuidString.lowercased() }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
