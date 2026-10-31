import Foundation
import os

/// A Live Activity running on this device.
public struct RunningFlightActivity: Sendable, Hashable {
    public var id: String
    public var flightId: UUID
    /// The account it was started for (`FlightActivityAttributes.ownerId`).
    public var ownerId: UUID?
    public var state: FlightActivityAttributes.ContentState

    public init(id: String, flightId: UUID, ownerId: UUID? = nil, state: FlightActivityAttributes.ContentState) {
        self.id = id; self.flightId = flightId; self.ownerId = ownerId; self.state = state
    }
}

/// ActivityKit behind a protocol, so the start and end rules are tested without a device.
/// `SystemFlightActivityHost` is the iOS implementation.
@MainActor public protocol FlightActivityHost: AnyObject {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled`.
    var areActivitiesEnabled: Bool { get }
    /// Called with every push token an activity gets (the first one and each new one) and its flight.
    var onPushToken: (@MainActor (Data, UUID) async -> Void)? { get set }
    /// Activities still running (not ended or dismissed).
    func running() -> [RunningFlightActivity]
    /// Starts one with `pushType: .token`; returns its id.
    func start(attributes: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) throws -> String
    func update(id: String, state: FlightActivityAttributes.ContentState) async
    /// Ends it now (`dismissAt` nil) or leaves the final state up until `dismissAt`.
    func end(id: String, state: FlightActivityAttributes.ContentState?, dismissAt: Date?) async
}

/// Keeps at most one Live Activity running, for the best followed flight:
/// - nothing runs or starts until `adopt(owner:)` names the account signed in; activities of another
///   account (or of nobody) end then and at every later sync;
/// - the candidate is the flight in the air, else the soonest one departing within 4 hours; it replaces
///   an activity running for another flight, and starts when activities are enabled;
/// - the running one is updated from the app's own data (the backend also pushes to its token), only
///   when the card would change;
/// - it ends when its flight arrives or is canceled (the final state stays up 30 min, 60 min for a
///   cancellation, as the backend's end push does), 6 h after the expected arrival of a flight left
///   landed or diverted, and at once when it is unfollowed; `endAll()` at sign-out;
/// - a timer re-runs the rules when the next flight reaches the 4 hour line, and every 5 minutes while the
///   running one is in the air (its progress moves by time, also with no connection); the shell also syncs
///   when the app becomes active (`Activity.request` only works in the foreground).
/// Each new push token is registered as `live_activity` for the flight.
@MainActor
public final class FlightActivityController {
    /// How long before departure an activity starts.
    public static let lead: TimeInterval = 4 * 3600
    /// How often a running activity in the air is moved on by time (the widgets' step).
    public static let progressStep: TimeInterval = WidgetTimeline.progressStep
    /// A scheduled flight this long past its departure without news is not started.
    static let staleDeparture: TimeInterval = 2 * 3600
    /// A flight left landed or diverted this long after its expected arrival is over for the activity.
    static let stuckAfterArrival: TimeInterval = 6 * 3600
    static let log = Logger(subsystem: "me.somalabs.flight", category: "live-activity")

    private let host: any FlightActivityHost
    private let push: any PushService
    private let lookup: @Sendable (String) -> Airport?
    private let now: @Sendable () -> Date
    /// Work runs one item after another, in the order it was enqueued.
    private var tail: Task<Void, Never>?
    /// Tokens whose registration failed, retried at the next sync.
    private(set) var pendingTokens: [Data: UUID] = [:]
    /// The account signed in; nil with `ownerKnown` false until `adopt(owner:)`.
    private var owner: UUID?
    private var ownerKnown = false
    /// The last list synced, for the timer.
    private var lastFlights: [Flight] = []
    private var wake: Task<Void, Never>?
    /// When the timer fires next (tests read it).
    private(set) var wakeAt: Date?

    public init(host: any FlightActivityHost, push: any PushService,
                lookup: @escaping @Sendable (String) -> Airport?,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.host = host; self.push = push; self.lookup = lookup; self.now = now
        host.onPushToken = { [weak self] token, flightId in await self?.register(token: token, flightId: flightId) }
    }

    /// Brings the activities in line with the followed list (the whole list, after a successful load,
    /// a pushed change, an unfollow, or when the app becomes active).
    public func sync(_ flights: [Flight]) async {
        await enqueue { await self.apply(flights) }.value
    }

    /// `sync` without waiting: the order of calls is the order the work runs in, so the latest list
    /// always wins. The store's change hook uses it.
    public func scheduleSync(_ flights: [Flight]) {
        enqueue { await self.apply(flights) }
    }

    /// The account signed in now (nil: the app has no accounts, the fakes). Ends every activity started
    /// for anyone else. Starts are held until the first call.
    public func adopt(owner: UUID?) async {
        await enqueue {
            self.owner = owner
            self.ownerKnown = true
            for a in self.host.running() where a.ownerId != owner {
                await self.host.end(id: a.id, state: nil, dismissAt: nil)
            }
        }.value
    }

    /// Ends every activity at once (signed out). Nothing starts again until `adopt(owner:)`.
    public func endAll() async {
        await enqueue {
            self.pendingTokens = [:]
            self.ownerKnown = false
            self.owner = nil
            self.lastFlights = []
            self.setWake(nil)
            for a in self.host.running() { await self.host.end(id: a.id, state: nil, dismissAt: nil) }
        }.value
    }

    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    private func apply(_ flights: [Flight]) async {
        guard ownerKnown else { return }
        let clock = now()
        lastFlights = flights
        let byId = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let best = Self.candidate(in: flights, now: clock)
        var alive: [(RunningFlightActivity, FlightActivityAttributes.ContentState)] = []
        for activity in host.running() {
            guard activity.ownerId == owner, let flight = byId[activity.flightId] else {
                await host.end(id: activity.id, state: nil, dismissAt: nil) // unfollowed or another account
                continue
            }
            let state = FlightActivityAttributes.ContentState.from(flight, now: clock)
            if state.isFinal {
                let linger: TimeInterval = state.status == .canceled ? 3600 : 1800
                await host.end(id: activity.id, state: state, dismissAt: clock.addingTimeInterval(linger))
            } else if Self.isStuck(state, now: clock) {
                await host.end(id: activity.id, state: state, dismissAt: clock.addingTimeInterval(1800))
            } else {
                alive.append((activity, state))
            }
        }
        // One at a time: the candidate's own activity if it has one, else the first still going when
        // there is no candidate. Everything else ends, and a candidate without one starts.
        let keepIndex = best.map { b in alive.firstIndex { $0.0.flightId == b.id } } ?? (alive.isEmpty ? nil : 0)
        for (i, (activity, state)) in alive.enumerated() {
            if i == keepIndex {
                if !state.looksLike(activity.state) { await host.update(id: activity.id, state: state) }
            } else {
                await host.end(id: activity.id, state: nil, dismissAt: nil)
            }
        }
        await retryPendingTokens()
        // In the air, the card's progress moves with the clock even with no news (offline, airline Wi-Fi):
        // the timer comes back every `progressStep` to update it from the times (the same estimate as the
        // flight sheet's).
        let tick: Date? = keepIndex.flatMap { i in
            [.departed, .enRoute].contains(alive[i].1.status) ? clock.addingTimeInterval(Self.progressStep) : nil
        }
        defer { setWake([Self.nextWake(in: flights, now: clock), tick].compactMap { $0 }.min()) }
        guard keepIndex == nil, let next = best else { return }
        guard host.areActivitiesEnabled else {
            Self.log.info("live activities are off, none started")
            return
        }
        do {
            _ = try host.start(attributes: .from(next, owner: owner, lookup: lookup), state: .from(next, now: clock))
        } catch {
            Self.log.error("live activity not started: \(String(describing: error), privacy: .public)")
        }
    }

    /// A flight left landed or diverted long after it was due: no arrived status will come.
    static func isStuck(_ state: FlightActivityAttributes.ContentState, now: Date) -> Bool {
        guard state.status == .landed || state.status == .diverted, let due = state.estimatedIn else { return false }
        return now.timeIntervalSince(due) > stuckAfterArrival
    }

    /// The next time a followed flight crosses the 4 hour line, nil when none will.
    static func nextWake(in flights: [Flight], now: Date) -> Date? {
        flights.compactMap { f -> Date? in
            guard f.status == .scheduled || f.status == .unknown, let out = f.estimatedOut ?? f.scheduledOut else { return nil }
            let at = out.addingTimeInterval(-lead)
            return at > now ? at : nil
        }.min()
    }

    private func setWake(_ date: Date?) {
        guard date != wakeAt else { return }
        wake?.cancel()
        wakeAt = date
        guard let date else { wake = nil; return }
        let delay = max(1, date.timeIntervalSince(now()))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.wakeAt = nil
            self.scheduleSync(self.lastFlights)
        }
    }

    #if DEBUG
    /// Applies a Live Activity push the way ActivityKit would (`simctl push` cannot deliver one): the
    /// `aps` body push-sender sends, `event` update or end, `content-state` decoded by `ContentState`'s
    /// own decoder, `dismissal-date` in seconds. Goes to every running activity. False when unreadable.
    @discardableResult
    public func applyDebugPush(_ payload: Data) async -> Bool {
        struct Body: Decodable {
            struct APS: Decodable {
                var event: String
                var contentState: FlightActivityAttributes.ContentState
                var dismissalDate: TimeInterval?
                enum CodingKeys: String, CodingKey {
                    case event, contentState = "content-state", dismissalDate = "dismissal-date"
                }
            }
            var aps: APS
        }
        guard let aps = try? JSONDecoder().decode(Body.self, from: payload).aps else { return false }
        await enqueue {
            for a in self.host.running() {
                if aps.event == "end" {
                    await self.host.end(id: a.id, state: aps.contentState,
                                        dismissAt: aps.dismissalDate.map(Date.init(timeIntervalSince1970:)))
                } else {
                    await self.host.update(id: a.id, state: aps.contentState)
                }
            }
        }.value
        return true
    }
    #endif

    /// The flight an activity is for: one in the air beats a scheduled one, then the soonest departure.
    static func candidate(in flights: [Flight], now: Date) -> Flight? {
        func airborne(_ f: Flight) -> Bool { f.status == .departed || f.status == .enRoute }
        return flights.filter { canStart($0, now: now) }.min { a, b in
            airborne(a) != airborne(b) ? airborne(a) : departure(a) < departure(b)
        }
    }

    static func canStart(_ f: Flight, now: Date) -> Bool {
        switch f.status {
        case .departed, .enRoute:
            return true
        case .scheduled, .unknown:
            guard let out = f.estimatedOut ?? f.scheduledOut else { return false }
            let until = out.timeIntervalSince(now)
            return until <= lead && until > -staleDeparture
        case .landed, .arrived, .canceled, .diverted:
            return false
        }
    }

    private static func departure(_ f: Flight) -> Date {
        f.actualOut ?? f.estimatedOut ?? f.scheduledOut ?? .distantFuture
    }

    private func register(token: Data, flightId: UUID) async {
        do {
            try await push.register(deviceToken: token, kind: .liveActivity, flightId: flightId)
            pendingTokens[token] = nil
        } catch {
            pendingTokens[token] = flightId
        }
    }

    private func retryPendingTokens() async {
        let running = Set(host.running().map(\.flightId))
        for (token, flightId) in pendingTokens {
            if running.contains(flightId) { await register(token: token, flightId: flightId) } else { pendingTokens[token] = nil }
        }
    }
}
