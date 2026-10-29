import Foundation
import Testing
@testable import FlightKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct ModelDecodingTests {
    @Test func decodesFullFlight() throws {
        let flight = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_full"))
        #expect(flight.status == .enRoute)
        #expect(flight.gateOrigin == "B22")
        #expect(flight.position?.altitudeFt == 37000)
        #expect(flight.originIcao == "LFPG")
        #expect(flight.destinationIata == "SFO")
    }

    @Test func decodesSparseFlight() throws {
        let f = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_sparse"))
        #expect(f.operator == nil && f.originIata == nil && f.destinationIata == nil)
        #expect(f.scheduledOut == nil && f.scheduledIn == nil && f.estimatedOut == nil && f.estimatedIn == nil)
        #expect(f.actualOut == nil && f.actualOff == nil && f.actualOn == nil && f.actualIn == nil)
        #expect(f.gateOrigin == nil && f.gateDestination == nil && f.terminalOrigin == nil)
        #expect(f.terminalDestination == nil && f.baggageBelt == nil)
        #expect(f.aircraftType == nil && f.registration == nil && f.position == nil)
        #expect(f.departureDelay == nil && f.arrivalDelay == nil)
        #expect(f.progress == 0)
    }

    @Test func unknownStatusIsUnknown() throws {
        var json = try #require(String(data: fixture("flight_sparse"), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"scheduled\"", with: "\"holding\"")
        let f = try FlightJSON.decoder.decode(Flight.self, from: Data(json.utf8))
        #expect(f.status == .unknown)
    }

    @Test func decodesBoardStatsWeather() throws {
        let board = try FlightJSON.decoder.decode(AirportBoard.self, from: fixture("board_kaus"))
        #expect(board.kind == .departures && board.flights.count == 2)
        let stats = try FlightJSON.decoder.decode(DelayStats.self, from: fixture("stats_kaus"))
        #expect(stats.severity == .moderate && stats.perHour.count == 3 && stats.worstAirlines[0].operator == "AAL")
        let wx = try FlightJSON.decoder.decode(Weather.self, from: fixture("weather_kaus"))
        #expect(wx.category == .VFR && wx.gustKt == 22 && wx.forecast.count == 1)
    }

    @Test func flightRoundTrips() throws {
        let f = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_full"))
        let data = try FlightJSON.encoder.encode(f)
        #expect(try FlightJSON.decoder.decode(Flight.self, from: data) == f)
    }

    @Test func apiErrorFromCode() {
        #expect(APIError(code: "plan_limit") == .planLimit)
        #expect(APIError(code: "something_new") == .providerUnavailable)
    }

    @Test func localTimeUsesAirportZone() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-23T23:25:00Z"))
        let tz = try #require(TimeZone(identifier: "America/Chicago"))
        #expect(localTime(date, in: tz, style: .h24) == "18:25 CDT")
    }

    @Test func progressClamps() throws {
        var f = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_sparse"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        f.scheduledOut = t0
        f.scheduledIn = t0.addingTimeInterval(7200)
        #expect(f.progress(at: t0.addingTimeInterval(-60)) == 0)
        #expect(f.progress(at: t0.addingTimeInterval(9000)) == 1)
        #expect(abs(f.progress(at: t0.addingTimeInterval(3600)) - 0.5) < 0.001)
    }
}
