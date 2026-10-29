#if os(iOS)
import ActivityKit
import Foundation

/// ActivityKit for `FlightActivityController`. Watches the push tokens of every activity it starts and
/// of the ones already running at launch, and hands each token to `onPushToken`.
@MainActor
public final class SystemFlightActivityHost: FlightActivityHost {
    public var onPushToken: (@MainActor (Data, UUID) async -> Void)? {
        didSet { live.forEach(watch) }
    }
    private var watched: [String: Task<Void, Never>] = [:]

    public init() {}

    public var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var live: [Activity<FlightActivityAttributes>] {
        Activity<FlightActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    public func running() -> [RunningFlightActivity] {
        live.map {
            RunningFlightActivity(id: $0.id, flightId: $0.attributes.flightId, ownerId: $0.attributes.ownerId,
                                  state: $0.content.state)
        }
    }

    public func start(attributes: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) throws -> String {
        let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: state.staleDate),
                                            pushType: .token)
        watch(activity)
        return activity.id
    }

    public func update(id: String, state: FlightActivityAttributes.ContentState) async {
        await Self.update(id: id, state: state)
    }

    public func end(id: String, state: FlightActivityAttributes.ContentState?, dismissAt: Date?) async {
        watched.removeValue(forKey: id)?.cancel()
        await Self.end(id: id, state: state, dismissAt: dismissAt)
    }

    // The activity is looked up off the main actor, where ActivityKit's async calls run, so it never
    // crosses an isolation boundary.
    private nonisolated static func update(id: String, state: FlightActivityAttributes.ContentState) async {
        guard let a = Activity<FlightActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await a.update(.init(state: state, staleDate: state.staleDate))
    }

    private nonisolated static func end(id: String, state: FlightActivityAttributes.ContentState?, dismissAt: Date?) async {
        guard let a = Activity<FlightActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await a.end(state.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: dismissAt.map { .after($0) } ?? .immediate)
    }

    /// Each token, the first and every new one, goes to `onPushToken` with the activity's flight.
    private func watch(_ activity: Activity<FlightActivityAttributes>) {
        guard watched[activity.id] == nil else { return }
        let flightId = activity.attributes.flightId, id = activity.id
        watched[id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self else { return }
                if let handler = self.onPushToken { await handler(token, flightId) }
            }
            // The activity ended, here or by the system or the user: stop tracking it.
            self?.watched[id] = nil
        }
    }
}
#endif
