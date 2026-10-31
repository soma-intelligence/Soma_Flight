import Foundation

/// A 35 minute drive to any airport with location allowed, for screenshot runs (`-useFakes`) and tests.
@MainActor public final class FakeTravelTime: TravelTimeProvider {
    public var access: LocationAccess
    public var drive: TimeInterval
    /// Set to make the next ETA fail.
    public var failNext = false
    public private(set) var requests = 0

    public init(access: LocationAccess = .allowed, drive: TimeInterval = 35 * 60) {
        self.access = access; self.drive = drive
    }

    public func requestAccess() async -> LocationAccess {
        if access == .notDetermined { access = .allowed }
        return access
    }

    public func drivingTime(to airport: Airport) async throws -> TimeInterval {
        requests += 1
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
        return drive
    }
}
