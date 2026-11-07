import Foundation

/// The airports the signed-in account follows for disruption alerts (`favorite_airports`). The server
/// pushes a ground stop, ground delay program or closure at a followed airport once per account and
/// program (function `favorite-airports`). Separate from the star on the airport sheet, which only
/// keeps a list on this device.
public protocol FavoriteAirportAlertsService: Sendable {
    /// ICAO codes of every followed airport.
    func followed() async throws(APIError) -> Set<String>
    /// Follows or stops following one airport (ICAO).
    func set(_ icao: String, following: Bool) async throws(APIError)
}

/// Nothing followed and no network call: the default for builds without a backend.
public struct UnavailableFavoriteAirportAlertsService: FavoriteAirportAlertsService {
    public init() {}
    public func followed() async throws(APIError) -> Set<String> { throw .providerUnavailable }
    public func set(_ icao: String, following: Bool) async throws(APIError) { throw .providerUnavailable }
}
