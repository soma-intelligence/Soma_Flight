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
        #expect(stats.severity == .major && stats.perHour.count == 3 && stats.worstAirlines[0].operator == "UAL")
        #expect(stats.perHour[1].hour == Date(timeIntervalSince1970: 1_800_003_600) && stats.perHour[1].late45 == 1)
        #expect(try FlightJSON.decoder.decode(DelayStats.self, from: FlightJSON.encoder.encode(stats)) == stats)
        let wx = try FlightJSON.decoder.decode(Weather.self, from: fixture("weather_kaus"))
        #expect(wx.category == .VFR && wx.gustKt == 22 && wx.forecast.count == 1)
    }

    @Test func flightRoundTrips() throws {
        let f = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_full"))
        let data = try FlightJSON.encoder.encode(f)
        #expect(try FlightJSON.decoder.decode(Flight.self, from: data) == f)
    }

    @Test(arguments: [
        ("2026-10-23T23:25:00+00:00", 1_792_797_900.0),
        ("2026-10-23T23:25:00.123456+00:00", 1_792_797_900.123),
    ])
    func dateFormats(_ s: String, _ epoch: Double) throws {
        let d = try FlightJSON.decoder.decode(Date.self, from: Data("\"\(s)\"".utf8))
        #expect(abs(d.timeIntervalSince1970 - epoch) < 0.01)
    }

    @Test func apiErrorFromCode() {
        #expect(APIError(code: "provider_unavailable") == .providerUnavailable)
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

    @Test func decodesPastFlightWithoutNewKeys() throws {
        let json = """
        {"id":"6f1b6a52-3a3f-4c3b-9b6e-1d2b3c4d5e6f","date":"2026-10-02T18:00:00.000Z","ident":"UA1882",
         "origin_icao":"KSFO","destination_icao":"KDEN","airline":null,"aircraft_type":null,"registration":null,
         "seat":null,"distance_km":1500,"block_minutes":null,"delay_minutes":0,"status":"completed"}
        """
        let f = try FlightJSON.decoder.decode(PastFlight.self, from: Data(json.utf8))
        #expect(f.seatClass == nil && f.reason == nil && f.bookingCode == nil && f.notes == nil)
        #expect(f.originCountry == nil && f.destinationCountry == nil && f.airMinutes == nil)
    }

    @Test func decodesPastFlightWithNewKeys() throws {
        let json = """
        {"id":"6f1b6a52-3a3f-4c3b-9b6e-1d2b3c4d5e6f","date":"2026-10-02T18:00:00+00:00","ident":"UA1882",
         "origin_icao":"KSFO","destination_icao":"KDEN","distance_km":1500,"delay_minutes":0,"status":"completed",
         "seat_class":"premium_economy","reason":"business","booking_code":"ABC123","notes":"x",
         "origin_country":"US","destination_country":"US","air_minutes":120}
        """
        let f = try FlightJSON.decoder.decode(PastFlight.self, from: Data(json.utf8))
        #expect(f.seatClass == .premiumEconomy && f.reason == .business && f.bookingCode == "ABC123")
        #expect(f.originCountry == "US" && f.airMinutes == 120)
    }

    @Test func decodesFlightOffOn() throws {
        let base = try FlightJSON.decoder.decode(Flight.self, from: fixture("flight_sparse"))
        #expect(base.scheduledOff == nil && base.estimatedOn == nil)
        var f = base
        f.scheduledOff = Date(timeIntervalSince1970: 1_792_770_600)
        f.estimatedOn = Date(timeIntervalSince1970: 1_792_790_000)
        let back = try FlightJSON.decoder.decode(Flight.self, from: FlightJSON.encoder.encode(f))
        let wire = #"{"scheduled_off":"2026-10-23T15:42:00.123456+00:00","estimated_on":"2026-10-23 16:42:00+00"}"#
        let partial = try FlightJSON.decoder.decode([String: Date].self, from: Data(wire.utf8))
        #expect(partial.count == 2)
        #expect(back.scheduledOff == f.scheduledOff && back.estimatedOn == f.estimatedOn)
        #expect(back.scheduledOn == nil && back.estimatedOff == nil)
    }
}
