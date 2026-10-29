import Foundation

public enum FlightQuery: Sendable, Equatable {
    case ident(String, date: Date)
    case route(origin: String, destination: String, date: Date)
    case airport(String)

    /// Interprets search text. An ident wins over an airport code ("AF84").
    /// Idents: 2-3 char airline code (letters, or letter+digit) then 1-4 digits.
    /// Routes: two 3-4 letter codes split by space, dash or "to". A lone 3-4 letter code is an airport.
    public static func parse(_ text: String, date: Date) -> FlightQuery? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !t.isEmpty else { return nil }
        if let m = t.wholeMatch(of: /([A-Z]{2,3}|[A-Z][0-9]|[0-9][A-Z])\s?([0-9]{1,4})/) {
            return .ident(String(m.1) + String(m.2), date: date)
        }
        if let m = t.wholeMatch(of: /([A-Z]{3,4})(?:\s+TO\s+|\s*-\s*|\s+)([A-Z]{3,4})/) {
            return .route(origin: String(m.1), destination: String(m.2), date: date)
        }
        if t.wholeMatch(of: /[A-Z]{3,4}/) != nil { return .airport(t) }
        return nil
    }
}

public protocol FlightService: Sendable {
    func lookup(_ query: FlightQuery) async throws(APIError) -> [Flight]
    func followed() async throws(APIError) -> [Flight]
    func follow(_ id: Flight.ID, notify: Bool) async throws(APIError)
    func unfollow(_ id: Flight.ID) async throws(APIError)
    /// Whether the signed-in user gets alerts for a followed flight; nil when the flight is not followed.
    func notifies(_ id: Flight.ID) async throws(APIError) -> Bool?
    func flight(_ id: Flight.ID) async throws(APIError) -> Flight
    func events(_ id: Flight.ID) async throws(APIError) -> [FlightEvent]
    func updates(for ids: [Flight.ID]) -> AsyncStream<Flight>
}
