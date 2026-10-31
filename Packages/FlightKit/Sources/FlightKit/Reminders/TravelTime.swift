import CoreLocation
import Foundation
import MapKit

/// Whether the app may read where the traveller is, while it is in use. Soma Flight never asks for more.
public enum LocationAccess: Sendable, Equatable {
    case notDetermined, allowed, denied
}

/// The drive from where the traveller is to an airport, behind a protocol for tests and screenshot runs.
/// Only ever used with the app in the foreground.
@MainActor public protocol TravelTimeProvider: AnyObject {
    var access: LocationAccess { get }
    /// Asks for "when in use" access if the traveller has not answered yet, and returns the answer.
    func requestAccess() async -> LocationAccess
    /// The expected driving time, now, from the current location to `airport`.
    func drivingTime(to airport: Airport) async throws -> TimeInterval
}

/// MapKit's driving ETA (`MKDirections.calculateETA`) from the current location, with Core Location's
/// "when in use" permission. Nothing runs in the background and the location never leaves the device
/// except to Apple Maps for the route.
@MainActor public final class MapKitTravelTime: NSObject, TravelTimeProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<LocationAccess, Never>] = []

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var access: LocationAccess { Self.access(manager.authorizationStatus) }

    nonisolated static func access(_ status: CLAuthorizationStatus) -> LocationAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        default: .denied
        }
    }

    public func requestAccess() async -> LocationAccess {
        guard access == .notDetermined else { return access }
        return await withCheckedContinuation { c in
            waiters.append(c)
            manager.requestWhenInUseAuthorization()
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let answer = Self.access(manager.authorizationStatus)
        Task { @MainActor in self.answered(answer) }
    }

    private func answered(_ answer: LocationAccess) {
        // The delegate also hears the status once on creation, before any question.
        guard answer != .notDetermined else { return }
        let pending = waiters
        waiters = []
        for c in pending { c.resume(returning: answer) }
    }

    public func drivingTime(to airport: Airport) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = MKMapItem(location: CLLocation(latitude: airport.lat, longitude: airport.lon), address: nil)
        request.transportType = .automobile
        return try await MKDirections(request: request).calculateETA().expectedTravelTime
    }
}
