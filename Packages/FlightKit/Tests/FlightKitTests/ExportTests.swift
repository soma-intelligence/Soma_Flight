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

    static func records(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
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
        let url = try await export.writeFile()
        defer { try? FileManager.default.removeItem(at: url) }
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
}
