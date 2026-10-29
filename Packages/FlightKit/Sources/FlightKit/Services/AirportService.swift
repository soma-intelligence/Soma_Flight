import Foundation

public protocol AirportService: Sendable {
    func airport(_ code: String) async throws(APIError) -> Airport
    func board(_ code: String, _ kind: BoardKind) async throws(APIError) -> AirportBoard
    func stats(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, departures: DelayStats, arrivals: DelayStats)
    func weather(_ code: String) async throws(APIError) -> (fetchedAt: Date, stale: Bool, weather: Weather)
}
