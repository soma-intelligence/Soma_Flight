import Foundation
import Testing
@testable import FlightKit

/// Task 16: Good to Know, the detailed timetable, the airline card, the user's history on the route,
/// the updates card and the report link.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct DetailPart2Tests {
    static let sfo = DetailPart1Tests.sfo
    static let cdg = DetailPart1Tests.cdg
    static let hnd = DetailPart1Tests.hnd
    static let lhr = Airport(id: "EGLL", iata: "LHR", name: "London Heathrow", city: "London",
                             country: "GB", lat: 51.47, lon: -0.4543, tz: "Europe/London")
    static let del = Airport(id: "VIDP", iata: "DEL", name: "Indira Gandhi International", city: "Delhi",
                             country: "IN", lat: 28.5665, lon: 77.1031, tz: "Asia/Kolkata")
    static let oak = DetailPart1Tests.oak

    // MARK: Time zone change

    @Test func timeZoneChangePositive() {
        // SFO 15:20 Friday to CDG 10:15 Saturday 31 October 2026: Paris is on CET, San Francisco still on PDT.
        let change = DetailFacts.timeZoneChange(origin: Self.sfo, destination: Self.cdg, arrival: date("2026-10-31T09:15:00Z"))
        #expect(change?.title == "+8 hours time zone change")
        #expect(change?.text == "10:15 arrival is 02:15 San Francisco time")
    }

    /// Review Focus 2: flying west across the date line, or west from Tokyo, the sign is negative.
    @Test func timeZoneChangeNegative() {
        // HND 00:30 Saturday to SFO 16:30 Friday: Tokyo +9, San Francisco -7.
        let west = DetailFacts.timeZoneChange(origin: Self.hnd, destination: Self.sfo, arrival: date("2026-10-30T23:30:00Z"))
        #expect(west?.title == "-16 hours time zone change")
        #expect(west?.text == "16:30 arrival is 08:30 Tokyo time")
        // HND to LHR in November: Tokyo +9, London on GMT.
        let london = DetailFacts.timeZoneChange(origin: Self.hnd, destination: Self.lhr, arrival: date("2026-11-20T15:00:00Z"))
        #expect(london?.title == "-9 hours time zone change")
        #expect(london?.text == "15:00 arrival is 00:00 Tokyo time")
        // One hour is singular.
        let paris = DetailFacts.timeZoneChange(origin: Self.cdg, destination: Self.lhr, arrival: date("2026-11-20T15:00:00Z"))
        #expect(paris?.title == "-1 hour time zone change")
    }

    @Test func timeZoneChangeHalfHour() {
        // LHR to DEL in November: GMT to +5:30.
        let change = DetailFacts.timeZoneChange(origin: Self.lhr, destination: Self.del, arrival: date("2026-11-20T15:00:00Z"))
        #expect(change?.title == "+5h 30m time zone change")
        #expect(change?.text == "20:30 arrival is 15:00 London time")
        let back = DetailFacts.timeZoneChange(origin: Self.del, destination: Self.lhr, arrival: date("2026-11-20T15:00:00Z"))
        #expect(back?.title == "-5h 30m time zone change")
    }

    @Test func timeZoneChangeNilSameOffset() {
        #expect(DetailFacts.timeZoneChange(origin: Self.sfo, destination: Self.oak, arrival: date("2026-10-31T09:15:00Z")) == nil)
        // Different zones, same offset on the arrival day (both on summer time).
        let lis = Airport(id: "LPPT", iata: "LIS", name: "Lisbon", city: "Lisbon", country: "PT", lat: 38.77, lon: -9.13, tz: "Europe/Lisbon")
        #expect(DetailFacts.timeZoneChange(origin: Self.lhr, destination: lis, arrival: date("2026-07-01T12:00:00Z")) == nil)
    }

    // MARK: Timetable

    /// UA 990 with every gate and runway time known: left 7 minutes late, landed 20 minutes late.
    static var full: Flight {
        var f = DetailPart1Tests.ua990
        f.scheduledOff = date("2026-10-30T22:53:00Z")
        f.scheduledOn = date("2026-10-31T09:00:00Z")
        f.actualOut = date("2026-10-30T22:27:00Z")
        f.actualOff = date("2026-10-30T22:45:00Z")
        f.actualOn = date("2026-10-31T09:20:00Z")
        f.estimatedIn = date("2026-10-31T09:35:00Z")
        f.status = .enRoute
        return f
    }

    @Test func timetableRowsFullAndSparse() {
        let rows = Timetable.rows(Self.full, originTz: Self.sfo.timeZone, destinationTz: Self.cdg.timeZone)
        #expect(rows.map(\.title) == ["Gate Departure", "Taxi", "Take Off", "Land", "Taxi", "Gate Arrival", "Air Time", "Total Time"])
        #expect(rows.map(\.section) == [.depart, .depart, .depart, .arrive, .arrive, .arrive, .totals, .totals])
        #expect(rows.map(\.scheduled) == ["15:20", "33m", "15:53", "10:00", "15m", "10:15", "10h 07m", "10h 55m"])
        #expect(rows.map(\.other) == ["15:27", "18m", "15:45", "10:20", "15m", "10:35", "10h 35m", "11h 08m"])
        #expect(rows.map(\.otherLabel) == ["Actual", "Actual", "Actual", "Actual", "Estimated", "Estimated", "Actual", "Estimated"])
        #expect(Timetable.subtitle == "Scheduled, estimated and actual times")

        var sparse = Flight(providerId: "p", ident: "XX1", originIcao: "KSFO", destinationIcao: "LFPG")
        sparse.status = .scheduled
        let empty = Timetable.rows(sparse, originTz: Self.sfo.timeZone, destinationTz: Self.cdg.timeZone)
        #expect(empty.count == 8)
        #expect(empty.allSatisfy { $0.scheduled == "--" && $0.other == "--" && $0.level == nil })
        #expect(empty.allSatisfy { $0.otherLabel == "Estimated" })
    }

    @Test func timetableColours() {
        let rows = Timetable.rows(Self.full, originTz: Self.sfo.timeZone, destinationTz: Self.cdg.timeZone)
        // Gate departure 7m late: on time; take off 8m early: on time; land 20m late: late; gate 20m late.
        #expect(rows[0].level == .onTime)
        #expect(rows[2].level == .onTime)
        #expect(rows[3].level == .late)
        #expect(rows[5].level == .late)
        // Spans carry no colour.
        #expect([rows[1], rows[4], rows[6], rows[7]].allSatisfy { $0.level == nil })
        var late = Self.full
        late.actualIn = date("2026-10-31T10:05:00Z")
        let gate = Timetable.rows(late, originTz: Self.sfo.timeZone, destinationTz: Self.cdg.timeZone)[5]
        #expect(gate.level == .veryLate)
        #expect(gate.otherLabel == "Actual")
        #expect(gate.other == "11:05")
    }

    // MARK: Route history

    static func past(_ day: String, _ ident: String, from: String, to: String, minutes: Int? = 640,
                     status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(date: date(day), ident: ident, originIcao: from, destinationIcao: to, airline: "Air France",
                   aircraftType: "B77W", registration: "F-GZND", distanceKm: 8965, blockMinutes: minutes, status: status)
    }

    @Test func routeHistoryBothDirections() {
        let flights = [
            Self.past("2024-12-16T18:00:00Z", "AF83", from: "KSFO", to: "LFPG", minutes: 622),
            Self.past("2024-10-26T18:00:00Z", "AF84", from: "LFPG", to: "KSFO", minutes: 617),
            Self.past("2023-05-01T18:00:00Z", "AF83", from: "KSFO", to: "LFPG", minutes: nil),
            Self.past("2025-01-01T18:00:00Z", "AF83", from: "KSFO", to: "LFPG", status: .canceled),
            Self.past("2025-02-01T18:00:00Z", "UA1", from: "KSFO", to: "KJFK"),
        ]
        let h = RouteHistory.compute(flights, origin: "KSFO", destination: "LFPG")
        #expect(h?.flights == 3)
        #expect(h?.distanceKm == 3 * 8965)
        #expect(h?.minutes == 622 + 617)
        #expect(h?.recent.map(\.ident) == ["AF83", "AF84"])
        #expect(h?.recent.first?.date == date("2024-12-16T18:00:00Z"))
        // The other direction counts the same flights.
        #expect(RouteHistory.compute(flights, origin: "LFPG", destination: "KSFO") == h)
        #expect(RouteHistory.subtitle(from: "SFO", to: "CDG") == "SFO → CDG")
        #expect(RouteHistory.title == "Your history on this route")
        #expect(RouteHistory.detail(flights[0]) == "F-GZND · Boeing 777-300ER")
    }

    @Test func routeHistoryNilWhenEmpty() {
        #expect(RouteHistory.compute([], origin: "KSFO", destination: "LFPG") == nil)
        let canceled = [Self.past("2025-01-01T18:00:00Z", "AF83", from: "KSFO", to: "LFPG", status: .canceled)]
        #expect(RouteHistory.compute(canceled, origin: "KSFO", destination: "LFPG") == nil)
    }

    // MARK: Good to Know

    static func stats(_ severity: Severity, avg: Double = 32) -> DelayStats {
        DelayStats(total: 40, onTime: 20, delayed15: 18, canceled: 2, avgDelayMinutes: avg, perHour: [],
                   worstRoutes: [], worstAirlines: [], severity: severity)
    }

    @Test func disruptionRowOnlyWhenModerateOrMajor() {
        #expect(DetailFacts.disruption(code: "SFO", stats: Self.stats(.normal), departures: true) == nil)
        #expect(DetailFacts.disruption(code: "SFO", stats: nil, departures: true) == nil)
        let moderate = DetailFacts.disruption(code: "SFO", stats: Self.stats(.moderate), departures: true)
        #expect(moderate?.title == "Delays at SFO")
        #expect(moderate?.text == "Departures average 32m late right now. Tap for the airport's details.")
        let major = DetailFacts.disruption(code: "CDG", stats: Self.stats(.major, avg: 71.6), departures: false)
        #expect(major?.title == "Delays at CDG")
        #expect(major?.text == "Arrivals average 1h 12m late right now. Tap for the airport's details.")
    }

    @Test func weatherLine() {
        let w = Weather(metarRaw: "KSFO 232356Z 29014KT 10SM SCT015 18/11 A3002", tafRaw: nil, tempC: 17.6, windDirDeg: nil,
                        windKt: nil, gustKt: nil, visibilitySm: nil, ceilingFt: nil, category: .VFR, observedAt: .now, forecast: [])
        #expect(DetailFacts.weatherText(w) == "18°C and scattered clouds")
        var noTemp = w
        noTemp.tempC = nil
        #expect(DetailFacts.weatherText(noTemp) == "Scattered clouds")
    }

    // MARK: Updates and report

    @Test func updatesCount() {
        #expect(DetailFacts.updatesLine(3) == "3 updates for this flight")
        #expect(DetailFacts.updatesLine(1) == "1 update for this flight")
    }

    @Test func reportURLEncodes() {
        let url = DetailFacts.reportURL(DetailPart1Tests.ua990, origin: Self.sfo.timeZone)
        #expect(url.absoluteString == "mailto:support@somalabs.me?subject=Soma%20Flight%20data%20issue%3A%20UA990%202026-10-30")
        #expect(DetailFacts.reportLabel == "Report a Data Issue")
        var bare = DetailPart1Tests.ua990
        bare.scheduledOut = nil
        #expect(DetailFacts.reportURL(bare).absoluteString == "mailto:support@somalabs.me?subject=Soma%20Flight%20data%20issue%3A%20UA990")
    }

    // MARK: Airline card

    @Test func airlineCardLinks() {
        let ual = Airline(id: "UAL", iata: "UA", name: "United", callsign: "UNITED", alliance: .starAlliance,
                          colorPrimary: "#005DAA", phone: "+1 (800) 864-8331", website: URL(string: "https://www.united.com"))
        let buttons = AirlineCard.buttons(ual)
        #expect(buttons.map(\.title) == ["PHONE", "WEBSITE"])
        #expect(buttons.first?.url.absoluteString == "tel:+18008648331")
        #expect(AirlineCard.codes(ual).map(\.value) == ["UNITED", "UAL", "UA"])
        let bare = Airline(id: "ZZZ", name: "Nowhere Air", colorPrimary: "#000000")
        #expect(AirlineCard.buttons(bare).isEmpty)
        #expect(AirlineCard.codes(bare).map(\.value) == ["--", "ZZZ", "--"])
        // A vanity number would dial something else: no button.
        #expect(AirlineCard.phoneURL("1-800-UNITED") == nil)
        #expect(AirlineCard.phoneURL("--") == nil)
    }

    /// Review round 1, Important 1: the bundled data holds bare handles; the buttons open the real profiles.
    @Test func socialButtonsFromRealHandles() throws {
        let ref = ReferenceData.bundled()
        let alaska = try #require(ref.airline("ASA"))
        let links = AirlineCard.buttons(alaska)
        #expect(links.map(\.title) == ["WEBSITE", "X", "FACEBOOK"])
        #expect(links[1].url.absoluteString == "https://x.com/AlaskaAir")
        #expect(links[2].url.absoluteString == "https://www.facebook.com/alaskaairlines")
        let nz = try #require(ref.airline("ANZ"))
        #expect(AirlineCard.buttons(nz).map(\.url.absoluteString)
                == ["https://www.airnewzealand.com", "https://x.com/FlyAirNZ", "https://www.facebook.com/AirNewZealand"])
        // Cathay has Facebook only.
        let cathay = try #require(ref.airline("CPA"))
        #expect(AirlineCard.buttons(cathay).map(\.title) == ["WEBSITE", "FACEBOOK"])
        // Every handle in the bundled data builds a link.
        for a in ref.airlines {
            if a.x != nil { #expect(AirlineCard.buttons(a).contains { $0.title == "X" }, "\(a.id) X") }
            if a.facebook != nil { #expect(AirlineCard.buttons(a).contains { $0.title == "FACEBOOK" }, "\(a.id) Facebook") }
            for link in AirlineCard.buttons(a) where link.title != "PHONE" {
                #expect(link.url.scheme == "https")
                #expect(link.url.query == nil && link.url.fragment == nil)
            }
        }
    }

    /// Review round 1, Important 2: only web pages, never another scheme; tracking bits dropped.
    @Test func linksAreSafe() {
        #expect(SafeLink.web(URL(string: "https://www.united.com/en/us?utm_source=x#top"))?.absoluteString
                == "https://www.united.com/en/us")
        #expect(SafeLink.web(URL(string: "http://www.airwis.com"))?.absoluteString == "http://www.airwis.com")
        #expect(SafeLink.web(URL(string: "HTTPS://user:pw@example.com/a"))?.absoluteString == "https://example.com/a")
        #expect(SafeLink.web(URL(string: "javascript:alert(1)")) == nil)
        #expect(SafeLink.web(URL(string: "tel:123")) == nil)
        #expect(SafeLink.web(URL(string: "file:///etc/passwd")) == nil)
        #expect(SafeLink.web(URL(string: "www.united.com")) == nil)
        #expect(SafeLink.handle(URL(string: "@AlaskaAir")) == "AlaskaAir")
        #expect(SafeLink.handle(URL(string: "https://x.com/AlaskaAir?s=20")) == "AlaskaAir")
        #expect(SafeLink.handle(URL(string: "air.baltic_1")) == "air.baltic_1")
        #expect(SafeLink.handle(URL(string: "bad%20handle")) == nil)
        #expect(SafeLink.handle(URL(string: "...")) == nil)
        #expect(SafeLink.handle(nil) == nil)
        let x = Airline(id: "QQQ", name: "Q", colorPrimary: "#000000", website: URL(string: "ftp://q.example"),
                        x: URL(string: "javascript:alert(1)"))
        #expect(AirlineCard.buttons(x).isEmpty)
    }

    @Test func routeHistoryExcludesTheFlightOnScreen() {
        let f = DetailPart1Tests.ua990
        let flights = [
            PastFlight(date: f.scheduledOut!, ident: "UA990", originIcao: "KSFO", destinationIcao: "LFPG", distanceKm: 8965,
                       blockMinutes: 655),
            Self.past("2024-12-16T18:00:00Z", "AF83", from: "KSFO", to: "LFPG", minutes: 622),
        ]
        let h = RouteHistory.compute(flights, origin: "KSFO", destination: "LFPG", excluding: f)
        #expect(h?.flights == 1)
        #expect(h?.recent.map(\.ident) == ["AF83"])
        #expect(RouteHistory.compute(flights, origin: "KSFO", destination: "LFPG")?.flights == 2)
        #expect(RouteHistory.compute([flights[0]], origin: "KSFO", destination: "LFPG", excluding: f) == nil)
    }

    @Test func cachedHistoryFetchesOnceWithinTTL() async throws {
        let base = FakeHistoryService()
        let clock = TestClock(date("2026-10-30T00:00:00Z"))
        let cached = CachedHistoryService(base, ttl: .seconds(600), now: { clock.now })
        let first = try await cached.pastFlights()
        await base.setNextError(.offline)
        // Within the window the copy answers; the failing base is not asked.
        #expect(try await cached.pastFlights() == first)
        clock.now = clock.now.addingTimeInterval(601)
        await #expect(throws: APIError.self) { try await cached.pastFlights() }
        #expect(try await cached.pastFlights() == first)
    }

    // MARK: Store

    @Test func extrasFailureHidesOnlyThatRow() async {
        let now = PreviewData.now
        let flights = FakeFlightService(now: now)
        let airports = FakeAirportService(now: now)
        let flight = PreviewData.enRoute
        let store = FlightDetailStore(id: flight.id, flights: flights, airports: airports, history: FakeHistoryService())
        await store.load()
        await store.loadExtras()
        #expect(store.originWeather != nil)
        #expect(store.destinationWeather != nil)
        #expect(store.originStats != nil)
        #expect(store.routeHistory != nil)

        // One airport call fails (they run at once, so which one is not fixed): only that row goes.
        let again = FlightDetailStore(id: flight.id, flights: flights, airports: airports, history: FakeHistoryService())
        await again.load()
        await airports.setNextError(.providerUnavailable)
        await again.loadExtras()
        let rows: [Bool] = [again.originStats != nil, again.destinationStats != nil,
                            again.originWeather != nil, again.destinationWeather != nil]
        #expect(rows.filter { !$0 }.count == 1)
        #expect(again.routeHistory != nil)
        #expect(again.error == nil)

        // History fails: no history card, the rest stays.
        let history = FakeHistoryService()
        await history.setNextError(.offline)
        let third = FlightDetailStore(id: flight.id, flights: flights, airports: airports, history: history)
        await third.load()
        await third.loadExtras()
        #expect(third.routeHistory == nil)
        #expect(third.originWeather != nil)
        #expect(third.error == nil)
    }
}
