import Foundation

public extension FlightActivityAttributes.ContentState {
    /// The state the backend would push for `flight` (push-sender's `contentState`): best estimate else
    /// schedule for both times, progress from the same times rounded to 0.001. The app starts and
    /// updates the activity with it, so local and pushed updates agree.
    static func from(_ flight: Flight, now: Date = .now) -> Self {
        Self(status: flight.status, gateOrigin: flight.gateOrigin, gateDestination: flight.gateDestination,
             estimatedOut: flight.estimatedOut ?? flight.scheduledOut,
             estimatedIn: flight.estimatedIn ?? flight.scheduledIn,
             progress: (progress(of: flight, at: now) * 1000).rounded() / 1000)
    }

    /// push-sender's `progressOf`: 1 once down, 0 before departure, else elapsed over the best times.
    static func progress(of f: Flight, at now: Date) -> Double {
        switch f.status {
        case .arrived, .landed: return 1
        case .scheduled, .unknown: return 0
        default: break
        }
        guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut,
              let inn = f.actualIn ?? f.actualOn ?? f.estimatedIn ?? f.scheduledIn,
              inn > out else { return 0 }
        return min(1, max(0, now.timeIntervalSince(out) / inn.timeIntervalSince(out)))
    }
}

public extension FlightActivityAttributes {
    /// The static part for `flight`: IATA codes (ICAO when there is none) and the airports' time zones.
    static func from(_ flight: Flight, lookup: (String) -> Airport?) -> Self {
        Self(flightId: flight.id, ident: flight.ident,
             originIata: flight.originIata ?? flight.originIcao,
             destinationIata: flight.destinationIata ?? flight.destinationIcao,
             scheduledOut: flight.scheduledOut, scheduledIn: flight.scheduledIn,
             originTimeZone: lookup(flight.originIcao)?.tz,
             destinationTimeZone: lookup(flight.destinationIcao)?.tz)
    }
}
