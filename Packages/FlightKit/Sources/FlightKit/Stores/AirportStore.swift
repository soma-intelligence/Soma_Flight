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
    /// The FAA's live programs (ground stops, delay programs, closures); nil outside the US or on failure.
    public private(set) var programs: AirportPrograms?
    /// Decoded NOTAMs; nil until the backend has the FAA NOTAM key, or on failure.
    public private(set) var notams: NotamReport?
    /// The board provider's live numbers (`airport-stats`). `available` false: the backend has none, and the
    /// card shows its "needs a data plan" note instead of the boards and every number made from them.
    public private(set) var liveStats: AirportLiveStats?
    /// The decoded METAR words and the FAA programs (`airport-weather`), for the status card.
    public private(set) var overview: AirportOverview?
    /// The user and friends who share their Passport, by flights through this airport.
    public private(set) var regulars: [RunwayRegular] = []
    public private(set) var fetchedAt: [BoardKind: Date] = [:]
    public private(set) var error: APIError?

    private let code: String
    private let service: any AirportService
    private let securityService: any SecurityWaitService
    private let faaService: any FAAService
    private let overviewService: any AirportOverviewService

    /// - Parameters:
    ///   - security: the security wait; the default asks nothing and shows no Security section.
    ///   - faa: FAA programs and NOTAMs; the default asks nothing and shows none.
    public init(code: String, airports: any AirportService,
                security: any SecurityWaitService = UnavailableSecurityWaitService(),
                faa: any FAAService = UnavailableFAAService(),
                overview: any AirportOverviewService = UnavailableAirportOverviewService()) {
        self.code = code; self.service = airports; self.securityService = security; self.faaService = faa
        self.overviewService = overview
    }

    /// The overall status from the FAA programs, the weather and the provider's numbers.
    public var status: AirportStatus {
        let live = liveStats.flatMap { l in
            l.available ? AirportLiveSummary(icao: l.icao, departures: l.departures?.brief, arrivals: l.arrivals?.brief,
                                             stale: l.stale) : nil
        }
        return AirportStatus.of(overview, live: live)
    }

    /// True once the backend said it has no board provider: no boards, no delay numbers, a calm note instead.
    public var needsDataPlan: Bool { liveStats?.available == false }

    /// Loads every part; a failing part keeps its previous value and sets `error`.
    public func load() async {
        var firstError: APIError?
        func note(_ e: APIError) { if firstError == nil { firstError = e } }

        do { airport = try await service.airport(code) } catch { note(error) }
        // Asked first: without a board provider the boards would only fail.
        if let live = try? await overviewService.liveStats(code) { liveStats = live }
        if let o = try? await overviewService.overviews([code]).first { overview = o }
        if let r = try? await overviewService.regulars(airport?.id ?? code) { regulars = r }
        if needsDataPlan {
            do {
                let w = try await service.weather(code)
                weather = w.weather; fetchedAt[.weather] = w.fetchedAt
            } catch { note(error) }
            if let s = try? await securityService.securityWait(airport: code) { security = s }
            if let p = try? await faaService.programs(airport: code) { programs = p }
            if let n = try? await faaService.notams(airport: code) { notams = n }
            error = firstError
            return
        }
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
        // The provider's summary stands in for board stats it could not give (an airport without a board).
        if stats == nil, let d = liveStats?.departures, let a = liveStats?.arrivals {
            stats = (d.delayStats, a.delayStats)
            if let at = liveStats?.fetchedAt { fetchedAt[.stats] = at }
            if firstError == .notFound { firstError = nil }
        }
        // A nicety: a failure keeps what the section shows and sets no error.
        if let s = try? await securityService.securityWait(airport: code) { security = s }
        // FAA advisories likewise: a failure keeps what is shown.
        if let p = try? await faaService.programs(airport: code) { programs = p }
        if let n = try? await faaService.notams(airport: code) { notams = n }
        error = firstError
    }
}
