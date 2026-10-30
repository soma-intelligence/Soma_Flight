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
    /// What the user noted on the flight (booking code, seat, notes); nil when not followed or unknown.
    public private(set) var details: FollowDetails?
    /// A details change is on its way to the server.
    public private(set) var isSavingDetails = false
    /// Why the last details change did not stick; cleared when the user tries again or opens an editor.
    public private(set) var detailsError: APIError?
    /// Why "Stop Tracking" did not work; the sheet shows it until dismissed.
    public private(set) var trackingError: APIError?
    /// True while the user follows the flight, as far as this screen knows.
    public var isFollowed: Bool { details != nil }

    /// What the server holds, to go back to when a save fails.
    private var confirmedDetails: FollowDetails?
    /// Bumped by every save; only the newest one may roll back or report an error.
    private var detailsGeneration = 0
    /// Saves run one after another, in the order the user made them.
    private var detailsChain: Task<Bool, Never>?

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
        // The tiles likewise: a failure keeps what they show.
        if !isSavingDetails, let d = try? await flights.followDetails(id), !isSavingDetails {
            details = d
            confirmedDetails = d
        }

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

    /// How often an open detail asks for the live position while the flight is in the air: the
    /// backend's shared window, so asking more often never buys a fresher one.
    public static let positionInterval: Duration = .seconds(120)

    /// Keeps the live position fresh while the screen is open (run it in the screen's task, after
    /// `load()`): asks at once, then every `interval`, until the task is cancelled.
    public func followPosition(every interval: Duration = positionInterval) async {
        while !Task.isCancelled {
            await refreshPosition()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// One position refresh for a followed flight that is departed or en route; nothing for the rest.
    /// A failure keeps what is on screen: the position is a nicety, never an error banner.
    func refreshPosition() async {
        guard let f = flight, f.status == .departed || f.status == .enRoute, notify != nil else { return }
        guard let fresh = try? await flights.refreshPosition(id), fresh.id == flight?.id else { return }
        flight = fresh
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

    /// Stores the booking code, seat and notes of the followed flight. Each field is normalised first
    /// (`FollowDetails.normalized()`); a value that does not normalise sends nothing and returns false.
    /// The tiles change at once. Saves are sent one after another and the latest wins: a save that a newer
    /// one replaced before it left is skipped, and only the newest one rolls the tiles back to what the
    /// server holds and sets `detailsError` when refused. Returns whether this edit is now stored (or
    /// superseded by a newer one).
    @discardableResult
    public func saveDetails(_ new: FollowDetails) async -> Bool {
        guard details != nil, let clean = new.normalized() else { return false }
        detailsError = nil
        guard clean != details || clean != confirmedDetails else { return true }
        detailsGeneration += 1
        let generation = detailsGeneration
        details = clean
        isSavingDetails = true
        let previous = detailsChain
        let work = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.send(clean, generation: generation)
        }
        detailsChain = work
        let stored = await work.value
        if generation == detailsGeneration { isSavingDetails = false }
        return stored
    }

    private func send(_ value: FollowDetails, generation: Int) async -> Bool {
        // A newer edit is queued behind this one: only the newest goes to the server.
        guard generation == detailsGeneration else { return true }
        do {
            try await flights.saveFollowDetails(id, value)
            confirmedDetails = value
            return true
        } catch {
            if generation == detailsGeneration {
                details = confirmedDetails
                detailsError = error
            }
            return false
        }
    }

    /// Forgets the last details error (the user opened an editor or dismissed it).
    public func clearDetailsError() { detailsError = nil }

    /// Unfollows the flight. `unfollow` does the work when the screen sits in a shell that keeps its own
    /// list (it returns the error, nil on success); else the service is asked directly. On failure the
    /// sheet stays and `trackingError` says why.
    @discardableResult
    public func stopTracking(via unfollow: ((Flight.ID) async -> APIError?)? = nil) async -> Bool {
        guard isFollowed else { return false }
        trackingError = nil
        let failure: APIError?
        if let unfollow {
            failure = await unfollow(id)
        } else {
            do { try await flights.unfollow(id); failure = nil } catch { failure = error }
        }
        if let failure {
            trackingError = failure
            return false
        }
        details = nil
        confirmedDetails = nil
        notify = nil
        return true
    }

    public func clearTrackingError() { trackingError = nil }
}

extension FollowDetails {
    /// The details as stored: seat and booking code trimmed and upper-cased, notes trimmed, empty text
    /// cleared. nil when any field is not valid (a seat like "ZZ", a 3-letter code, notes over 2000).
    public func normalized() -> FollowDetails? {
        var out = self
        if let s = seat {
            guard let v = Self.normalizedSeat(s) else { return nil }
            out.seat = v
        }
        if let b = bookingCode {
            guard let v = Self.normalizedBookingCode(b) else { return nil }
            out.bookingCode = v
        }
        if let n = notes {
            guard let v = Self.normalizedNotes(n) else { return nil }
            out.notes = v
        }
        return out
    }
}
