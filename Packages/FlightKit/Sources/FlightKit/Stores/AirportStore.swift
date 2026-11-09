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
        return AirportStatus.of(overview, live: live, assessment: programs?.assessment)
    }

    /// True once the backend said it has no board provider: no boards, no delay numbers, a calm note instead.
    public var needsDataPlan: Bool { liveStats?.available == false }

    /// True once the first load has finished: the card waits for it, then shows every part at once.
    public private(set) var hasLoaded = false

    /// Loads every part at the same time and shows them together, so the card fills in one go rather than
    /// section after section. A failing part keeps its previous value and sets `error`.
    public func load() async {
        let code = self.code, service = self.service, overviewService = self.overviewService
        let securityService = self.securityService, faaService = self.faaService
        @Sendable func result<T>(_ work: () async throws(APIError) -> T) async -> Result<T, APIError> {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        // Asked with the rest: without a board provider the boards fail quietly and are dropped below.
        async let airportR = result { () async throws(APIError) in try await service.airport(code) }
        async let liveR = try? await overviewService.liveStats(code)
        async let overviewR = try? await overviewService.overviews([code]).first
        async let depR = result { () async throws(APIError) in try await service.board(code, .departures) }
        async let arrR = result { () async throws(APIError) in try await service.board(code, .arrivals) }
        async let statsR = result { () async throws(APIError) in try await service.stats(code) }
        async let weatherR = result { () async throws(APIError) in try await service.weather(code) }
        async let securityR = try? await securityService.securityWait(airport: code)
        async let programsR = try? await faaService.programs(airport: code)
        async let notamsR = try? await faaService.notams(airport: code)

        let (a, live, o, dep, arr, st, w, sec, prog, nots) =
            await (airportR, liveR, overviewR, depR, arrR, statsR, weatherR, securityR, programsR, notamsR)
        let regularsR = try? await overviewService.regulars((try? a.get())?.id ?? code)

        var firstError: APIError?
        func note(_ e: APIError) { if firstError == nil { firstError = e } }
        switch a { case .success(let v): airport = v; case .failure(let e): note(e) }
        if let live { liveStats = live }
        if let o { overview = o }
        if let regularsR { regulars = regularsR }
        switch w {
        case .success(let v): weather = v.weather; fetchedAt[.weather] = v.fetchedAt
        case .failure(let e): note(e)
        }
        if !needsDataPlan {
            switch dep { case .success(let b): departures = b; fetchedAt[.departures] = b.fetchedAt; case .failure(let e): note(e) }
            switch arr { case .success(let b): arrivals = b; fetchedAt[.arrivals] = b.fetchedAt; case .failure(let e): note(e) }
            switch st {
            case .success(let v): stats = (v.departures, v.arrivals); fetchedAt[.stats] = v.fetchedAt
            case .failure(let e): note(e)
            }
            // The provider's summary stands in for board stats it could not give (an airport without a board).
            if stats == nil, let d = liveStats?.departures, let a = liveStats?.arrivals {
                stats = (d.delayStats, a.delayStats)
                if let at = liveStats?.fetchedAt { fetchedAt[.stats] = at }
                if firstError == .notFound { firstError = nil }
            }
        }
        // Niceties: a failure keeps what the section shows and sets no error.
        if let sec { security = sec }
        if let prog { programs = prog }
        if let nots { notams = nots }
        error = firstError
        hasLoaded = true
    }
}
