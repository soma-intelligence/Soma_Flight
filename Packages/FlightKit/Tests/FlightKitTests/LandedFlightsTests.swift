import Foundation
import Testing
import FlightImportKit
@testable import FlightKit

/// A followed flight that is over leaves My Flights an hour after it reached the gate and shows in
/// Passport straight away, until the server's archived row replaces it.
@MainActor @Suite struct LandedFlightsTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func flight(_ status: FlightStatus, arrivedAgo minutes: Double?, ident: String = "AF84") -> Flight {
        let inn = minutes.map { now.addingTimeInterval(-$0 * 60) }
        let out = inn.map { $0.addingTimeInterval(-11 * 3600) }
        let flown = status != .canceled && status != .scheduled
        return Flight(providerId: "p-\(ident)", ident: ident, operator: "AFR", originIcao: "LFPG", destinationIcao: "KSFO",
                      scheduledOut: out, scheduledIn: inn.map { $0.addingTimeInterval(-20 * 60) },
                      actualOut: flown ? out?.addingTimeInterval(10 * 60) : nil,
                      actualOff: flown ? out?.addingTimeInterval(25 * 60) : nil,
                      actualOn: flown ? inn?.addingTimeInterval(-8 * 60) : nil,
                      actualIn: flown ? inn : nil, aircraftType: "A359", registration: "F-HTYM",
                      status: status, updatedAt: now)
    }

    actor History: HistoryService {
        let rows: [PastFlight]
        init(_ rows: [PastFlight]) { self.rows = rows }
        func pastFlights() async throws(APIError) -> [PastFlight] { rows }
        func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
        func delete(_ id: PastFlight.ID) async throws(APIError) {}
    }

    @Test func overAnHourAfterTheGate() {
        #expect(!LandedFlights.isOver(flight(.arrived, arrivedAgo: 30), now: now))
        #expect(LandedFlights.isOver(flight(.arrived, arrivedAgo: 61), now: now))
        #expect(LandedFlights.isOver(flight(.landed, arrivedAgo: 90), now: now))
        #expect(LandedFlights.isOver(flight(.diverted, arrivedAgo: 120), now: now))
        // Canceled: an hour after it was due in.
        #expect(LandedFlights.isOver(flight(.canceled, arrivedAgo: 90), now: now))
        #expect(!LandedFlights.isOver(flight(.scheduled, arrivedAgo: 600), now: now))
        #expect(!LandedFlights.isOver(flight(.arrived, arrivedAgo: nil), now: now))
    }

    @Test func historyRowCarriesTheFlight() {
        let row = LandedFlights.pastFlight(flight(.arrived, arrivedAgo: 90), airport: PreviewData.airport)
        #expect(row.ident == "AF84")
        #expect(row.source == .archive)
        #expect(!row.isEditable)
        #expect(row.status == .completed)
        #expect((8900...9000).contains(row.distanceKm))
        #expect(row.originTz == "Europe/Paris")
        #expect(row.blockMinutes == 11 * 60 - 10)
        #expect(row.arrivalDelayMinutes == 20)
        #expect(row.departureDelayMinutes == 10)
        #expect(row.delayMinutes == 20)

        let canceled = LandedFlights.pastFlight(flight(.canceled, arrivedAgo: 90), airport: PreviewData.airport)
        #expect(canceled.status == .canceled)
        #expect(canceled.blockMinutes == nil)
        #expect(canceled.delayMinutes == 0)
        #expect(canceled.arrivalDelayMinutes == nil)
    }

    @Test func myFlightsLeavesOutWhatIsOver() {
        let over = flight(.arrived, arrivedAgo: 90, ident: "AF84")
        let fresh = flight(.arrived, arrivedAgo: 20, ident: "AF66")
        let titled = MyFlightsView.groups(live: [], upcoming: [over, fresh], planned: [], lookup: PreviewData.airport,
                                          now: now)
        let ids = titled.flatMap(\.rows).map(\.id)
        #expect(ids == [fresh.id.uuidString])
        // Without a clock (the tests that pin the seed) nothing is left out.
        #expect(MyFlightsView.groups(live: [], upcoming: [over, fresh], planned: [], lookup: PreviewData.airport)
            .flatMap(\.rows).count == 2)
    }

    @Test func plannedFlightWhoseDayPassedIsLeftOut() {
        let old = UpcomingFlight(ident: "ZZ1", day: LocalDay(now.addingTimeInterval(-3 * 86_400), in: .current))
        let soon = UpcomingFlight(ident: "ZZ2", day: LocalDay(now.addingTimeInterval(5 * 86_400), in: .current))
        let rows = MyFlightsView.groups(live: [], upcoming: [], planned: [old, soon], lookup: PreviewData.airport,
                                        now: now).flatMap(\.rows)
        #expect(rows.map(\.id) == [soon.id])
    }

    @Test func passportShowsLandedUntilTheArchiveHasIt() async {
        let over = flight(.arrived, arrivedAgo: 90)
        let store = PassportStore(history: History([]), airports: PreviewData.airport)
        await store.load()
        store.showLanded([over, flight(.arrived, arrivedAgo: 10, ident: "AF66")], now: now)
        #expect(store.flights.map(\.ident) == ["AF84"])
        #expect(store.stats.flights == 1)

        // The server archived it (its own id, the number spaced, a departure a little apart): one row, the server's.
        var archived = LandedFlights.pastFlight(over, airport: PreviewData.airport)
        archived.id = UUID()
        archived.ident = "AF 84"
        archived.date = archived.date.addingTimeInterval(120)
        let later = PassportStore(history: History([archived]), airports: PreviewData.airport)
        await later.load()
        later.showLanded([over], now: now)
        #expect(later.flights.count == 1)
        #expect(later.flights.first?.id == archived.id)
    }
}
