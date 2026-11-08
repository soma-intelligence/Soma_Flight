import Foundation
import PDFKit
import Testing
@testable import FlightKit

/// Plan 27: past flights grouped into trips, one PDF per trip made on the device.
@Suite struct ExpenseTripTests {
    /// 2025-03-10 08:00 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_741_593_600)
    static func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    static func leg(_ from: String, _ to: String, day n: Double, ident: String = "AFR84", km: Int = 1_000,
                    block: Int? = 120, status: PastFlightStatus = .completed, reason: TripReason? = nil) -> PastFlight {
        PastFlight(date: day(n), ident: ident, originIcao: from, destinationIcao: to, distanceKm: km,
                   blockMinutes: block, status: status, reason: reason)
    }

    @Test func roundTripIsOneTrip() {
        let trips = ExpenseTrips.group([Self.leg("KSFO", "LFPG", day: 0), Self.leg("LFPG", "KSFO", day: 12)])
        #expect(trips.count == 1)
        #expect(trips[0].legs.map(\.originIcao) == ["KSFO", "LFPG"])
        #expect(trips[0].isRoundTrip)
        #expect(trips[0].distanceKm == 2_000)
    }

    @Test func multiCityIsOneTrip() {
        let trips = ExpenseTrips.group([
            Self.leg("LFPG", "KSFO", day: 15), Self.leg("KSFO", "KJFK", day: 0),
            Self.leg("KJFK", "EGLL", day: 4), Self.leg("EGLL", "LFPG", day: 8),
        ])
        #expect(trips.count == 1)
        #expect(trips[0].legs.map(\.destinationIcao) == ["KJFK", "EGLL", "LFPG", "KSFO"])
        #expect(trips[0].route == ["KSFO", "KJFK", "EGLL", "LFPG", "KSFO"])
    }

    @Test func farApartFlightsAreSeparateTrips() {
        let trips = ExpenseTrips.group([
            Self.leg("KSFO", "KSEA", day: 0), Self.leg("KSEA", "KSFO", day: 2),
            Self.leg("KSFO", "KAUS", day: 30), Self.leg("KAUS", "KDFW", day: 33),
        ])
        #expect(trips.count == 2)
        // Newest first.
        #expect(trips[0].legs.map(\.originIcao) == ["KSFO", "KAUS"])
        #expect(!trips[0].isRoundTrip)
        #expect(trips[1].isRoundTrip)
    }

    @Test func aReturnHomeEndsTheTrip() {
        // Back home on day 3, out again on day 5: two trips even though the gap is short.
        let trips = ExpenseTrips.group([
            Self.leg("KSFO", "KLAX", day: 0), Self.leg("KLAX", "KSFO", day: 3), Self.leg("KSFO", "KDEN", day: 5),
        ])
        #expect(trips.count == 2)
    }

    @Test func aLongStayBreaksTheTripUnlessItIsTheReturn() {
        // Eight days between legs: only the flight home may wait that long.
        let away = ExpenseTrips.group([Self.leg("KSFO", "KJFK", day: 0), Self.leg("KJFK", "KBOS", day: 8)])
        #expect(away.count == 2)
        // A return later than 21 days is a trip of its own.
        let late = ExpenseTrips.group([Self.leg("KSFO", "LFPG", day: 0), Self.leg("LFPG", "KSFO", day: 25)])
        #expect(late.count == 2)
    }

    @Test func theGapCountsFromTheLanding() {
        // Lands 2 h after leaving day 0; the next leg 5 days after the landing still joins.
        let trips = ExpenseTrips.group([Self.leg("KSFO", "KJFK", day: 0, block: 600),
                                        Self.leg("KJFK", "KBOS", day: 5.3)])
        #expect(trips.count == 1)
    }

    @Test func canceledFlightsAreLeftOut() {
        let trips = ExpenseTrips.group([Self.leg("KSFO", "LFPG", day: 0, status: .canceled)])
        #expect(trips.isEmpty)
    }

    @Test func businessFilterKeepsBusinessLegsOnly() {
        let flights = [Self.leg("KSFO", "LFPG", day: 0, reason: .business),
                       Self.leg("LFPG", "KSFO", day: 6, reason: .business),
                       Self.leg("KSFO", "KLAS", day: 40, reason: .personal),
                       Self.leg("KSFO", "KSEA", day: 60)]
        #expect(ExpenseTrips.group(flights).count == 3)
        let business = ExpenseTrips.group(flights, filter: .business)
        #expect(business.count == 1)
        #expect(business[0].legs.count == 2)
    }

    @Test func emptyHistoryHasNoTrips() {
        #expect(ExpenseTrips.group([]).isEmpty)
    }
}

@Suite struct ExpenseReportTests {
    static let paris = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", country: "FR",
                               lat: 49.0097, lon: 2.5479, tz: "Europe/Paris")
    static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco",
                             country: "US", lat: 37.6213, lon: -122.379, tz: "America/Los_Angeles")

    static func full() -> PastFlight {
        PastFlight(date: ExpenseTripTests.day(0), ident: "AFR83", originIcao: "KSFO", destinationIcao: "LFPG",
                   airline: "Air France", seat: "12A", distanceKm: 8_954, blockMinutes: 660, status: .completed,
                   originTz: "America/Los_Angeles", seatClass: .business, reason: .business, bookingCode: "ABC123",
                   notes: "Client visit", departureDelayMinutes: 25)
    }

    static func bare() -> PastFlight {
        PastFlight(date: ExpenseTripTests.day(6), ident: "AFR84", originIcao: "LFPG", destinationIcao: "KSFO",
                   distanceKm: 8_954)
    }

    static func report(_ legs: [PastFlight], traveller: String? = "Jane Doe", unit: DistanceUnit = .km,
                       notes: Bool = true) -> ExpenseReport {
        let trip = ExpenseTrips.group(legs)[0]
        return ExpenseReport(trip: trip, traveller: traveller, unit: unit,
                             airports: ["LFPG": paris, "KSFO": sfo], locale: Locale(identifier: "en_US"), includesNotes: notes)
    }

    static func text(_ data: Data) throws -> (pages: Int, text: String) {
        let doc = try #require(PDFDocument(data: data))
        return (doc.pageCount, doc.string ?? "")
    }

    @Test func pdfHoldsEveryField() throws {
        let (pages, text) = try Self.text(Self.report([Self.full(), Self.bare()]).pdf())
        #expect(pages == 1)
        for piece in ["Jane Doe", "AFR 83", "Air France", "San Francisco (SFO)", "Paris (CDG)", "12A", "Business",
                      "ABC123", "Client visit", "25 min late", "17,908 km", "Made with Soma Flight", "Page 1 of 1"] {
            #expect(text.contains(piece), "\(piece)")
        }
        // Local times at each end, the arrival from the block time.
        #expect(text.contains("01:00 PDT"))
        #expect(text.contains("20:00 GMT+1"))
    }

    @Test func notesStayOutUnlessIncluded() throws {
        let trip = ExpenseTrips.group([Self.full(), Self.bare()])[0]
        let plain = ExpenseReport(trip: trip, traveller: nil, unit: .km, airports: ["LFPG": Self.paris, "KSFO": Self.sfo],
                                  locale: Locale(identifier: "en_US"))
        #expect(!plain.includesNotes)
        let (_, text) = try Self.text(plain.pdf())
        #expect(!text.contains("Client visit"))
        #expect(!text.contains("Notes"))
        // The booking code stays: an expense claim needs it.
        #expect(text.contains("ABC123"))
        let (_, withNotes) = try Self.text(Self.report([Self.full(), Self.bare()], notes: true).pdf())
        #expect(withNotes.contains("Notes: Client visit"))
    }

    @Test func missingFieldsLeaveNoGaps() throws {
        let (_, text) = try Self.text(Self.report([Self.bare()], traveller: nil).pdf())
        #expect(text.contains("AFR 84"))
        #expect(!text.contains("Traveller"))
        #expect(!text.contains("Seat"))
        #expect(!text.contains("Booking code"))
        #expect(!text.contains("Arrival"))
        #expect(!text.contains("nil"))
        #expect(!text.contains("$"))
    }

    @Test func distanceFollowsTheUnit() throws {
        let (_, text) = try Self.text(Self.report([Self.full(), Self.bare()], unit: .mi).pdf())
        #expect(text.contains("11,128 mi"))
    }

    @Test func longTripsRunOntoMorePages() throws {
        var legs: [PastFlight] = []
        for i in 0..<30 {
            var f = Self.full()
            f.date = ExpenseTripTests.day(Double(i) * 0.5)
            f.originIcao = "X\(i)"
            f.destinationIcao = "X\(i + 1)"
            legs.append(f)
        }
        let trip = ExpenseTrips.group(legs)[0]
        #expect(trip.legs.count == 30)
        let report = ExpenseReport(trip: trip, traveller: "Jane Doe", unit: .km, airports: [:], locale: Locale(identifier: "en_US"))
        let (pages, text) = try Self.text(report.pdf())
        #expect(pages == report.layout().count)
        #expect(pages > 1)
        #expect(text.contains("Page 1 of \(pages)"))
        #expect(text.contains("Page \(pages) of \(pages)"))
    }

    @Test func fileNameCarriesTheFirstDay() {
        let r = Self.report([Self.full(), Self.bare()])
        #expect(r.fileName == "soma-flight-trip-2025-03-10.pdf")
    }

    @Test func titleNamesTheFirstDestination() {
        #expect(Self.report([Self.full(), Self.bare()]).title == "Trip to Paris")
    }

    @Test func copyHasNoEmDash() throws {
        let (_, text) = try Self.text(Self.report([Self.full(), Self.bare()]).pdf())
        #expect(!text.contains("\u{2014}"))
    }

    @Test func shareFileIsSweptWithTheHistoryExports() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "expense-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = try ExpenseReportFile(report: Self.report([Self.full(), Self.bare()])).write(in: tmp)
        #expect(url.lastPathComponent == "soma-flight-trip-2025-03-10.pdf")
        #expect(PDFDocument(url: url)?.pageCount == 1)
        HistoryExport.removeTemporaryFiles(in: tmp)
        #expect(!FileManager.default.fileExists(atPath: url.path()))
    }
}
