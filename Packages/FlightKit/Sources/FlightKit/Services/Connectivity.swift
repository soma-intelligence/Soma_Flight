import Foundation
import Network
import Observation
import SwiftUI

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

    /// A fixed state, for previews, tests and fakes.
    public init(online: Bool) { isOnline = online }

    /// The system's path, watched until the app quits.
    public static func system() -> Connectivity {
        let c = Connectivity(online: true)
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak c] path in
            let online = path.status == .satisfied
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
