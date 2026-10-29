import Foundation
import Observation

@MainActor @Observable
public final class FlightDetailStore {
    public private(set) var flight: Flight?
    public private(set) var events: [FlightEvent] = []
    public private(set) var origin: Airport?
    /// The airport the flight actually ended at: the diversion target when diverted.
    public private(set) var destination: Airport?
    public private(set) var error: APIError?
    /// Alerts for this flight: true or false while the user follows it, nil when not followed or unknown.
    public private(set) var notify: Bool?
    /// A notify change is on its way to the server.
    public private(set) var isSavingNotify = false

    private let id: Flight.ID
    private let flights: any FlightService
    private let airports: any AirportService
    private let cache: (any FlightListCache)?

    public init(id: Flight.ID, flights: any FlightService, airports: any AirportService, cache: (any FlightListCache)? = nil) {
        self.id = id; self.flights = flights; self.airports = airports; self.cache = cache
    }

    /// Failures set `error` (first one wins) and keep earlier data. A diverted flight whose events
    /// failed shows no destination rather than the planned one.
    public func load() async {
        var firstError: APIError?
        func note(_ e: APIError) { if firstError == nil { firstError = e } }
        // Last known state first, so the screen is not blank while the network answers or when it is down.
        if flight == nil, let cache {
            let cached = await cache.flights().first { $0.id == id }
            if flight == nil { flight = cached }
        }
        let f: Flight
        do { f = try await flights.flight(id) } catch { self.error = error; return }
        flight = f
        // The switch only: a failure hides it rather than covering the flight with an error.
        if !isSavingNotify, let n = try? await flights.notifies(id), !isSavingNotify { notify = n }

        var eventsFailed = false
        do { events = try await flights.events(id) } catch { note(error); eventsFailed = true }

        var destCode: String? = f.destinationIcao
        if f.status == .diverted {
            if let d = events.last(where: { $0.kind == .diversion })?.payload["destination"], !d.isEmpty {
                destCode = d
            } else if eventsFailed {
                destCode = nil
            }
        }
        do { origin = try await airports.airport(f.originIcao) } catch { note(error) }
        if let destCode {
            do { destination = try await airports.airport(destCode) } catch { note(error); destination = nil }
        } else {
            destination = nil
        }
        error = firstError
    }

    /// Turns alerts for the followed flight on or off (`follow(_:notify:)`). The switch moves at once and
    /// goes back, with `error` set, when the server refuses.
    public func setNotify(_ on: Bool) async {
        guard let before = notify, before != on, !isSavingNotify else { return }
        notify = on
        isSavingNotify = true
        defer { isSavingNotify = false }
        do {
            try await flights.follow(id, notify: on)
        } catch {
            notify = before
            self.error = error
        }
    }
}
