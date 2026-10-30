import Foundation
import Testing
@testable import FlightKit

/// The CSV import: our own export back in, generic files with loose headers, what is skipped and why,
/// duplicates of the history and of earlier rows.
@Suite struct PastFlightImportTests {
    static let directory = AirportDirectory.bundled()
    static let reference = ReferenceData.bundled()
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    static func preview(_ csv: String, existing: [PastFlight] = []) throws -> PastFlightImport.Preview {
        try PastFlightImport.preview(Data(csv.utf8), existing: existing, airport: directory.lookup,
                                     reference: reference, now: now)
    }

    static func iso(_ s: String) -> Date { FlightJSON.parse(s)! }

    // MARK: Round trip

    @Test func ownExportImportsBack() throws {
        let flights = [
            PastFlight(date: Self.iso("2025-03-14T06:05:00Z"), ident: "AF84", originIcao: "LFPG", destinationIcao: "KSFO",
                       airline: "Air France", aircraftType: "B77W", registration: "F-GSQA", seat: "12A",
                       distanceKm: 8_954, blockMinutes: 690, delayMinutes: -5, status: .diverted),
            PastFlight(date: Self.iso("2024-07-01T18:30:00Z"), ident: "", originIcao: "KJFK", destinationIcao: "EGLL",
                       airline: "=cmd", distanceKm: 5_540),
        ]
        let csv = String(decoding: PastFlight.csv(flights), as: UTF8.self)
        let p = try Self.preview(csv)
        #expect(p.format == .somaFlight)
        #expect(p.skipped.isEmpty && p.duplicates.isEmpty)
        #expect(p.rows.map(\.row) == [2, 3])
        let a = p.rows[0].flight, b = p.rows[1].flight
        #expect(a.date == flights[0].date)
        #expect([a.ident, a.originIcao, a.destinationIcao] == ["AF84", "LFPG", "KSFO"])
        #expect(a.airline == "AFR", "a name the reference list knows becomes its ICAO code")
        #expect(a.aircraftType == "B77W" && a.registration == "F-GSQA" && a.seat == "12A")
        #expect(a.distanceKm == 8_954 && a.blockMinutes == 690 && a.delayMinutes == -5 && a.status == .diverted)
        #expect(a.source == .import)
        #expect(b.ident == "" && b.airline == "=cmd", "the export's formula guard comes off")
        #expect(p.rows.allSatisfy { $0.warnings.isEmpty })

        // Imported again over the stored copy: every row is already there.
        let again = try Self.preview(csv, existing: flights)
        #expect(again.rows.isEmpty)
        #expect(again.duplicates.map(\.reason) == [.alreadyInHistory, .alreadyInHistory])
    }

    // MARK: Generic files

    @Test func looseHeadersAndIATACodes() throws {
        let csv = """
        Flight Date;Flight #;Departure Airport;Arrival Airport;Carrier;Aircraft Type;Seat Number;Cabin;Trip Reason;Seat Type;Comments
        2023-05-12;ua 990;sfo;CDG;United;Boeing 777-300ER;23a;Business;work;Window;"Upgrade; nice"
        """
        let p = try Self.preview(csv)
        #expect(p.format == .generic)
        let f = try #require(p.rows.first).flight
        #expect(f.ident == "UA990")
        #expect([f.originIcao, f.destinationIcao] == ["KSFO", "LFPG"], "IATA codes become ICAO")
        #expect(f.airline == "UAL")
        #expect(f.aircraftType == "B77W", "a type named in full becomes its designator")
        #expect(PastFlightImport.aircraftType("777-300ER", reference: Self.reference) == "B77W")
        #expect(f.seat == "23A" && f.seatClass == .business && f.reason == .business && f.seatPosition == .window)
        #expect(f.notes == "Upgrade; nice")
        #expect(f.distanceKm == 0, "the server fills the distance")
        // A day without a time is noon at the origin, so it stays that day there.
        #expect(PastFlightRules.dayKey(f.date, in: TimeZone(identifier: "America/Los_Angeles")!) == "2023-05-12")
    }

    @Test func airportCellsWithNamesAndBrackets() {
        let lookup = Self.directory.lookup
        #expect(PastFlightImport.airportCode(in: "Paris / Charles de Gaulle (CDG/LFPG)", airport: lookup) == "LFPG")
        #expect(PastFlightImport.airportCode(in: "San Francisco (SFO)", airport: lookup) == "KSFO")
        #expect(PastFlightImport.airportCode(in: "SFO San Francisco", airport: lookup) == "KSFO")
        #expect(PastFlightImport.airportCode(in: "xyz", airport: lookup) == "XYZ", "an unknown code stays as written")
        #expect(PastFlightImport.airportCode(in: "Somewhere nice", airport: lookup) == nil)
    }

    @Test func requiredColumnsAreReported() {
        #expect(throws: PastFlightImport.Failure.missingColumns(["from", "to"])) {
            try Self.preview("date,flight\n2024-01-01,AF84\n")
        }
        #expect(throws: PastFlightImport.Failure.empty) { try Self.preview("date,from,to\n") }
        #expect(throws: PastFlightImport.Failure.empty) { try Self.preview("") }
    }

    @Test func tooManyRowsAreRefused() {
        let body = String(repeating: "2024-01-01,KSFO,KJFK\n", count: PastFlightImport.maxRows + 1)
        #expect(throws: PastFlightImport.Failure.tooManyRows(limit: PastFlightImport.maxRows)) {
            try Self.preview("date,from,to\n" + body)
        }
    }

    // MARK: Skips and warnings

    @Test func skippedRowsSayWhy() throws {
        let csv = """
        date,from,to
        ,KSFO,KJFK
        2024-01-01,,KJFK
        2024-01-01,KSFO,
        yesterday,KSFO,KJFK
        2024-02-30,KSFO,KJFK
        2027-01-01,KSFO,KJFK
        1903-12-17,KSFO,KJFK
        2024-01-01,Somewhere,KJFK
        2024-01-01,KSFO,Nowhere at all
        2024-01-01,SFO,KSFO
        2024-01-01,KSFO,KJFK
        """
        let p = try Self.preview(csv)
        #expect(p.skipped.map(\.reason) == [
            .noDate, .noOrigin, .noDestination, .badDate("yesterday"), .badDate("2024-02-30"), .futureDate,
            .badDate("1903-12-17"), .badOrigin("Somewhere"), .badDestination("Nowhere at all"), .sameAirports,
        ])
        #expect(p.skipped.map(\.row) == Array(2...11))
        #expect(p.rows.map(\.row) == [12])
    }

    @Test func badOptionalValuesAreLeftOutWithAWarning() throws {
        let csv = """
        date,from,to,flight,aircraft,registration,seat,class
        2024-01-01,KSFO,KJFK,not a flight,Flying Banana,F GZNB!,aisle,Steerage
        """
        let row = try #require(try Self.preview(csv).rows.first)
        #expect(row.flight.ident == "" && row.flight.aircraftType == nil && row.flight.registration == nil)
        #expect(row.flight.seat == nil && row.flight.seatClass == nil)
        #expect(row.warnings == [
            "Flight number \u{201C}not a flight\u{201D} left out", "Aircraft \u{201C}Flying Banana\u{201D} left out",
            "Registration \u{201C}F GZNB!\u{201D} left out", "Seat \u{201C}aisle\u{201D} left out",
            "Class \u{201C}Steerage\u{201D} left out",
        ])
        #expect(PastFlightRules.problems(row.flight, now: Self.now).isEmpty, "what is kept passes the server's rules")
    }

    @Test func airlineComesFromTheFlightNumberWhenMissing() throws {
        let f = try #require(try Self.preview("date,from,to,flight\n2024-01-01,KSFO,KJFK,UA990\n").rows.first).flight
        #expect(f.airline == "UAL")
    }

    // MARK: Duplicates

    @Test func duplicatesOfHistoryAndOfEarlierRows() throws {
        // Stored: SFO to JFK on 2024-03-10, 23:30 in San Francisco (06:30 UTC the next day).
        let stored = PastFlight(date: Self.iso("2024-03-11T06:30:00Z"), ident: "UA1", originIcao: "SFO",
                                destinationIcao: "KJFK", distanceKm: 4_150, originTz: "America/Los_Angeles")
        let csv = """
        date,from,to
        2024-03-10,KSFO,JFK
        2024-03-11,KSFO,KJFK
        2024-03-11,SFO,JFK
        2024-03-11,KJFK,KSFO
        """
        let p = try Self.preview(csv, existing: [stored])
        #expect(p.duplicates.map(\.reason) == [.alreadyInHistory, .repeatedRow(3)])
        #expect(p.duplicates.map(\.row) == [2, 4])
        #expect(p.rows.map(\.row) == [3, 5], "another day, or the way back, is another flight")
    }

    // MARK: Dates

    @Test func dateForms() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        func day(_ s: String, time: String = "", dayFirst: Bool = false) -> String? {
            PastFlightImport.date(s, time: time, dayFirst: dayFirst, in: paris).map { PastFlightRules.dayKey($0, in: paris) }
        }
        #expect(day("2025-03-14") == "2025-03-14")
        #expect(day("2025/03/14") == "2025-03-14")
        #expect(day("14.03.2025") == "2025-03-14")
        #expect(day("14-03-2025") == "2025-03-14")
        #expect(day("03/04/2025") == "2025-03-04")
        #expect(day("03/04/2025", dayFirst: true) == "2025-04-03")
        #expect(day("2025-03-14 23:30") == "2025-03-14")
        #expect(day("13/13/2025") == nil)
        #expect(PastFlightImport.date("2025-03-14", time: "08:15", dayFirst: false, in: paris)
            == Self.iso("2025-03-14T07:15:00Z"))
        #expect(PastFlightImport.date("2025-03-14T06:05:00Z", time: "", dayFirst: false, in: paris)
            == Self.iso("2025-03-14T06:05:00Z"))
        #expect(PastFlightImport.slashDayFirst(["01/02/2024", "25/02/2024"]))
        #expect(!PastFlightImport.slashDayFirst(["01/02/2024", "02/25/2024"]))
        #expect(!PastFlightImport.slashDayFirst(["01/02/2024"]))
    }

    // MARK: CSV

    @Test func csvRecords() {
        let text = "a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"two\nlines\"\n\n1,2,3\r4,5,6"
        #expect(PastFlightImport.records(text) == [
            ["a", "b", "c"], ["x, y", "say \"hi\"", "two\nlines"], ["1", "2", "3"], ["4", "5", "6"],
        ])
        #expect(PastFlightImport.records("a;b\tc;d\n1;2\t3;4") == [["a", "b\tc", "d"], ["1", "2\t3", "4"]])
        #expect(PastFlightImport.records("a\tb\n1\t2") == [["a", "b"], ["1", "2"]])
    }

    @Test func textDecoding() {
        #expect(PastFlightImport.text(PastFlight.csvBOM + Data("date".utf8)) == "date")
        // Not UTF-8: read as Windows Latin 1 ("é" is 0xE9 there).
        #expect(PastFlightImport.text(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    }
}
