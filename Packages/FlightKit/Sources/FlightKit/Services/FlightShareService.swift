import Foundation

/// A live link to one flight: `https://somalabs.me/f/<token>`, open to anyone who has it until `expiresAt`
/// (24 hours after the flight arrives, moved by delays) or until the sharer stops sharing.
public struct FlightShareLink: Sendable, Equatable {
    public var url: URL
    public var expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url; self.expiresAt = expiresAt
    }
}

/// Live flight sharing for the flight sheet's Share and "Stop Sharing". Live builds use
/// `SupabaseFlightShareService` (edge function `share-flight`, free: no paid provider behind it); screenshot
/// runs (`-useFakes`) use `FakeFlightShareService`. The page the link opens is `flight-page` on the server.
public protocol FlightShareService: Sendable {
    /// A new link to `flight`, which the user follows. `outOfWindow` once the flight has been down a day.
    func share(_ flight: Flight.ID) async throws(APIError) -> FlightShareLink
    /// When the user's live link to `flight` closes, or nil when they share none that still opens.
    func activeShare(_ flight: Flight.ID) async throws(APIError) -> Date?
    /// Closes every link the user made to `flight`.
    func stopSharing(_ flight: Flight.ID) async throws(APIError)
}

/// No live links (Share hands over the text only), and no network call: the default for views and stores
/// built without a service.
public struct UnavailableFlightShareService: FlightShareService {
    public init() {}
    public func share(_ flight: Flight.ID) async throws(APIError) -> FlightShareLink { throw .providerUnavailable }
    public func activeShare(_ flight: Flight.ID) async throws(APIError) -> Date? { nil }
    public func stopSharing(_ flight: Flight.ID) async throws(APIError) {}
}

/// Links in memory for screenshot runs and tests: each share is a new `somalabs.me/f/` URL that expires a day
/// after `now`, and stopping forgets every link of the flight. Nothing leaves the device.
public actor FakeFlightShareService: FlightShareService {
    public var nextError: APIError?
    /// Every link made, per flight, in order; emptied for a flight by `stopSharing`.
    public private(set) var links: [Flight.ID: [FlightShareLink]] = [:]
    private let clock: @Sendable () -> Date
    private var made = 0

    /// - Parameter now: the clock the links expire from; the real time when nil.
    public init(now: Date? = nil) {
        clock = { now ?? .now }
    }

    public func setNextError(_ error: APIError?) { nextError = error }

    public func share(_ flight: Flight.ID) async throws(APIError) -> FlightShareLink {
        if let e = nextError { nextError = nil; throw e }
        made += 1
        let token = String(format: "Fake%039d", made)
        let link = FlightShareLink(url: URL(string: "https://somalabs.me/f/\(token)")!,
                                   expiresAt: clock().addingTimeInterval(24 * 3600))
        links[flight, default: []].append(link)
        return link
    }

    public func activeShare(_ flight: Flight.ID) async throws(APIError) -> Date? {
        if let e = nextError { nextError = nil; throw e }
        return links[flight]?.last.map(\.expiresAt)
    }

    public func stopSharing(_ flight: Flight.ID) async throws(APIError) {
        if let e = nextError { nextError = nil; throw e }
        links[flight] = nil
    }
}
