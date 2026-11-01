import Foundation
import Testing
@testable import FlightKit

/// The Delay Report's figures: what counts as delayed, the buckets, missing times, years and zones.
struct DelayReportTests {
    /// 2024-06-01 12:00 UTC, plus `days`.
    static func day(_ days: Int, _ hour: Int = 12) -> Date {
        Date(timeIntervalSince1970: 1_717_243_200 + Double(days) * 86_400 + Double(hour - 12) * 3600)
    }

    static func flight(_ ident: String, arr: Int?, dep: Int? = nil, status: PastFlightStatus = .completed,
                       from: String = "KSFO", to: String = "KJFK", airline: String? = nil, type: String? = nil,
                       day: Int = 0, source: PastFlightSource? = .import, country: String? = "US") -> PastFlight {
        PastFlight(date: Self.day(day), ident: ident, originIcao: from, destinationIcao: to,
                   airline: airline ?? String(ident.prefix(2)), aircraftType: type, distanceKm: 4000,
                   delayMinutes: arr ?? 0, status: status, originTz: "America/Los_Angeles",
                   originCountry: country, source: source, arrivalDelayMinutes: arr, departureDelayMinutes: dep)
    }

    /// The fixture: early, on time, 1, 15, 30 and 45 minutes late, a canceled and a diverted flight, and
    /// one with no arrival time.
    static let fixture: [PastFlight] = [
        flight("UA1", arr: -12, dep: -2, airline: "UAL", day: 0),
        flight("UA2", arr: 0, dep: 0, airline: "UAL", day: 1),
        flight("UA3", arr: 1, dep: 5, airline: "UAL", type: "B38M", day: 2),
        flight("AF4", arr: 15, dep: 20, from: "LFPG", airline: "AFR", type: "A359", day: 3, country: "FR"),
        flight("AF5", arr: 30, dep: 25, from: "LFPG", airline: "AFR", type: "A359", day: 4, country: "FR"),
        flight("DL6", arr: 45, dep: 50, from: "KATL", airline: "DAL", type: "A321", day: 5),
        flight("DL7", arr: nil, dep: 10, status: .canceled, from: "KATL", airline: "DAL", day: 6),
        flight("DL8", arr: nil, dep: 3, status: .diverted, from: "KATL", airline: "DAL", day: 7),
        flight("UA9", arr: nil, dep: nil, airline: "UAL", day: 8),
    ]

    @Test func countsAnyMinuteLateAsDelayed() {
        let r = DelayReport.compute(Self.fixture, year: nil)
        #expect(r.flights == 9)
        #expect(r.withTimes == 6)
        #expect(r.noData == 1)
        #expect(r.canceled == 1 && r.diverted == 1)
        // 1, 15, 30 and 45 minutes late: four of the six with times.
        #expect(r.lateArrivals == .init(late: 4, of: 6))
        #expect(r.lateArrivals.percent == 67)
        #expect(r.lostMinutes == 91)
        #expect(r.averageLateMinutes == 23)
        #expect(r.netMinutes == 79)
        #expect(r.worst?.flight.ident == "DL6")
        #expect(r.arrivalDelays.map(\.minutes) == [45, 30, 15, 1])
    }

    @Test func bucketsKeepTheFifteenMinuteView() {
        let r = DelayReport.compute(Self.fixture, year: nil)
        #expect(r.count(.early) == 1)
        #expect(r.count(.onTime) == 2) // on time and 1 minute late
        #expect(r.count(.late15) == 1)
        #expect(r.count(.late30) == 1)
        #expect(r.count(.late45) == 1)
        #expect(r.count(.canceled) == 1)
        #expect(r.count(.diverted) == 1)
        #expect(r.bucketTotal == 8)
        #expect(DelayReport.Bucket.allCases.reduce(0) { $0 + r.count($1) } == r.bucketTotal)
        #expect(r.percent(.onTime) == 25)
        #expect(DelayReport.Bucket.of(14) == .onTime && DelayReport.Bucket.of(-1) == .early)
        #expect(DelayReport.Bucket.of(29) == .late15 && DelayReport.Bucket.of(44) == .late30 && DelayReport.Bucket.of(200) == .late45)
    }

    @Test func airlinesAndAirports() {
        let r = DelayReport.compute(Self.fixture, year: nil)
        // AFR 2/2, DAL 1/1, UAL 1/3 (UA9 has no times, DL7 and DL8 neither).
        #expect(r.airlines.map(\.key) == ["AFR", "DAL", "UAL"])
        #expect(r.airlines.map(\.share) == [.init(late: 2, of: 2), .init(late: 1, of: 1), .init(late: 1, of: 3)])
        #expect(r.airlineLosses.map(\.key) == ["AFR", "DAL", "UAL"])
        #expect(r.airlineLosses.map(\.minutes) == [45, 45, 1])
        #expect(r.airlineLosses.first?.type == "A359")
        // Departures: the canceled flight never left; UA9 has no departure time.
        #expect(r.lateDepartures == .init(late: 5, of: 7))
        // Ties on share and count go by code.
        #expect(r.airports.map(\.key) == ["KATL", "LFPG", "KSFO"])
        #expect(r.airports.map(\.share) == [.init(late: 2, of: 2), .init(late: 2, of: 2), .init(late: 1, of: 3)])
        #expect(r.airports[1].country == "FR")
    }

    @Test func missingActualsAreNoData() {
        let none = [Self.flight("UA1", arr: nil), Self.flight("UA2", arr: nil)]
        let r = DelayReport.compute(none, year: nil)
        #expect(r.withTimes == 0 && r.noData == 2)
        #expect(r.lateArrivals.percent == 0)
        #expect(r.worst == nil)
        #expect(r.averageLateMinutes == 0)
    }

    /// Rows from before the field: a non-zero `delayMinutes` counts; 0 is on time for archived and hand
    /// added flights and no data for imported ones.
    @Test func olderRowsFallBackToDelayMinutes() {
        func legacy(_ m: Int, _ source: PastFlightSource?) -> PastFlight {
            PastFlight(date: Self.day(0), ident: "UA1", originIcao: "KSFO", destinationIcao: "KJFK", distanceKm: 1,
                       delayMinutes: m, source: source)
        }
        #expect(DelayReport.arrivalDelay(legacy(-4, .import)) == -4)
        #expect(DelayReport.arrivalDelay(legacy(22, nil)) == 22)
        #expect(DelayReport.arrivalDelay(legacy(0, .import)) == nil)
        #expect(DelayReport.arrivalDelay(legacy(0, .archive)) == 0)
        #expect(DelayReport.arrivalDelay(legacy(0, .manual)) == 0)
        var canceled = legacy(30, .manual)
        canceled.status = .canceled
        #expect(DelayReport.arrivalDelay(canceled) == nil)
    }

    @Test func yearFilterUsesTheLocalDepartureDay() {
        // 23:30 on 31 December in Los Angeles is 07:30 on 1 January in UTC: it belongs to the old year.
        let nye = PastFlight(date: ISO8601DateFormatter().date(from: "2025-01-01T07:30:00Z")!, ident: "UA1",
                             originIcao: "KLAX", destinationIcao: "KSFO", distanceKm: 500,
                             originTz: "America/Los_Angeles", source: .import, arrivalDelayMinutes: 20)
        let jan = PastFlight(date: ISO8601DateFormatter().date(from: "2025-01-02T18:00:00Z")!, ident: "UA2",
                             originIcao: "KLAX", destinationIcao: "KSFO", distanceKm: 500,
                             originTz: "America/Los_Angeles", source: .import, arrivalDelayMinutes: -5)
        #expect(DelayReport.compute([nye, jan], year: 2024).lateArrivals == .init(late: 1, of: 1))
        #expect(DelayReport.compute([nye, jan], year: 2025).lateArrivals == .init(late: 0, of: 1))
        #expect(DelayReport.compute([nye, jan], year: 2023).flights == 0)
        #expect(DelayReport.compute([nye, jan], year: nil).flights == 2)
    }

    @Test func storeFiltersEveryFigureByYear() async {
        let flights = [Self.flight("UA1", arr: 20, day: 0), Self.flight("UA2", arr: 40, day: 400)]
        let store = await PassportStore(history: FixedHistory(flights: flights))
        await store.load()
        await MainActor.run {
            #expect(store.delayReport.lostMinutes == 60)
            store.year = 2024
            #expect(store.delayReport.lostMinutes == 20)
            store.year = 2025
            #expect(store.delayReport.lostMinutes == 40)
        }
    }
}

/// Flighty export stamps: gate first, runway second, and real minutes across a clock change.
struct FlightyDelayTests {
    @Test func wallClockAndOffsets() {
        #expect(FlightyImport.delay("2024-03-01T10:00", "2024-03-01T10:01") == 1)
        #expect(FlightyImport.delay("2024-03-01T23:50", "2024-03-02T00:35") == 45)
        #expect(FlightyImport.delay("2024-03-01T10:00", "2024-03-01T09:48") == -12)
        #expect(FlightyImport.delay("2024-03-01T10:00", "") == nil)
        // Fall back in Los Angeles: 01:50 PDT then 01:10 PST is 20 minutes later, not 40 earlier.
        #expect(FlightyImport.delay("2024-11-03T01:50-07:00", "2024-11-03T01:10-08:00") == 20)
        #expect(FlightyImport.delay("2024-06-01T08:00Z", "2024-06-01T10:15+02:00") == 15)
        #expect(FlightyImport.delay("2024-06-01T08:00:00+0530", "2024-06-01T08:30:30+0530") == 31)
    }

    static let header = "Date,Airline,Flight,From,To,Dep Terminal,Dep Gate,Arr Terminal,Arr Gate,Canceled,Diverted To,"
        + "Gate Departure (Scheduled),Gate Departure (Actual),Take off (Scheduled),Take off (Actual),"
        + "Landing (Scheduled),Landing (Actual),Gate Arrival (Scheduled),Gate Arrival (Actual)\n"

    @Test func gateThenRunway() throws {
        let csv = Self.header
            // Gate times both ways.
            + "2024-03-01,UAL,1,SFO,JFK,,,,,false,,2024-03-01T08:00,2024-03-01T08:07,,,,,2024-03-01T16:30,2024-03-01T16:41\n"
            // Runway only.
            + "2024-03-02,UAL,2,SFO,JFK,,,,,false,,,,2024-03-02T08:10,2024-03-02T08:30,2024-03-02T16:20,2024-03-02T16:15,,\n"
            // A scheduled gate arrival with a runway actual: never mixed, no arrival delay.
            + "2024-03-03,UAL,3,SFO,JFK,,,,,false,,,,,,,2024-03-03T16:20,2024-03-03T16:30,\n"
        let rows = try FlightyImport.read(Data(csv.utf8)).map { try $0.flight.get() }
        #expect(rows[0].delayMinutes == 11 && rows[0].departureDelayMinutes == 7)
        #expect(rows[1].delayMinutes == -5 && rows[1].departureDelayMinutes == 20)
        #expect(rows[2].delayMinutes == nil && rows[2].departureDelayMinutes == nil)
    }
}

private struct FixedHistory: HistoryService {
    var flights: [PastFlight]
    func pastFlights() async throws(APIError) -> [PastFlight] { flights }
    func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
}

/// Prints the headline numbers of a real export, read through the importer, for a local check only:
///
///     DELAY_REPORT_FILE=~/path/to/export.csv swift test --package-path Packages/FlightKit --filter ExportHeadline
///
/// Skipped without the variable. Prints counts only, never a row.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DELAY_REPORT_FILE"] != nil))
struct ExportHeadlineTests {
    @Test func headline() throws {
        let path = (ProcessInfo.processInfo.environment["DELAY_REPORT_FILE"]! as NSString).expandingTildeInPath
        let rows = try FlightyImport.read(Data(contentsOf: URL(fileURLWithPath: path)))
        let flights: [PastFlight] = rows.compactMap { row in
            guard case .success(let f) = row.flight else { return nil }
            var p = PastFlight(date: Date(timeIntervalSince1970: 0), ident: f.ident ?? "", originIcao: f.origin ?? "",
                               destinationIcao: f.destination ?? "", airline: f.airline, distanceKm: 0,
                               delayMinutes: f.delayMinutes ?? 0, source: .import,
                               arrivalDelayMinutes: f.delayMinutes, departureDelayMinutes: f.departureDelayMinutes)
            p.status = f.canceled ? .canceled : f.divertedTo != nil ? .diverted : .completed
            return p
        }
        let r = DelayReport.compute(flights, year: nil)
        // Before: 15 minutes or more over every flight, minutes floored at 0.
        let old = flights.filter { $0.status != .canceled }
        let oldDelayed = old.filter { $0.delayMinutes >= 15 }.count
        let oldLost = old.reduce(0) { $0 + max(0, $1.delayMinutes) }
        print("HEADLINE before: \(oldDelayed) of \(old.count) delayed (15m+), \(oldLost) min lost")
        print("HEADLINE after: \(r.lateArrivals.late) of \(r.withTimes) with times (\(r.lateArrivals.percent)%), "
              + "\(r.flights) flights, \(r.noData) no data, \(r.canceled) canceled, \(r.diverted) diverted")
        print("HEADLINE lost \(r.lostMinutes) min, average \(r.averageLateMinutes) min, net \(r.netMinutes) min, "
              + "worst \(r.worst?.minutes ?? 0) min")
        print("HEADLINE buckets " + DelayReport.Bucket.allCases.map { "\($0.rawValue) \(r.count($0)) (\(r.percent($0))%)" }.joined(separator: ", "))
        print("HEADLINE late departures \(r.lateDepartures.late) of \(r.lateDepartures.of) (\(r.lateDepartures.percent)%)")
    }
}

/// The report's words.
struct DelayFactsTests {
    @Test func copy() {
        #expect(DelayFacts.board(445) == ("7", "HRS"))
        #expect(DelayFacts.board(60) == ("1", "HR"))
        #expect(DelayFacts.board(45) == ("45", "MIN"))
        #expect(DelayFacts.led(91) == "1H 31M")
        #expect(DelayFacts.led(45) == "45 MIN")
        #expect(DelayFacts.hoursShort(45) == "45m")
        #expect(DelayFacts.hoursShort(80) == "1h 20m")
        #expect(DelayFacts.hoursShort(170) == "3h")
        #expect(DelayFacts.spoken(91) == "1 hour 31 minutes")
        #expect(DelayFacts.net(-12) == ("12m", "early"))
        #expect(DelayFacts.net(0) == ("0m", "on time"))
        #expect(DelayFacts.shareLine(.init(late: 21, of: 47)) == "21 of 47 flights with times reached the gate after schedule")
        let r = DelayReport.compute(DelayReportTests.fixture, year: nil)
        #expect(DelayFacts.basis(r) == "Based on 6 of 9 flights with arrival times. 1 has none. 1 canceled and 1 diverted. Late means any minute after schedule.")
    }
}
