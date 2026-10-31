import Foundation
import Testing
@testable import FlightKit

/// The Add Past Flight sheet's model: searches, validation against the server's rules, the day kept in
/// the origin's zone, saving and deleting through the Passport store.
@MainActor @Suite struct PastFlightEditorTests {
    static let directory = AirportDirectory.bundled()
    static let reference = ReferenceData.bundled()
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    static func model(_ flight: PastFlight? = nil) -> PastFlightEditorModel {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        return PastFlightEditorModel(flight: flight, airport: directory.lookup,
                                     today: Date(timeIntervalSince1970: 1_741_932_300), calendar: cal)
    }

    static let paris: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        return cal
    }()

    @Test func airportSearch() {
        #expect(PastFlightEditorModel.airports(matching: "sfo").first?.id == "KSFO")
        #expect(PastFlightEditorModel.airports(matching: "KJFK").first?.id == "KJFK")
        // The whole seed: Paris's two big airports first, then the smaller fields.
        #expect(PastFlightEditorModel.airports(matching: "paris").prefix(2).map(\.id) == ["LFPG", "LFPO"])
        #expect(PastFlightEditorModel.airports(matching: "").isEmpty)
        #expect(PastFlightEditorModel.airports(matching: "x").count <= 20)
    }

    @Test func airlineSearch() {
        let all = Self.reference.airlines
        #expect(PastFlightEditorModel.airlines(matching: "AF", in: all).first?.id == "AFR")
        #expect(PastFlightEditorModel.airlines(matching: "ual", in: all).first?.id == "UAL")
        #expect(PastFlightEditorModel.airlines(matching: "united", in: all).contains { $0.id == "UAL" })
        #expect(PastFlightEditorModel.airlines(matching: "x", in: all).count <= 20)
    }

    @Test func newFlightIsCheckedAndNormalised() throws {
        let m = Self.model()
        #expect(m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris)
            == .failure(.init(problems: [.origin, .destination])))
        m.origin = "SFO"; m.destination = "CDG"
        m.ident = "ua 990"; m.seat = "23a"; m.registration = "n12345"; m.notes = "  Window seat  "
        m.seatClass = .business; m.seatPosition = .window
        let f = try m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris).get()
        #expect([f.originIcao, f.destinationIcao, f.ident] == ["KSFO", "LFPG", "UA990"])
        #expect(f.airline == "UAL", "the airline comes from the flight number")
        #expect(f.seat == "23A" && f.registration == "N12345" && f.notes == "Window seat")
        #expect(f.source == .manual && f.distanceKm == 0)
        // The day picked (14 March) is stored at noon in San Francisco.
        #expect(PastFlightRules.dayKey(f.date, in: TimeZone(identifier: "America/Los_Angeles")!) == "2025-03-14")

        m.ident = "nope"; m.seat = "aisle"; m.aircraftType = "Jumbo"; m.destination = "KSFO"
        #expect(m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris)
            == .failure(.init(problems: [.sameAirports, .ident, .aircraftType, .seat])))
        m.destination = "LFPG"; m.ident = ""; m.seat = ""; m.aircraftType = ""
        m.day = Self.now.addingTimeInterval(5 * 86_400)
        #expect(m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris)
            == .failure(.init(problems: [.date])))
    }

    @Test func editingKeepsTheTimeAndTheDistanceUntilTheRouteMoves() throws {
        let original = PastFlight(date: FlightJSON.parse("2025-03-14T06:05:00Z")!, ident: "AF84", originIcao: "LFPG",
                                  destinationIcao: "KSFO", distanceKm: 8_954, originTz: "Europe/Paris",
                                  originCountry: "FR", source: .import)
        let m = Self.model(original)
        #expect(m.isEditing)
        var f = try m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris).get()
        #expect(f == original, "nothing changed: the same flight")
        m.seat = "1A"
        f = try m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris).get()
        #expect(f.date == original.date && f.distanceKm == 8_954 && f.source == .import)
        m.destination = "KJFK"
        f = try m.flight(now: Self.now, reference: Self.reference, calendar: Self.paris).get()
        #expect(f.distanceKm == 0 && f.originCountry == nil, "a moved route is worked out again by the server")
    }

    @Test func saveAndDeleteThroughTheStore() async throws {
        let svc = FakeHistoryService()
        let store = PassportStore(history: svc)
        await store.load()
        let count = store.allFlights.count
        let m = Self.model()
        #expect(await !m.save(to: store, reference: Self.reference, now: Self.now))
        #expect(m.errors[.origin] == PastFlightRules.Problem.origin.message)
        m.origin = "LFPG"; m.destination = "KSFO"
        #expect(await m.save(to: store, reference: Self.reference, now: Self.now))
        #expect(m.errors.isEmpty)
        let added = try #require(store.allFlights.first { $0.isEditable })
        #expect(store.allFlights.count == count + 1)

        let edit = Self.model(added)
        await svc.setNextError(.offline)
        edit.notes = "Hello"
        #expect(await !edit.save(to: store, reference: Self.reference, now: Self.now))
        #expect(edit.saveError == APIError.offline.message)
        #expect(await edit.delete(from: store))
        #expect(store.allFlights.count == count)
        // Gone already: the second delete says so.
        #expect(await !edit.delete(from: store))
        #expect(edit.saveError == "This flight is no longer in your history.")
    }
}
