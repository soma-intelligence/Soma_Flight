import Foundation

/// An in-memory follow list for screenshot runs and tests.
public actor FakeFavoriteAirportAlertsService: FavoriteAirportAlertsService {
    public private(set) var stored: Set<String>
    public private(set) var writes = 0
    public var nextError: APIError?

    public init(_ stored: Set<String> = []) { self.stored = stored }

    public func setNextError(_ error: APIError?) { nextError = error }

    public func followed() async throws(APIError) -> Set<String> {
        if let e = nextError { nextError = nil; throw e }
        return stored
    }

    public func set(_ icao: String, following: Bool) async throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
        if following { stored.insert(icao) } else { stored.remove(icao) }
        writes += 1
    }
}
