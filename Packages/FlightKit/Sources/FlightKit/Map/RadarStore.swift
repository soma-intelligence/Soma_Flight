import CoreLocation
import Foundation
import Observation

/// Where the radar can learn the user's place. Never asks: it answers only when the permission is already
/// granted (the leave-by reminders ask for it, with their own reasons).
@MainActor public protocol RadarLocating {
    /// The current place when location is already allowed, else nil. Never shows a permission prompt.
    func locationIfAllowed() async -> CLLocationCoordinate2D?
}

/// Core Location's "when in use" permission, read and never requested.
@MainActor public final class SystemRadarLocator: NSObject, RadarLocating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiter: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    nonisolated static func allowed(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        status == .authorizedAlways || status == .authorized
        #else
        status == .authorizedAlways || status == .authorizedWhenInUse
        #endif
    }

    public func locationIfAllowed() async -> CLLocationCoordinate2D? {
        guard Self.allowed(manager.authorizationStatus) else { return nil }
        // A fix from the last ten minutes is plenty for a 100 km radar.
        if let last = manager.location, abs(last.timestamp.timeIntervalSinceNow) < 600 { return last.coordinate }
        guard waiter == nil else { return manager.location?.coordinate }
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            waiter = c
            manager.requestLocation()
            // requestLocation answers or fails on its own; this is only a backstop.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finish(self?.manager.location?.coordinate)
            }
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        guard let w = waiter else { return }
        waiter = nil
        w.resume(returning: coordinate)
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in self.finish(c) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(self.manager.location?.coordinate) }
    }
}

/// A place for tests and fakes.
@MainActor public final class FakeRadarLocator: RadarLocating {
    public var coordinate: CLLocationCoordinate2D?
    public private(set) var asked = 0
    public init(_ coordinate: CLLocationCoordinate2D? = nil) { self.coordinate = coordinate }
    public func locationIfAllowed() async -> CLLocationCoordinate2D? { asked += 1; return coordinate }
}

/// The radar's state: the place it looks around, the planes in the air there, the plane the user tapped and
/// the one they follow. `run()` refreshes every `interval` seconds until its task is cancelled, which the view
/// does when it disappears, so nothing is read while the radar is hidden.
@MainActor @Observable
public final class RadarStore {
    public enum Place: Equatable, Sendable {
        /// The user's own place (location was already allowed).
        case me(latitude: Double, longitude: Double)
        case airport(Airport)

        public var coordinate: CLLocationCoordinate2D {
            switch self {
            case let .me(lat, lon): CLLocationCoordinate2D(latitude: lat, longitude: lon)
            case let .airport(a): CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// No place yet: no location permission and no airport chosen.
        case needsPlace
        case loading
        case ready
        case failed(APIError)
    }

    public static let defaultRadiusKm = 100.0
    public static let refreshInterval: Duration = .seconds(60)

    public private(set) var place: Place?
    public private(set) var flights: [NearbyFlight] = []
    public private(set) var status: Status = .needsPlace
    public private(set) var updatedAt: Date?
    public private(set) var stale = false
    public private(set) var truncated = false
    public var selectedID: NearbyFlight.ID?
    /// The followed plane: the radar recentres on it and looks around it, so it stays in view.
    public private(set) var followedID: NearbyFlight.ID?
    /// Bumped when the camera should move (new place, followed plane moved).
    public private(set) var cameraSerial = 0
    public private(set) var refreshes = 0

    @ObservationIgnored private let service: any NearbyFlightsService
    @ObservationIgnored private let locator: any RadarLocating
    @ObservationIgnored private let lookup: @Sendable (String) -> Airport?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var lastFollowed: NearbyFlight?

    public init(service: any NearbyFlightsService, locator: any RadarLocating, lookup: @escaping @Sendable (String) -> Airport?,
                startAt airport: Airport? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.service = service; self.locator = locator; self.lookup = lookup; self.sleep = sleep
        if let airport { place = .airport(airport) }
    }

    public var selected: NearbyFlight? { flights.first { $0.id == selectedID } ?? (selectedID == followedID ? lastFollowed : nil) }
    public var followed: NearbyFlight? { followedID == nil ? nil : (flights.first { $0.id == followedID } ?? lastFollowed) }

    /// Picks an airport by IATA or ICAO code. False when the code is unknown.
    @discardableResult public func choose(code: String) -> Bool {
        guard let airport = lookup(code) else { return false }
        choose(airport: airport)
        return true
    }

    public func choose(airport: Airport) {
        place = .airport(airport)
        followedID = nil; lastFollowed = nil; selectedID = nil
        flights = []; status = .loading; cameraSerial += 1
    }

    /// Use my place, when location is already allowed. False when it is not (nothing is asked).
    @discardableResult public func useMyLocation() async -> Bool {
        guard let c = await locator.locationIfAllowed() else { return false }
        place = .me(latitude: c.latitude, longitude: c.longitude)
        followedID = nil; lastFollowed = nil; selectedID = nil
        flights = []; status = .loading; cameraSerial += 1
        return true
    }

    public func follow(_ flight: NearbyFlight) {
        followedID = flight.id; lastFollowed = flight; selectedID = flight.id; cameraSerial += 1
    }

    public func stopFollowing() { followedID = nil; lastFollowed = nil }

    /// Refreshes now and then every minute, until the task is cancelled. Starts from my place when location is
    /// already allowed and no place was chosen; with neither, waits for an airport (status `.needsPlace`).
    public func run() async {
        if place == nil { _ = await useMyLocation() }
        while !Task.isCancelled {
            await refresh()
            do { try await sleep(Self.refreshInterval) } catch { return }
        }
    }

    /// One read around the followed plane, else the place. Keeps the planes it had when a read fails.
    public func refresh() async {
        guard let around = followed?.coordinate ?? place?.coordinate else { status = .needsPlace; return }
        if flights.isEmpty { status = .loading }
        do {
            let got = try await service.nearby(latitude: around.latitude, longitude: around.longitude,
                                               radiusKm: Self.defaultRadiusKm)
            guard !Task.isCancelled else { return }
            flights = got.flights; updatedAt = got.fetchedAt; stale = got.stale; truncated = got.truncated
            status = .ready; refreshes += 1
            if let id = followedID, let now = got.flights.first(where: { $0.id == id }) {
                lastFollowed = now; cameraSerial += 1
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error)
        }
    }
}
