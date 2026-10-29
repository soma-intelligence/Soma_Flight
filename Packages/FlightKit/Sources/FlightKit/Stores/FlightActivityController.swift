import Foundation
import os

/// A Live Activity running on this device.
public struct RunningFlightActivity: Sendable, Hashable {
    public var id: String
    public var flightId: UUID
    public var state: FlightActivityAttributes.ContentState

    public init(id: String, flightId: UUID, state: FlightActivityAttributes.ContentState) {
        self.id = id; self.flightId = flightId; self.state = state
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

/// Keeps at most one Live Activity running, for the next followed flight:
/// - starts one for the flight in the air, else the next one departing within 4 hours, when activities
///   are enabled and none is running;
/// - updates it from the app's own data (the backend also pushes updates to its token);
/// - ends it when its flight arrives or is canceled (the final state stays up 30 min, 60 min for a
///   cancellation, as the backend's end push does), and at once when it is unfollowed;
/// - `endAll()` at sign-out and account change.
/// Each new push token is registered as `live_activity` for the flight.
@MainActor
public final class FlightActivityController {
    /// How long before departure an activity starts.
    public static let lead: TimeInterval = 4 * 3600
    /// A scheduled flight this long past its departure without news is not started.
    static let staleDeparture: TimeInterval = 2 * 3600
    static let log = Logger(subsystem: "me.somalabs.flight", category: "live-activity")

    private let host: any FlightActivityHost
    private let push: any PushService
    private let lookup: @Sendable (String) -> Airport?
    private let now: @Sendable () -> Date
    /// Calls run one after another: two overlapping syncs must not both start an activity.
    private var tail: Task<Void, Never>?
    /// Tokens whose registration failed, retried at the next sync.
    private var pendingTokens: [Data: UUID] = [:]

    public init(host: any FlightActivityHost, push: any PushService,
                lookup: @escaping @Sendable (String) -> Airport?,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.host = host; self.push = push; self.lookup = lookup; self.now = now
        host.onPushToken = { [weak self] token, flightId in await self?.register(token: token, flightId: flightId) }
    }

    /// Brings the activities in line with the followed list (the whole list, after a successful load,
    /// a pushed change or an unfollow).
    public func sync(_ flights: [Flight]) async {
        await serial { await self.apply(flights) }
    }

    /// Ends every activity at once (sign-out, another account).
    public func endAll() async {
        await serial {
            self.pendingTokens = [:]
            for a in self.host.running() { await self.host.end(id: a.id, state: nil, dismissAt: nil) }
        }
    }

    private func serial(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    private func apply(_ flights: [Flight]) async {
        let clock = now()
        let byId = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        var kept: [RunningFlightActivity] = []
        for activity in host.running() {
            guard let flight = byId[activity.flightId] else {
                await host.end(id: activity.id, state: nil, dismissAt: nil) // unfollowed
                continue
            }
            let state = FlightActivityAttributes.ContentState.from(flight, now: clock)
            if state.isFinal {
                let linger: TimeInterval = state.status == .canceled ? 3600 : 1800
                await host.end(id: activity.id, state: state, dismissAt: clock.addingTimeInterval(linger))
            } else if !kept.isEmpty {
                await host.end(id: activity.id, state: nil, dismissAt: nil) // one at a time
            } else {
                if state != activity.state { await host.update(id: activity.id, state: state) }
                kept.append(activity)
            }
        }
        await retryPendingTokens()
        guard kept.isEmpty, let next = Self.candidate(in: flights, now: clock) else { return }
        guard host.areActivitiesEnabled else {
            Self.log.info("live activities are off, none started")
            return
        }
        do {
            _ = try host.start(attributes: .from(next, lookup: lookup), state: .from(next, now: clock))
        } catch {
            Self.log.error("live activity not started: \(String(describing: error), privacy: .public)")
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
        await serial {
            for a in self.host.running() {
                if aps.event == "end" {
                    await self.host.end(id: a.id, state: aps.contentState,
                                        dismissAt: aps.dismissalDate.map(Date.init(timeIntervalSince1970:)))
                } else {
                    await self.host.update(id: a.id, state: aps.contentState)
                }
            }
        }
        return true
    }
    #endif

    /// The flight an activity starts for: in the air first, else the soonest departing within `lead`.
    static func candidate(in flights: [Flight], now: Date) -> Flight? {
        flights.filter { canStart($0, now: now) }.min { departure($0) < departure($1) }
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
