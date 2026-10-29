import Foundation

public enum ExportFormat: Sendable, Hashable {
    case json, csv
}

public protocol HistoryService: Sendable {
    func pastFlights() async throws(APIError) -> [PastFlight]
    func export(_ format: ExportFormat) async throws(APIError) -> Data
}
