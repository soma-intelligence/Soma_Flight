import Testing
import Foundation
@testable import FlightKit

/// A history that answers with fixed flights.
private struct ListHistory: HistoryService {
    var past: [PastFlight]
    func pastFlights() async throws(APIError) -> [PastFlight] { past }
    func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
}

/// Facts that are never there, as on a live build today (the `aircraft` table is empty).
private struct NoFacts: AircraftFactsService {
    func facts(_ registrations: [String]) async -> [AircraftFact] { [] }
}

private let asOf = Date(timeIntervalSince1970: 1_793_232_000) // 2026-10-29T00:00:00Z

private func flight(_ day: Int, airline: String? = "United", type: String? = "B77W", reg: String? = nil,
                    delay: Int = 0, status: PastFlightStatus = .completed) -> PastFlight {
    PastFlight(date: Date(timeIntervalSince1970: 1_767_268_800 + Double(day) * 86_400), // 2026-01-01T12:00Z + days
               ident: "UA\(900 + day)", originIcao: "KSFO", destinationIcao: "LFPG", airline: airline,
               aircraftType: type, registration: reg, distanceKm: 8_950, blockMinutes: 640, delayMinutes: delay,
               status: status, originTz: "America/Los_Angeles")
}

@MainActor private func store(_ flights: [PastFlight], facts: (any AircraftFactsService)? = nil) async -> PassportStore {
    let s = PassportStore(history: ListHistory(past: flights), facts: facts, asOf: asOf)
    await s.load()
    return s
}

@Suite @MainActor struct PassportDetailStoreTests {
    @Test func detailMapsNamesToIcao() async {
        let s = await store([flight(1, airline: "United"), flight(2, airline: "UAL"), flight(3, airline: "UA"),
                             flight(4, airline: "Zed Air Charter")])
        #expect(s.detail.airlinesByFlights.map(\.key) == ["UAL", "Zed Air Charter"])
        #expect(s.detail.airlinesByFlights.first?.flights == 3)
        // The tab's count agrees: three spellings of one airline are one airline.
        #expect(s.stats.airlines == 2)
        // Countries come from the airports when the flight does not carry them.
        #expect(s.detail.international == 4)
        #expect(Set(s.detail.countries.map(\.iso2)) == ["US", "FR"])
    }

    @Test func yearChangeRecomputes() async {
        let s = PassportStore(history: FakeHistoryService(), facts: FakeAircraftFactsService(), asOf: asOf)
        await s.load()
        let allTime = (s.stats.flights, s.detail.flights, s.aircraft.typesByFlights.map(\.flights).reduce(0, +))
        #expect(allTime.0 == allTime.1)
        s.year = 2025
        #expect(s.stats.flights == 12)
        #expect(s.detail.flights == 12)
        #expect(s.aircraft.typesByFlights.map(\.flights).reduce(0, +) <= 12)
        #expect(s.detail.flights < allTime.1)
        s.year = nil
        #expect(s.detail.flights == allTime.1)
    }

    @Test func mostFlownAirlineForLivery() async {
        let s = await store([flight(1, airline: "Air France"), flight(2, airline: "United"), flight(3, airline: "UA"),
                             flight(4, airline: "AFR", type: "A320"), flight(5, airline: "AFR", type: "A320", status: .canceled)])
        #expect(s.aircraft.mostFlown?.icaoType == "B77W")
        #expect(s.aircraft.mostFlown?.flights == 3)
        #expect(s.mostFlownType?.id == "B77W")
        #expect(s.mostFlownAirline?.id == "UAL")
        // A tie goes to the first code alphabetically.
        let tie = await store([flight(1, airline: "United"), flight(2, airline: "Air France")])
        #expect(tie.mostFlownAirline?.id == "AFR")
    }

    @Test func liveFactsEmptyHidesAges() async {
        let flights = [flight(1, reg: "N2135U"), flight(2, type: "B39M", reg: "N47280")]
        let live = await store(flights, facts: NoFacts())
        #expect(!live.aircraft.hasAges)
        #expect(live.aircraft.newest == nil && live.aircraft.oldest == nil)
        #expect(live.aircraft.decades.isEmpty)
        #expect(live.aircraft.totalTypes == 2) // everything else stays
        let none = await store(flights)
        #expect(!none.aircraft.hasAges)

        let fake = await store(flights, facts: FakeAircraftFactsService())
        #expect(fake.aircraft.hasAges)
        #expect(fake.aircraft.newest?.registration == "N47280") // delivered 2026-03-12
        #expect(fake.aircraft.newest?.ageMonths == 7)
        #expect(fake.aircraft.oldest?.registration == "N2135U")
    }

    @Test func emptyHistoryCards() async {
        let s = await store([], facts: FakeAircraftFactsService())
        #expect(s.flights.isEmpty)
        #expect(s.stats == .empty)
        #expect(s.detail.flights == 0)
        #expect(s.aircraft.mostFlown == nil)
        #expect(s.mostFlownType == nil && s.mostFlownAirline == nil)
        #expect(s.mostDelayed.isEmpty)
    }

    // MARK: Delay page

    @Test func delayFiguresFromCore() async {
        let s = await store([flight(1, delay: 10), flight(2, delay: 15), flight(3, delay: 30),
                             flight(4, delay: 90, status: .canceled)])
        #expect(s.stats.delayedFlights == 2)
        #expect(s.stats.avgDelayedMinutes == 23) // 22.5 rounds half up
        #expect(s.stats.delayLost == .seconds(55 * 60))
        #expect(DelayFacts.share(delayed: s.stats.delayedFlights, of: s.stats.flights) == "67%")
        #expect(DelayFacts.shareCaption(delayed: 2, of: 3) == "2 of 3 flights")
        #expect(DelayFacts.share(delayed: 0, of: 0) == "0%")
        #expect(TravelFacts.delayedAverageLine(23, delayed: 2) == "Delayed flights left 23m late on average")
        #expect(TravelFacts.delayedAverageLine(0, delayed: 0) == "None of your flights left 15 minutes late or more")
    }

    @Test func mostDelayedTopTen() async {
        var flights = (1...12).map { flight($0, delay: $0 * 10) }
        flights.append(flight(20, delay: 0))
        flights.append(flight(21, delay: 500, status: .canceled))
        flights.append(flight(22, delay: 120)) // ties day 12: the newer first
        let s = await store(flights)
        let list = s.mostDelayed
        #expect(list.count == 10)
        #expect(list.map(\.delayMinutes) == [120, 120, 110, 100, 90, 80, 70, 60, 50, 40])
        #expect(list[0].ident == "UA922")
        #expect(!list.contains { $0.status == .canceled || $0.delayMinutes == 0 })
        s.year = 2025
        #expect(s.mostDelayed.isEmpty)
    }

    // MARK: Facts and pages

    @Test func factsDecodeTableRows() throws {
        let json = #"[{"registration":"N47280","delivered_on":"2026-03-12","name":null},{"registration":"F-X","delivered_on":null,"name":"Ville"}]"#
        let facts = try JSONDecoder().decode([AircraftFact].self, from: Data(json.utf8))
        #expect(facts[0].deliveredOn == Date(timeIntervalSince1970: 1_773_273_600))
        #expect(facts[1].deliveredOn == nil && facts[1].name == "Ville")
        #expect(facts[0].coreFact.deliveredAt == 1_773_273_600)
    }

    @Test func fakeFactsCoverTheFakeHistory() async {
        let regs = Set(FakeSeed.load("past_flights", as: [PastFlight].self).compactMap(\.registration))
        let facts = await FakeAircraftFactsService().facts(Array(regs))
        #expect(Set(facts.map(\.registration)) == regs)
        let years = facts.compactMap(\.deliveredOn).map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        #expect(years.min() == 1994 && years.max() == 2026)
    }

    @Test func fullPageLaunchArgument() async throws {
        let home = HomeModel(env: try await .fake())
        let args = try #require(UserDefaults(suiteName: "PassportDetailStoreTests.fullPage"))
        defer { args.removePersistentDomain(forName: "PassportDetailStoreTests.fullPage") }
        args.set("delays", forKey: "fullPage")
        home.applyLaunchArguments(args)
        #expect(home.tab == .passport)
        #expect(home.fullPage == .delays)
        #expect(FullPage.allCases.map(\.title) == ["Soma Flight Passport", "Delay stats", "Aircraft stats"])
    }
}
