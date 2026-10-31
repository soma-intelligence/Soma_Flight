import Foundation
import Observation

@MainActor @Observable
public final class AirportStore {
    public private(set) var airport: Airport?
    public private(set) var departures: AirportBoard?
    public private(set) var arrivals: AirportBoard?
    public private(set) var stats: (departures: DelayStats, arrivals: DelayStats)?
    public private(set) var weather: Weather?
    /// The security wait per checkpoint; nil outside the US or when it failed (never an error banner).
    public private(set) var security: SecurityWait?
    public private(set) var fetchedAt: [BoardKind: Date] = [:]
    public private(set) var error: APIError?

    private let code: String
    private let service: any AirportService
    private let securityService: any SecurityWaitService

    /// - Parameter security: the security wait; the default asks nothing and shows no Security section.
    public init(code: String, airports: any AirportService,
                security: any SecurityWaitService = UnavailableSecurityWaitService()) {
        self.code = code; self.service = airports; self.securityService = security
    }

    /// Loads every part; a failing part keeps its previous value and sets `error`.
    public func load() async {
        var firstError: APIError?
        func note(_ e: APIError) { if firstError == nil { firstError = e } }

        do { airport = try await service.airport(code) } catch { note(error) }
        do {
            let b = try await service.board(code, .departures)
            departures = b; fetchedAt[.departures] = b.fetchedAt
        } catch { note(error) }
        do {
            let b = try await service.board(code, .arrivals)
            arrivals = b; fetchedAt[.arrivals] = b.fetchedAt
        } catch { note(error) }
        do {
            let s = try await service.stats(code)
            stats = (s.departures, s.arrivals); fetchedAt[.stats] = s.fetchedAt
        } catch { note(error) }
        do {
            let w = try await service.weather(code)
            weather = w.weather; fetchedAt[.weather] = w.fetchedAt
        } catch { note(error) }
        // A nicety: a failure keeps what the section shows and sets no error.
        if let s = try? await securityService.securityWait(airport: code) { security = s }
        error = firstError
    }
}
