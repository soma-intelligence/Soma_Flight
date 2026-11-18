import Foundation
import Network
import Observation
import SwiftUI
import Synchronization

/// Whether the device has a path to the internet right now (`NWPathMonitor`). The flight sheet, the globe
/// and the home read it to switch to estimates and the offline banner; nothing is blocked on it, since the
/// cache keeps working either way. One monitor for the app (`shared`), started on first use.
///
/// The fakes (`AppEnvironment.fixedConnectivity`) are online unless launched with `-fakeOffline`, so
/// screenshots of both states need no network trick.
@MainActor @Observable
public final class Connectivity {
    public private(set) var isOnline: Bool
    @ObservationIgnored private var monitor: NWPathMonitor?

    /// What the system monitor last said, readable from any thread: the error mapping
    /// (`SupabaseBackend.map`) asks it whether a timeout means "offline" or "the server is down" (E7).
    /// Nil until a system monitor has reported (previews, tests, the fakes).
    public nonisolated static var devicePathOnline: Bool? { pathState.withLock { $0 } }
    nonisolated private static let pathState = Mutex<Bool?>(nil)

    /// Tests: sets what `devicePathOnline` reports.
    nonisolated static func setDevicePathOnline(_ online: Bool?) { pathState.withLock { $0 = online } }

    /// Calls `action` each time the connection comes back (offline to online). The home reloads with it (E2).
    /// Returns nothing to keep: the watch lasts as long as this object.
    public func onReconnect(_ action: @escaping @MainActor () -> Void) {
        reconnectHandlers.append(action)
        watchReconnect()
    }

    @ObservationIgnored private var reconnectHandlers: [@MainActor () -> Void] = []
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var lastSeenOnline: Bool?

    private func watchReconnect() {
        guard !watching else { return }
        watching = true
        lastSeenOnline = isOnline
        observe()
    }

    private func observe() {
        withObservationTracking { _ = isOnline } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = self.isOnline, before = self.lastSeenOnline
                self.lastSeenOnline = now
                if now, before == false { self.reconnectHandlers.forEach { $0() } }
                self.observe()
            }
        }
    }

    /// Tests and the fakes' `-fakeOffline` toggle: moves a fixed connection.
    public func set(online: Bool) { isOnline = online }

    /// A fixed state, for previews, tests and fakes.
    public init(online: Bool) { isOnline = online }

    /// The system's path, watched until the app quits.
    public static func system() -> Connectivity {
        let c = Connectivity(online: true)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak c] path in
            let online = path.status == .satisfied
            Connectivity.setDevicePathOnline(online)
            Task { @MainActor in c?.isOnline = online }
        }
        m.start(queue: DispatchQueue(label: "me.somalabs.flight.connectivity"))
        c.monitor = m
        return c
    }

    /// The app's one system monitor.
    public static let shared = system()
}

private struct ConnectivityKey: EnvironmentKey {
    static var defaultValue: Connectivity? { nil }
}

public extension EnvironmentValues {
    /// The device's connection; nil (previews, snapshot tests) reads as online.
    var connectivity: Connectivity? {
        get { self[ConnectivityKey.self] }
        set { self[ConnectivityKey.self] = newValue }
    }
}
