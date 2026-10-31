import Foundation
import Testing
@testable import FlightKit

/// Weather impact through the core, delay causes, the Operations Report's decoding and copy, and the
/// lines the airport sheet and the flight sheet take from them.
@MainActor
struct OpsReportTests {
    static let now = PreviewData.now

    static func weather(metar: String, ceiling: Int? = nil, vis: Double? = 10, wind: Int? = 5, gust: Int? = nil,
                        forecast: [ForecastPeriod] = []) -> Weather {
        Weather(metarRaw: metar, tafRaw: nil, tempC: 12, windDirDeg: 200, windKt: wind, gustKt: gust,
                visibilitySm: vis, ceilingFt: ceiling, category: .VFR, observedAt: now, forecast: forecast)
    }

    static func stats(_ severity: Severity, avg: Double = 32, perHour: [HourBucket] = []) -> DelayStats {
        DelayStats(total: 40, onTime: 20, delayed15: 18, canceled: 2, avgDelayMinutes: avg, perHour: perHour,
                   worstRoutes: [], worstAirlines: [], severity: severity)
    }

    static func period(_ from: TimeInterval, _ to: TimeInterval, change: ForecastChange? = nil, prob: Int? = nil,
                       ceiling: Int? = nil, vis: Double = 6, wx: String? = nil) -> ForecastPeriod {
        ForecastPeriod(from: now.addingTimeInterval(from * 3600), to: now.addingTimeInterval(to * 3600),
                       category: .VFR, windDirDeg: 180, windKt: 8, gustKt: nil, visibilitySm: vis, ceilingFt: ceiling,
                       change: change, probability: prob, wx: wx, clouds: nil)
    }

    // MARK: Payload

    @Test func contractWeatherCarriesTheNewFields() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "supabase/functions/airport-board/contract/weather.json")
        let w = try SupabaseAirportService.decodeWeather(Data(contentsOf: url)).weather
        #expect(w.wx == "-RA" && w.clouds?.count == 4 && w.dewpointC == 20 && w.altimeterHpa == 1021.1)
        #expect(w.tafIssuedAt == ISO8601DateFormatter().date(from: "2026-10-29T17:30:00Z"))
        #expect(w.forecast.first?.change == nil && w.forecast.dropFirst().first?.change == .FM)
        #expect(w.forecast.last?.wx == "-RA BR" && w.forecast.last?.clouds?.first?.baseFt == 900)
        // Payloads from before these fields still decode.
        let old = #"{"metarRaw":"KAUS 291744Z 10SM","category":"VFR","observedAt":"2026-10-29T17:44:00Z","forecast":[]}"#
        let decoded = try FlightJSON.decoder.decode(Weather.self, from: Data(old.utf8))
        #expect(decoded.wx == nil && decoded.clouds == nil && decoded.tafIssuedAt == nil)
    }

    // MARK: Impact through the core

    @Test func impactReadsTheRawMetarWhenThePayloadHasNoWx() {
        let fog = Self.weather(metar: "KSFO 240556Z 00000KT 1 1/2SM FG BKN008 12/12 A3001", ceiling: 800, vis: 1.5)
        let i = WeatherImpact.of(fog)
        #expect(i.slows && i.level == .moderate && i.affects == .arrivals)
        #expect(i.reason == "Low clouds and fog: arrivals likely slowed")
        #expect(i.hazards.map(\.kind) == [.lowCeiling, .fog])
        let fine = WeatherImpact.of(Self.weather(metar: "KAUS 231453Z 17012G22KT 10SM FEW040 24/17 A2998", gust: 22))
        #expect(fine.level == .none && !fine.slows && fine.affects == nil)
    }

    @Test func describeAndGroups() {
        #expect(WeatherImpact.describe("+TSRA") == "thunderstorms with heavy rain")
        #expect(WeatherImpact.groups(in: "LFPG 231530Z 21006KT 2500 -DZ BR BKN006 12/11 Q1012 TEMPO 0800 FG") == "-DZ BR")
    }

    @Test func forecastImpactTakesTheWorstOverlay() {
        let w = Self.weather(metar: "KAUS 231453Z 17012KT 10SM FEW040 24/17 A2998", forecast: [
            Self.period(-3, 5), Self.period(4, 8, change: .FM),
            Self.period(5, 9, change: .TEMPO, ceiling: 3000, vis: 3, wx: "TSRA"),
        ])
        let at6 = w.forecastImpact(at: Self.now.addingTimeInterval(6 * 3600))
        #expect(at6?.period.change == .TEMPO && at6?.impact.level == .severe)
        #expect(w.forecastImpact(at: Self.now.addingTimeInterval(1 * 3600))?.impact.level == WeatherImpact.Level.none)
        #expect(w.forecastImpact(at: Self.now.addingTimeInterval(20 * 3600)) == nil)
    }

    // MARK: Causes

    @Test func causeFollowsDelaysAndWeather() {
        let bad = WeatherImpact.of(ceilingFt: 300, visibilitySm: 0.5, windKt: 3, gustKt: nil, wx: "FG")
        let fine = WeatherImpact.of(ceilingFt: nil, visibilitySm: 10, windKt: 5, gustKt: nil, wx: "")
        #expect(DelayCause.of(delayed: true, impact: bad) == .weather(bad))
        #expect(DelayCause.of(delayed: true, impact: fine) == .notWeather(fine))
        #expect(DelayCause.of(delayed: false, impact: bad) == .weatherAhead(bad))
        #expect(DelayCause.of(delayed: false, impact: fine) == .normal)
    }

    @Test func issuesCardSaysWhetherWeatherIsTheCause() {
        let late = Self.stats(.major), fine = Self.stats(.normal)
        let fog = Self.weather(metar: "KSFO 240556Z 00000KT 1 1/2SM FG BKN008 12/12 A3001", ceiling: 800, vis: 1.5)
        #expect(AirportFacts.issuesWeatherLine(fog, departures: late, arrivals: fine)
            == "Fog, 12°C. Likely weather related. Low clouds and fog: arrivals likely slowed.")
        let clear = Self.weather(metar: "KAUS 231453Z 17012KT 10SM FEW040 24/17 A2998")
        #expect(AirportFacts.issuesWeatherLine(clear, departures: late, arrivals: fine)
            == "Few Clouds, 12°C. The weather is fine, so the delays have another cause.")
        let gusty = Self.weather(metar: "KAUS 231453Z 17015G26KT 10SM FEW040 24/17 A2998", wind: 15, gust: 26)
        #expect(AirportFacts.issuesWeatherLine(gusty, departures: late, arrivals: fine)
            == "Few Clouds, 12°C. Weather is not the main cause: only gusty winds here.")
    }

    @Test func goodToKnowAddsTheCause() {
        let fog = Self.weather(metar: "LFPG 231530Z 21006KT 2500 -DZ BR BKN006 12/11 Q1012", ceiling: 600, vis: 1.55)
        let row = DetailFacts.disruption(code: "CDG", stats: Self.stats(.major, avg: 71.6), departures: false, weather: fog)
        #expect(row?.text == "Arrivals average 1h 12m late right now. Likely weather related: low clouds and poor "
            + "visibility. Tap for the airport's details.")
        let clear = Self.weather(metar: "KAUS 231453Z 17012KT 10SM FEW040 24/17 A2998")
        let fineRow = DetailFacts.disruption(code: "AUS", stats: Self.stats(.moderate), departures: true, weather: clear)
        #expect(fineRow?.text == "Departures average 32m late right now. The weather there is fine, so it's not the "
            + "cause. Tap for the airport's details.")
        // No weather, the old wording.
        #expect(DetailFacts.disruption(code: "AUS", stats: Self.stats(.moderate), departures: true)?.text
            == "Departures average 32m late right now. Tap for the airport's details.")
    }

    @Test func arrivalWeatherWarnsOnlyWhenTheForecastSlowsArrivals() {
        let utc = TimeZone(identifier: "UTC")!
        let w = Self.weather(metar: "KAUS 231453Z 17012KT 10SM FEW040 24/17 A2998", forecast: [
            Self.period(-3, 5), Self.period(5, 9, change: .TEMPO, ceiling: 3000, vis: 3, wx: "TSRA"),
            Self.period(5, 12, change: .FM), Self.period(12, 20, change: .PROB, prob: 40, ceiling: 100, vis: 0.2, wx: "FG"),
        ])
        let storm = DetailFacts.arrivalWeather(w, arrival: Self.now.addingTimeInterval(6 * 3600), timeZone: utc)
        #expect(storm?.title == "Weather at arrival")
        #expect(storm?.text == "Thunderstorms forecast at times around your 21:42 arrival. Arrivals may be held up, "
            + "so allow extra time.")
        let fog = DetailFacts.arrivalWeather(w, arrival: Self.now.addingTimeInterval(13 * 3600), timeZone: utc)
        #expect(fog?.text.hasPrefix("Very low clouds and thick fog forecast (40% chance) around your 04:42 arrival.") == true)
        #expect(DetailFacts.arrivalWeather(w, arrival: Self.now.addingTimeInterval(1 * 3600), timeZone: utc) == nil)
        #expect(DetailFacts.arrivalWeather(w, arrival: Self.now.addingTimeInterval(30 * 3600), timeZone: utc) == nil)
        #expect(DetailFacts.arrivalWeather(w, arrival: nil, timeZone: utc) == nil)
    }

    // MARK: Decoding

    @Test func windVisibilityCloudsInPlainWords() {
        #expect(OpsReport.windSentence(dir: 170, kt: 12, gust: 22) == "Wind from the south at 22 km/h, gusting to 41 km/h.")
        #expect(OpsReport.windSentence(dir: nil, kt: 3, gust: nil) == "Variable wind at 6 km/h.")
        #expect(OpsReport.windSentence(dir: nil, kt: 0, gust: nil) == "Calm wind.")
        #expect(OpsReport.windSentence(dir: nil, kt: nil, gust: nil) == "Wind not reported.")
        #expect(OpsReport.compass(0) == "north" && OpsReport.compass(23) == "northeast" && OpsReport.compass(350) == "north")
        #expect(OpsReport.visibilitySentence(10) == "Visibility 10 km or more.")
        #expect(OpsReport.visibilitySentence(1.55) == "Visibility 2.5 km.")
        #expect(OpsReport.cloudSentence([CloudLayer(cover: "BKN", baseFt: 900), CloudLayer(cover: "OVC", baseFt: 13000)])
            == "Broken clouds at 900 ft, overcast at 13,000 ft.")
        #expect(OpsReport.cloudSentence([]) == "No cloud reported.")
        #expect(OpsReport.cloudSentence([CloudLayer(cover: "VV", baseFt: 100)]) == "Sky hidden, vertical visibility 100 ft.")
    }

    @Test func rawMetarFallbacks() {
        let raw = "SPECI KAUS 291744Z VRB03KT 10SM -RA BKN009 OVC130 22/20 A3015 RMK AO2 BKN005"
        #expect(OpsReport.cloudLayers(in: raw) == [CloudLayer(cover: "BKN", baseFt: 900), CloudLayer(cover: "OVC", baseFt: 13000)])
        #expect(OpsReport.dewpoint(in: raw) == 20)
        #expect(OpsReport.dewpoint(in: "KORD 241451Z 27018KT 1/2SM +SN VV005 M04/M06 A2990") == -6)
        #expect(OpsReport.pressure(in: "LFPG 231530Z 21006KT 9999 FEW030 11/07 Q1018") == 1018)
        #expect(abs((OpsReport.pressure(in: raw) ?? 0) - 1021) < 0.5)
    }

    @Test func conditionsTitles() {
        let rain = Self.weather(metar: "SPECI KAUS 291744Z VRB03KT 10SM -RA BKN009 22/20 A3015", ceiling: 900)
        #expect(OpsReport.conditionsTitle(rain) == "Low Clouds and Light Rain")
        let drizzle = Self.weather(metar: "LFPG 231530Z 21006KT 2500 -DZ BR BKN006 12/11 Q1012", ceiling: 600)
        #expect(OpsReport.conditionsTitle(drizzle) == "Low Clouds, Light Drizzle and Mist")
        let storm = Self.weather(metar: "KAUS 232153Z 22015G30KT 3SM +TSRA BKN030CB 24/20 A2990", ceiling: 3000)
        #expect(OpsReport.conditionsTitle(storm) == "Thunderstorms with Heavy Rain")
        #expect(OpsReport.conditionsTitle(Self.weather(metar: "KSFO 231456Z 29014KT 10SM FEW015 17/11 A3002")) == "Few Clouds")
    }

    @Test func periodLabels() {
        let utc = TimeZone(identifier: "UTC")!
        func label(_ p: ForecastPeriod) -> String { OpsReport.periodLabel(p, timeZone: utc, now: Self.now, clock: .h24) }
        #expect(label(Self.period(-2, 4)) == "Now until 19:42")
        #expect(label(Self.period(1, 4, change: .FM)) == "From 16:42 until 19:42")
        #expect(label(Self.period(1, 4, change: .TEMPO)) == "At times, 16:42 to 19:42")
        #expect(label(Self.period(-1, 4, change: .TEMPO)) == "At times, now to 19:42")
        #expect(label(Self.period(5, 12, change: .PROB, prob: 40)) == "40% chance, 20:42 to Sat 03:42")
        #expect(label(Self.period(2, 4, change: .BECMG)) == "Changing from 17:42")
    }

    @Test func trendComparesTheLastTwoHoursWithEarlier() {
        let hour = Self.now.addingTimeInterval(-Self.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600))
        func b(_ h: Double, on: Int, late: Int) -> HourBucket {
            HourBucket(hour: hour.addingTimeInterval(h * 3600), onTime: on, late15: late, late45: 0, canceled: 0, diverted: 0)
        }
        let worse = OpsReport.trend([b(-4, on: 8, late: 2), b(-3, on: 8, late: 2), b(-1, on: 3, late: 7), b(0, on: 2, late: 6),
                                     b(2, on: 9, late: 0)], now: Self.now)
        #expect(worse?.direction == .worse)
        #expect(OpsReport.trendLine(worse!) == "Getting worse: 72% late in the last two hours, against 20% earlier today.")
        let better = OpsReport.trend([b(-4, on: 2, late: 8), b(-1, on: 8, late: 2)], now: Self.now)
        #expect(better?.direction == .better)
        #expect(OpsReport.trend([b(-4, on: 1, late: 1), b(-1, on: 8, late: 2)], now: Self.now) == nil)
    }

    // MARK: The report on the fakes

    private func report(_ code: String) async -> (OpsReport, AirportStore) {
        let store = AirportStore(code: code, airports: FakeAirportService(now: Self.now))
        await store.load()
        let tz = store.airport?.timeZone ?? .current
        let r = OpsReport(code: store.airport?.iata ?? code, stats: store.stats, weather: store.weather,
                          timeZone: tz, now: Self.now)
        return (r, store)
    }

    @Test func austinIsLateWithFineWeatherAndStormsAhead() async {
        let (r, _) = await report("KAUS")
        guard case .notWeather = r.cause else { Issue.record("cause \(String(describing: r.cause))"); return }
        #expect(r.summary == "Flights at AUS are running late, departures by 39m and arrivals by 49m on average. "
            + "The weather is fine, so the cause lies elsewhere. Expect thunderstorms from 16:00.")
        #expect(r.conditionsTitle == "Mostly Cloudy")
        #expect(r.conditionsText == "Wind from the south at 22 km/h, gusting to 41 km/h. Visibility 10 km or more. "
            + "Few clouds at 4,000 ft, broken clouds at 25,000 ft. Temperature 24°C, dew point 17°C. Pressure 1015 hPa.")
        #expect(r.periods.map(\.label) == ["Now until 15:00", "From 15:00 until 22:00", "At times, 16:00 to 20:00",
                                           "From 22:00 until Sat 07:00"])
        #expect(r.periods[2].impact.level == .severe)
        #expect(r.departures?.trend != nil)
    }

    @Test func parisIsLateBecauseOfTheWeather() async {
        let (r, store) = await report("LFPG")
        guard case .weather = r.cause else { Issue.record("cause \(String(describing: r.cause))"); return }
        #expect(r.summary == "Flights at CDG are running late, departures by 31m and arrivals by 49m on average. "
            + "Low clouds and poor visibility are the likely cause, slowing arrivals.")
        #expect(r.conditionsTitle == "Low Clouds, Light Drizzle and Mist")
        #expect(r.periods.count == 5)
        // The TEMPO overlay follows the base period that starts with it.
        #expect(r.periods.prefix(2).map(\.label) == ["Now until 20:00", "At times, now to 18:00"])
        #expect(r.periods.contains { $0.label.hasPrefix("40% chance") && $0.impact.level == .severe })
        #expect(store.weather?.tafIssuedAt != nil)
    }

    @Test func sanFranciscoIsNormal() async {
        let (r, _) = await report("KSFO")
        #expect(r.cause == .normal)
        #expect(r.summary == "Flights at SFO are running close to time and the weather is fine.")
    }

    @Test func summaryWhenWeatherIsPoorButFlightsAreOnTime() {
        let storm = Self.weather(metar: "KAUS 232153Z 22015G30KT 3SM +TSRA BKN030CB 24/20 A2990", ceiling: 3000, vis: 3,
                                 wind: 15, gust: 30)
        let r = OpsReport(code: "AUS", stats: (Self.stats(.normal), Self.stats(.normal)), weather: storm,
                          timeZone: TimeZone(identifier: "UTC")!, now: Self.now)
        #expect(r.summary == "Flights at AUS are close to time for now, but thunderstorms could hold up departures and arrivals.")
        let fog = Self.weather(metar: "LFPG 240600Z 00000KT 2000 FG BKN008 08/08 Q1021", ceiling: 800, vis: 1.2)
        let singular = OpsReport(code: "CDG", stats: (Self.stats(.major), Self.stats(.normal)), weather: fog,
                                 timeZone: TimeZone(identifier: "UTC")!, now: Self.now)
        #expect(singular.summary == "Flights at CDG are running late, departures by 32m on average. "
            + "Low clouds and fog are the likely cause, slowing arrivals.")
    }

    @Test func verdictCopy() {
        let fog = WeatherImpact.of(ceilingFt: 800, visibilitySm: 1.5, windKt: 4, gustKt: nil, wx: "FG")
        #expect(OperationsReportView.verdictTitle(fog) == "Weather Is Slowing Flights")
        #expect(OperationsReportView.verdictText(fog, cause: .weather(fog))
            == "Low clouds and fog: arrivals likely slowed. It matches the delays on the boards, so they are likely weather related.")
        let fine = WeatherImpact.of(ceilingFt: nil, visibilitySm: 10, windKt: 4, gustKt: nil, wx: "")
        #expect(OperationsReportView.verdictTitle(fine) == "Weather Is Not a Factor")
        #expect(OperationsReportView.verdictText(fine, cause: .normal) == "Nothing in the latest report should slow flights.")
    }

    @Test func noEmDashAnywhereInTheCopy() async {
        for code in ["KAUS", "LFPG", "KSFO"] {
            let (r, _) = await report(code)
            let all = [r.summary, r.conditionsTitle ?? "", r.conditionsText ?? ""] + r.periods.flatMap { [$0.label, $0.text] }
            #expect(all.allSatisfy { !$0.contains("\u{2014}") }, "\(code)")
        }
    }
}
