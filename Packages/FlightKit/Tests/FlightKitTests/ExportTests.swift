import Foundation
import Testing
@testable import FlightKit

/// The history export built on the device: CSV (RFC 4180) and JSON, dates in ISO 8601 UTC.
@Suite struct ExportTests {
    static let header = "date,flight,from,to,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status"

    /// 2025-03-14 06:05:00 UTC.
    static let date = Date(timeIntervalSince1970: 1_741_932_300)

    static func flight(airline: String? = "Air France", seat: String? = "12A", block: Int? = 690,
                       status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, date: date, ident: "AFR84",
                   originIcao: "LFPG", destinationIcao: "KSFO", airline: airline, aircraftType: "B77W",
                   registration: "F-GSQA", seat: seat, distanceKm: 8_954, blockMinutes: block, delayMinutes: 25,
                   status: status, originTz: "Europe/Paris")
    }

    /// The records after the byte order mark.
    static func records(_ data: Data) -> [String] {
        String(decoding: data.starts(with: PastFlight.csvBOM) ? data.dropFirst(3) : data, as: UTF8.self)
            .components(separatedBy: "\r\n")
    }

    @Test func csvStartsWithTheUTF8ByteOrderMark() {
        let data = PastFlight.csv([Self.flight(airline: "Aerolíneas Argentinas")])
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(Array(PastFlight.csv([]).prefix(3)) == [0xEF, 0xBB, 0xBF])
        // Once, at the start only, and the rest is the plain UTF-8 text.
        #expect(Self.records(data)[0] == Self.header)
        #expect(Self.records(data)[1].contains("Aerolíneas Argentinas"))
        #expect(!data.dropFirst(3).starts(with: PastFlight.csvBOM))
    }

    @Test func csvHasHeaderAndRows() {
        let rows = Self.records(PastFlight.csv([Self.flight(), Self.flight(airline: nil, seat: nil, block: nil, status: .canceled)]))
        #expect(rows.count == 3)
        #expect(rows[0] == Self.header)
        #expect(rows[1] == "2025-03-14T06:05:00Z,AFR84,LFPG,KSFO,Air France,B77W,F-GSQA,12A,8954,690,25,completed")
        // Missing values are empty fields, never "nil".
        #expect(rows[2] == "2025-03-14T06:05:00Z,AFR84,LFPG,KSFO,,B77W,F-GSQA,,8954,,25,canceled")
    }

    @Test func csvEscapesCommas() {
        let rows = Self.records(PastFlight.csv([Self.flight(airline: "Lufthansa, Cargo")]))
        #expect(rows[1].contains(",\"Lufthansa, Cargo\","))
    }

    @Test func csvEscapesQuotesAndNewlines() {
        let data = PastFlight.csv([Self.flight(airline: "The \"Best\" Air", seat: "12A\nwindow")])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(",\"The \"\"Best\"\" Air\","))
        #expect(text.contains(",\"12A\nwindow\","))
        // A carriage return alone is quoted too.
        #expect(String(decoding: PastFlight.csv([Self.flight(seat: "1\r2")]), as: UTF8.self).contains(",\"1\r2\","))
    }

    @Test func csvEmptyHistoryIsHeaderOnly() {
        #expect(Self.records(PastFlight.csv([])) == [Self.header])
    }

    @Test func csvDatesAreUTCWhateverTheZone() {
        // The origin is Paris; the export still writes UTC.
        #expect(Self.records(PastFlight.csv([Self.flight()]))[1].hasPrefix("2025-03-14T06:05:00Z,"))
    }

    @Test func jsonRoundTripsWithUTCDates() throws {
        let data = try PastFlightExport.data([Self.flight()], format: .json)
        let text = String(decoding: data, as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(object.first?["date"] as? String == "2025-03-14T06:05:00Z")
        #expect(object.first?["origin_icao"] as? String == "LFPG")
        #expect(text.hasSuffix("\n"))
        let back = try FlightJSON.decoder.decode([PastFlight].self, from: data)
        #expect(back == [Self.flight()])
    }

    @Test func fileNamesCarryTheLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 06:05 UTC is still March 13 in California.
        #expect(HistoryExport.fileName(for: .csv, on: Self.date, calendar: cal) == "soma-flight-history-2025-03-13.csv")
        #expect(HistoryExport.fileName(for: .json, on: Self.date, calendar: cal) == "soma-flight-history-2025-03-13.json")
    }

    @Test func exportFileIsWrittenUnderItsName() async throws {
        let export = HistoryExport(format: .csv, history: FakeHistoryService())
        let tmp = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = try await export.writeFile(in: tmp)
        #expect(url.lastPathComponent == HistoryExport.fileName(for: .csv, on: .now))
        let rows = Self.records(try Data(contentsOf: url))
        #expect(rows.first == Self.header)
        #expect(rows.count == 43)
    }

    @Test func exportFailurePropagates() async throws {
        let history = FakeHistoryService()
        await history.setNextError(.offline)
        let export = HistoryExport(format: .json, history: history)
        await #expect(throws: APIError.offline) { try await export.writeFile() }
    }

    @Test func leftoverExportFilesAreRemoved() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try await HistoryExport(format: .csv, history: FakeHistoryService()).writeFile(in: tmp)
        let b = try await HistoryExport(format: .json, history: FakeHistoryService()).writeFile(in: tmp)
        let other = tmp.appending(path: "keep.txt")
        try Data("x".utf8).write(to: other)
        HistoryExport.removeTemporaryFiles(in: tmp)
        #expect(!FileManager.default.fileExists(atPath: a.path()))
        #expect(!FileManager.default.fileExists(atPath: b.path()))
        #expect(FileManager.default.fileExists(atPath: other.path()))
    }
}

/// Review round 1: spreadsheet formula injection.
@Suite struct ExportFormulaTests {
    @Test func formulaTextCellsAreDefused() {
        let f = ExportTests.flight(airline: "=SUM(A1)", seat: "-1+1")
        var g = f
        g.registration = "@x"
        g.aircraftType = "+cmd"
        let rows = ExportTests.records(PastFlight.csv([f, g]))
        #expect(rows[1].contains(",'=SUM(A1),"))
        #expect(rows[1].contains(",'-1+1,"))
        #expect(rows[2].contains(",'@x,"))
        #expect(rows[2].contains(",'+cmd,"))
    }

    @Test func tabAndCarriageReturnAreDefused() {
        #expect(PastFlight.csvText("\tx") == "'\tx")
        #expect(PastFlight.csvText("\rx") == "'\rx")
        #expect(PastFlight.csvText("AF84") == "AF84")
        #expect(PastFlight.csvText("") == "")
        // Quoting still applies after the prefix.
        let row = ExportTests.records(PastFlight.csv([ExportTests.flight(airline: "=a,b")]))[1]
        #expect(row.contains(",\"'=a,b\","))
    }

    @Test func negativeDelayStaysNumeric() {
        var f = ExportTests.flight()
        f.delayMinutes = -5
        let row = ExportTests.records(PastFlight.csv([f]))[1]
        #expect(row.hasSuffix(",690,-5,completed"))
    }
}
