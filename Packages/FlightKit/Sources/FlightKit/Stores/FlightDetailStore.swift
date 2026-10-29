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

    private let id: Flight.ID
    private let flights: any FlightService
    private let airports: any AirportService

    public init(id: Flight.ID, flights: any FlightService, airports: any AirportService) {
        self.id = id; self.flights = flights; self.airports = airports
    }

    public func load() async {
        do {
            let f = try await flights.flight(id)
            flight = f
            events = (try? await flights.events(id)) ?? events
            var destCode = f.destinationIcao
            if f.status == .diverted,
               let d = events.last(where: { $0.kind == .diversion })?.payload["destination"], !d.isEmpty {
                destCode = d
            }
            origin = try? await airports.airport(f.originIcao)
            destination = try? await airports.airport(destCode)
            error = nil
        } catch { self.error = error }
    }
}
