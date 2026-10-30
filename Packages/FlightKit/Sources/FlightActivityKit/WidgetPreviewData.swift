import Foundation

public extension WidgetSnapshot {
    /// Four followed flights around `now`, for the widget gallery's placeholder, the previews and the
    /// tests: AF 84 in the air and running late, UA 1527 leaving in under three hours 25 minutes late from
    /// gate F11, DL 401 tomorrow on time, BA 287 in three days with only its schedule known.
    static func preview(now: Date = .now) -> Self {
        func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        let cdg = WidgetAirport(code: "CDG", city: "Paris", timeZone: "Europe/Paris")
        let sfo = WidgetAirport(code: "SFO", city: "San Francisco", timeZone: "America/Los_Angeles")
        let aus = WidgetAirport(code: "AUS", city: "Austin", timeZone: "America/Chicago")
        let jfk = WidgetAirport(code: "JFK", city: "New York", timeZone: "America/New_York")
        let lhr = WidgetAirport(code: "LHR", city: "London", timeZone: "Europe/London")
        return Self(generatedAt: now, flights: [
            WidgetFlight(id: UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000000084")!, ident: "AF84", airlineIcao: "AFR",
                         origin: cdg, destination: sfo,
                         scheduledOut: at(-4.5), scheduledIn: at(6.5), bestOut: at(-4.25), bestIn: at(6.83),
                         status: .enRoute, gateOrigin: "K42", gateDestination: "G91",
                         terminalOrigin: "2E", terminalDestination: "I",
                         departureDelayMinutes: 15, arrivalDelayMinutes: 20, progress: 0.38),
            WidgetFlight(id: UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000001527")!, ident: "UA1527", airlineIcao: "UAL",
                         origin: sfo, destination: aus,
                         scheduledOut: at(2.4), scheduledIn: at(5.9), bestOut: at(2.82), bestIn: at(6.2),
                         status: .scheduled, gateOrigin: "F11", terminalOrigin: "3",
                         departureDelayMinutes: 25, arrivalDelayMinutes: 18),
            WidgetFlight(id: UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000000401")!, ident: "DL401", airlineIcao: "DAL",
                         origin: jfk, destination: sfo,
                         scheduledOut: at(26), scheduledIn: at(32.5), bestOut: at(26), bestIn: at(32.4),
                         status: .scheduled, terminalOrigin: "4",
                         departureDelayMinutes: 0, arrivalDelayMinutes: -6),
            WidgetFlight(id: UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000000287")!, ident: "BA287", airlineIcao: "BAW",
                         origin: lhr, destination: sfo,
                         scheduledOut: at(74), scheduledIn: at(85), bestOut: at(74), bestIn: at(85),
                         status: .scheduled),
        ])
    }
}
