import Foundation
import Testing
@testable import FlightKit

/// Delay and gate predictions: the mapping to the Rust core, the store, the fakes and the gate history
/// service. The core's own rules are tested in `core/flightcore/src/predict.rs`.
@MainActor @Suite struct PredictionTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let out = now.addingTimeInterval(2 * 3600)

    static func flight(status: FlightStatus = .scheduled, estimatedOut: Date? = nil, gate: String? = nil,
                       type: String? = "A320") -> Flight {
        Flight(providerId: "p", ident: "AF84", operator: "AF", originIcao: "KSFO", originIata: "SFO",
               destinationIcao: "LFPG", destinationIata: "CDG", scheduledOut: out,
               scheduledIn: out.addingTimeInterval(11 * 3600), estimatedOut: estimatedOut, gateOrigin: gate,
               aircraftType: type, status: status)
    }

    /// The plane's leg into SFO, landing `lateBy` minutes after its schedule of 50 minutes before departure.
    static func leg(lateBy: Int, status: FlightStatus = .enRoute, into: String = "SFO") -> InboundLeg {
        InboundLeg(id: "in", ident: "AF83", originIata: "CDG", destinationIata: into,
                   scheduledOut: out.addingTimeInterval(-12 * 3600), scheduledIn: out.addingTimeInterval(-50 * 60),
                   status: status, delayMinutes: lateBy)
    }

    static func stats(avg: Double, delayed: Int, total: Int = 40) -> DelayStats {
        DelayStats(total: total, onTime: total - delayed, delayed15: delayed, canceled: 0, avgDelayMinutes: avg,
                   perHour: [], worstRoutes: [], worstAirlines: [], severity: avg >= 45 ? .major : .moderate)
    }

    static func weather(wx: String, ceiling: Int?, vis: Double, wind: Int, gust: Int?) -> Weather {
        Weather(metarRaw: "KSFO 012256Z \(wind)KT \(wx)", tafRaw: nil, tempC: 12, windDirDeg: 280, windKt: wind,
                gustKt: gust, visibilitySm: vis, ceilingFt: ceiling, category: .IFR, observedAt: now, forecast: [],
                wx: wx)
    }

    func delay(_ f: Flight = flight(), inbound: [InboundLeg] = [], forecast: ArrivalForecast? = nil,
               stats: DelayStats? = nil, origin: Weather? = nil, destination: Weather? = nil) -> DelayPrediction? {
        Predictions.delay(f, inbound: inbound, forecast: forecast, originStats: stats, originWeather: origin,
                          destinationWeather: destination, now: Self.now)
    }

    // MARK: Delay, one per reason

    @Test func lateInboundAirborneIsHigh() {
        // Lands 40 minutes late, 10 before departure; a 35 minute turn makes it 25 late.
        let p = delay(inbound: [Self.leg(lateBy: 40)])
        #expect(p?.minutes == 25)
        #expect(p?.reason == .lateInbound)
        #expect(p?.confidence == .high)
        #expect(p?.summary == "Likely 25 min late: inbound aircraft running late")
        #expect(p?.headline == "Likely 25 min late")
        #expect(p?.cause == "Inbound aircraft running late.")
        // Still at its gate: medium.
        #expect(delay(inbound: [Self.leg(lateBy: 40, status: .scheduled)])?.confidence == .medium)
    }

    @Test func weatherAtTheOrigin() {
        let storm = Self.weather(wx: "+TSRA", ceiling: 400, vis: 0.5, wind: 35, gust: 48)
        let p = delay(origin: storm)
        #expect(p?.reason == .originWeather)
        #expect(p?.reasonTitle == "Weather at SFO")
        #expect(p?.minutes == 45)
    }

    @Test func congestionFromTheBoard() {
        let p = delay(stats: Self.stats(avg: 48, delayed: 24))
        #expect(p?.reason == .congestion)
        #expect(p?.reasonTitle == "Airport congestion")
        #expect(p?.minutes == 50)
        #expect(p?.confidence == .medium)
    }

    @Test func historyAloneIsLow() {
        let often = ArrivalForecast(ident: "AF84", days: 60, observed: 30, latePercent: 70, averageLateMinutes: 40,
                                    percents: [:])
        let p = delay(forecast: often)
        #expect(p?.reason == .history)
        #expect(p?.confidence == .low)
        #expect(p?.minutes == 30)
    }

    // MARK: No delay prediction

    @Test func nothingWhenWeakOrTold() {
        #expect(delay() == nil)
        // A plane landing in time, a calm board.
        #expect(delay(inbound: [Self.leg(lateBy: 0)], stats: Self.stats(avg: 5, delayed: 2)) == nil)
        // A leg into another airport is not this flight's plane.
        #expect(delay(inbound: [Self.leg(lateBy: 40, into: "LAX")]) == nil)
        // The airline already says 20 minutes.
        #expect(delay(Self.flight(estimatedOut: Self.out.addingTimeInterval(20 * 60)),
                      inbound: [Self.leg(lateBy: 40)]) == nil)
        // The flight left.
        #expect(delay(Self.flight(status: .departed), inbound: [Self.leg(lateBy: 40)]) == nil)
        // The weather far from now: a METAR says nothing about a flight 20 hours away.
        let storm = Self.weather(wx: "+TSRA", ceiling: 400, vis: 0.5, wind: 35, gust: 48)
        var later = Self.flight()
        later.scheduledOut = Self.now.addingTimeInterval(20 * 3600)
        #expect(delay(later, origin: storm) == nil)
    }

    // MARK: Gate

    static let week = GateHistory(
        days: (21...26).map { GateHistory.Day(day: "2026-10-\($0)", gate: "B22", terminal: "2") }
            + [GateHistory.Day(day: "2026-10-27", gate: "B24", terminal: "2")],
        airline: [])

    @Test func gateFromRecentDays() {
        let p = Predictions.gate(Self.flight(), history: Self.week)
        #expect(p?.guess == .gate)
        #expect(p?.label == "B22")
        #expect(p?.badge == "B22")
        #expect(p?.headline == "Likely gate B22")
        #expect(p?.detail == "Used 6 of the last 7 days")
        #expect(PredictionFacts.gateRow(p!).title == "Likely gate B22 in terminal 2")
    }

    @Test func realGateReplacesTheGuess() {
        #expect(Predictions.gate(Self.flight(gate: "B30"), history: Self.week) == nil)
        #expect(Predictions.gate(Self.flight(status: .departed), history: Self.week) == nil)
        #expect(Predictions.gate(Self.flight(), history: nil) == nil)
    }

    @Test func concourseFromTheAirline() {
        let h = GateHistory(days: [], airline: [
            .init(gate: "A10", terminal: "International", flights: 14),
            .init(gate: "A12", terminal: "International", flights: 6),
            .init(gate: "G91", terminal: "International", flights: 4),
        ])
        let p = Predictions.gate(Self.flight(), history: h)
        #expect(p?.guess == .concourse)
        #expect(p?.badge == "A gates")
        #expect(p?.headline == "Likely concourse A")
        #expect(p?.detail == "Where AF usually departs")
        #expect(p?.fromAirline == true)
    }

    @Test func departureDayIsLocalAtTheOrigin() {
        var f = Self.flight()
        f.scheduledOut = Date(timeIntervalSince1970: 1_793_244_600) // 2026-10-29T03:30:00Z
        #expect(Predictions.departureDay(f, originTimeZone: TimeZone(identifier: "America/Los_Angeles")) == "2026-10-28")
        #expect(Predictions.departureDay(f, originTimeZone: nil) == "2026-10-29")
    }

    // MARK: Store and fakes

    /// AS312: tomorrow's flight with no gate yet, whose plane (in the fakes) is still flying and late.
    @Test func storeShowsBothOnTheFakes() async throws {
        let flights = FakeFlightService(now: PreviewData.now)
        let f = PreviewData.sparse
        #expect(f.gateOrigin == nil)
        let store = FlightDetailStore(id: f.id, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                      insights: FakeInsightsService(flights: flights), gates: FakeGateHistoryService())
        await store.load()
        await store.loadExtras(now: PreviewData.now)
        let d = try #require(store.delayPrediction(now: PreviewData.now))
        #expect(d.reason == .lateInbound)
        #expect(d.confidence == .high)
        #expect(d.minutes >= 15)
        let g = try #require(store.gatePrediction)
        #expect(g.guess == .gate)
        #expect(g.badge == g.label)
        #expect(g.detail == "Used 6 of the last 7 days")
    }

    @Test func storeWithoutServicesShowsNothing() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let f = PreviewData.sparse
        let store = FlightDetailStore(id: f.id, flights: flights, airports: FakeAirportService(now: PreviewData.now))
        await store.load()
        await store.loadExtras(now: PreviewData.now)
        #expect(store.gatePrediction == nil)
        // No inbound plane without insights: what is left comes from the airports (the fakes: weather at SFO).
        let d = store.delayPrediction(now: PreviewData.now)
        #expect(d?.reason != .lateInbound)
    }

    @Test func gateFailureHidesOnlyTheGuess() async {
        let flights = FakeFlightService(now: PreviewData.now)
        let gates = FakeGateHistoryService()
        await gates.setNextError(.providerUnavailable)
        let f = PreviewData.sparse
        let store = FlightDetailStore(id: f.id, flights: flights, airports: FakeAirportService(now: PreviewData.now),
                                      insights: FakeInsightsService(flights: flights), gates: gates)
        await store.load()
        await store.loadExtras(now: PreviewData.now)
        #expect(store.gatePrediction == nil)
        #expect(store.error == nil)
        #expect(store.delayPrediction(now: PreviewData.now) != nil)
    }

    @Test func passportFlightsPredictNothing() {
        let past = PastFlight(date: PreviewData.now, ident: "AF84", originIcao: "KSFO", destinationIcao: "LFPG",
                              distanceKm: 8965)
        let store = FlightDetailStore(past: past, flights: FakeFlightService(now: PreviewData.now),
                                      airports: FakeAirportService(now: PreviewData.now))
        #expect(store.delayPrediction(now: PreviewData.now) == nil)
        #expect(store.gatePrediction == nil)
    }

    @Test func fakeHistoryIsDeterministic() async throws {
        let a = try await FakeGateHistoryService().gateHistory(ident: "ZZ1", origin: "KSFO", operator: "ZZ", day: "2026-10-30")
        let b = try await FakeGateHistoryService().gateHistory(ident: "ZZ1", origin: "KSFO", operator: "ZZ", day: "2026-10-30")
        #expect(a == b)
        #expect(a.days.map(\.day) == ["2026-10-29", "2026-10-28", "2026-10-27", "2026-10-26", "2026-10-25",
                                      "2026-10-24", "2026-10-23"])
        #expect(a.airline.count == 3)
        let none = try await FakeGateHistoryService().gateHistory(ident: "ZZ1", origin: "KSFO", operator: nil, day: "2026-10-30")
        #expect(none.airline.isEmpty)
    }

    // MARK: Supabase

    @Test func decodesTheFunctionAnswer() throws {
        let json = #"""
        {"days": [{"day": "2026-10-29", "gate": "G91", "terminal": "International"},
                  {"day": "2026-10-28", "gate": "A12", "terminal": null}],
         "airline": [{"gate": "A10", "terminal": "International", "flights": 4}]}
        """#
        let h = try SupabaseGateHistoryService.decode(Data(json.utf8))
        #expect(h.days.count == 2)
        #expect(h.days[1].terminal == nil)
        #expect(h.airline == [.init(gate: "A10", terminal: "International", flights: 4)])
        #expect(try SupabaseGateHistoryService.decode(Data("{}".utf8)) == GateHistory())
    }

    @Test func paramsSendANullOperator() throws {
        let p = SupabaseGateHistoryService.Params(p_ident: "AF84", p_origin: "KSFO", p_operator: nil, p_day: "2026-10-30")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        #expect(obj?["p_operator"] is NSNull)
        #expect(obj?["p_day"] as? String == "2026-10-30")
    }

    @Test func liveAndFakeEnvironmentsWireTheService() async throws {
        let live = AppEnvironment.supabase(config: SupabaseConfig(url: URL(string: "http://127.0.0.1:1")!, anonKey: "test"),
                                           cache: try CacheStore.inMemory(), recents: .memory,
                                           authStorage: MemoryAuthStorage())
        #expect(live.gates is SupabaseGateHistoryService)
        let fake = try await AppEnvironment.fake(now: PreviewData.now)
        #expect(fake.gates is FakeGateHistoryService)
    }
}
