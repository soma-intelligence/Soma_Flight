import Foundation
import Testing
@testable import FlightKit

/// Writing past flights: the rules shared with the server, the Supabase request bodies, the fake and
/// the Passport store's add, edit, delete and import.
@Suite struct PastFlightWriteTests {
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    static func manual(_ id: UUID = UUID(), date: Date = Date(timeIntervalSince1970: 1_741_932_300)) -> PastFlight {
        PastFlight(id: id, date: date, ident: "AF84", originIcao: "LFPG", destinationIcao: "KSFO",
                   airline: "AFR", aircraftType: "B77W", registration: "F-GSQA", seat: "12A", distanceKm: 0,
                   seatClass: .business, reason: .personal, notes: "Window, wing view", seatPosition: .window,
                   source: .manual)
    }

    // MARK: Rules

    @Test func fieldRules() {
        #expect(PastFlightRules.airportCode(" sfo ") == "SFO")
        #expect(PastFlightRules.airportCode("lfpg") == "LFPG")
        #expect(PastFlightRules.airportCode("SF") == nil && PastFlightRules.airportCode("PARIS") == nil)
        #expect(PastFlightRules.ident("ua 990") == .some("UA990"))
        #expect(PastFlightRules.ident("U21234") == .some("U21234"))
        #expect(PastFlightRules.ident("") == .some(nil))
        #expect(PastFlightRules.ident("FLIGHT") == nil)
        #expect(PastFlightRules.aircraftType("b738") == .some("B738"))
        #expect(PastFlightRules.aircraftType("Boeing 737") == nil)
        #expect(PastFlightRules.registration("f-gznb") == .some("F-GZNB"))
        #expect(PastFlightRules.registration("F GZNB") == nil)
        #expect(PastFlightRules.airline(String(repeating: "a", count: 81)) == nil)
        #expect(PastFlightRules.airline("  Air France ") == .some("Air France"))
    }

    @Test func dateRules() {
        #expect(PastFlightRules.allows(date: Self.now, now: Self.now))
        #expect(PastFlightRules.allows(date: Self.now.addingTimeInterval(11 * 3600), now: Self.now))
        #expect(!PastFlightRules.allows(date: Self.now.addingTimeInterval(13 * 3600), now: Self.now))
        #expect(!PastFlightRules.allows(date: PastFlightRules.earliest.addingTimeInterval(-1), now: Self.now))
        // Noon of today in the farthest zones is never more than 12 hours ahead; tomorrow's always is.
        for id in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"] {
            let zone = TimeZone(identifier: id)!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.year, .month, .day], from: Self.now)
            let today = PastFlightRules.noon(year: c.year!, month: c.month!, day: c.day!, in: zone)!
            let tomorrow = PastFlightRules.noon(year: c.year!, month: c.month!, day: c.day! + 1, in: zone)
            #expect(PastFlightRules.allows(date: today, now: Self.now), "\(id) today")
            #expect(tomorrow.map { !PastFlightRules.allows(date: $0, now: Self.now) } ?? true, "\(id) tomorrow")
        }
        #expect(PastFlightRules.noon(year: 2024, month: 2, day: 30, in: .gmt) == nil)
    }

    @Test func problemsListEveryBrokenRule() {
        #expect(PastFlightRules.problems(Self.manual(), now: Self.now).isEmpty)
        var f = Self.manual(date: Self.now.addingTimeInterval(86_400 * 3))
        f.destinationIcao = "LFPG"
        f.ident = "nope"
        f.seat = "window"
        f.notes = String(repeating: "x", count: 2001)
        #expect(PastFlightRules.problems(f, now: Self.now) == [.date, .sameAirports, .ident, .seat, .notes])
        f = Self.manual()
        f.originIcao = ""
        f.aircraftType = "Jumbo Jet"
        f.registration = "??"
        #expect(PastFlightRules.problems(f, now: Self.now) == [.origin, .aircraftType, .registration])
    }

    // MARK: Supabase bodies

    static func json(_ write: SupabaseHistoryService.Write) throws -> [String: Any] {
        let data = try FlightJSON.encoder.encode(write)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func insertBodyCarriesTheTypedFieldsAndNullsForTheDerivedOnes() throws {
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        var f = Self.manual(id)
        f.originTz = "Europe/Paris"; f.originCountry = "FR"
        let body = try Self.json(.init(flight: f, insert: true))
        #expect(body["id"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(body["date"] as? String == "2025-03-14T06:05:00.000Z")
        #expect(body["ident"] as? String == "AF84")
        #expect(body["origin_icao"] as? String == "LFPG" && body["destination_icao"] as? String == "KSFO")
        #expect(body["seat_class"] as? String == "business" && body["seat_position"] as? String == "window")
        #expect(body["reason"] as? String == "personal" && body["status"] as? String == "completed")
        #expect(body["source"] as? String == "manual")
        // Filled by the server: sent as null, distance 0 included.
        for key in ["distance_km", "origin_tz", "origin_country", "destination_country", "block_minutes",
                    "booking_code", "air_minutes"] {
            #expect(body[key] is NSNull, "\(key)")
        }
        #expect(body["user_id"] == nil, "the user is the column default")
        #expect(Set(body.keys).count == 23)
    }

    @Test func updateBodyHasNoIdAndKeepsTheSource() throws {
        var f = Self.manual()
        f.source = .import
        f.distanceKm = 5_555
        f.seat = nil
        let body = try Self.json(.init(flight: f, insert: false))
        #expect(body["id"] == nil)
        #expect(body["source"] as? String == "import")
        #expect(body["distance_km"] as? Int == 5_555)
        #expect(body["seat"] is NSNull, "a cleared field clears the column")
        // An archived flight never goes back as archived.
        f.source = .archive
        #expect(try Self.json(.init(flight: f, insert: false))["source"] as? String == "manual")
    }

    @Test func importsGoInBatches() {
        let flights = (0..<450).map { _ in Self.manual() }
        let batches = SupabaseHistoryService.batches(flights)
        #expect(batches.map(\.count) == [200, 200, 50])
        #expect(batches.flatMap { $0 }.map(\.flight.id) == flights.map(\.id))
        #expect(batches.allSatisfy { $0.allSatisfy { w in w.insert } })
        #expect(SupabaseHistoryService.batches([]).isEmpty)
    }

    @Test func storedRowsDecodeTheirSource() throws {
        let json = """
        [{"id":"11111111-2222-4333-8444-555555555555","date":"2025-03-14T06:05:00+00:00","ident":"AF84",
          "origin_icao":"LFPG","destination_icao":"KSFO","distance_km":8954,"delay_minutes":0,"status":"completed",
          "source":"import"},
         {"id":"11111111-2222-4333-8444-555555555556","date":"2025-03-14T06:05:00+00:00","ident":"AF84",
          "origin_icao":"LFPG","destination_icao":"KSFO","distance_km":8954,"delay_minutes":0,"status":"completed"}]
        """
        let rows = try SupabaseHistoryService.decode(Data(json.utf8))
        #expect(rows.map(\.source) == [.import, nil])
        #expect(rows.map(\.isEditable) == [true, false], "a row without a source reads as archived")
        #expect(SupabaseHistoryService.columns.hasSuffix(", source"))
    }

    // MARK: Fake

    @Test func fakeStoresEditsAndDeletesOnlyTheTravellersFlights() async throws {
        let svc = FakeHistoryService()
        let seeded = try await svc.pastFlights()
        let added = try await svc.add(Self.manual())
        #expect(added.source == .manual)
        #expect(added.distanceKm > 8_900 && added.distanceKm < 9_000)
        #expect(added.originTz == "Europe/Paris" && added.destinationCountry == "US")
        var edit = added
        edit.destinationIcao = "JFK"
        edit.distanceKm = 0
        let edited = try await svc.update(edit)
        #expect(edited.destinationIcao == "KJFK" && edited.distanceKm < 6_000)
        await #expect(throws: APIError.notFound) { try await svc.update(seeded[0]) }
        await #expect(throws: APIError.notFound) { try await svc.delete(seeded[0].id) }
        try await svc.delete(added.id)
        #expect(try await svc.pastFlights().count == seeded.count)
        let imported = try await svc.addAll([Self.manual(), Self.manual()].map { var f = $0; f.source = .import; return f })
        #expect(imported.map(\.source) == [.import, .import])
        #expect(try await svc.pastFlights().count == seeded.count + 2)
    }

    // MARK: Store

    @MainActor @Test func storeAddsEditsDeletesAndImports() async throws {
        let svc = FakeHistoryService()
        let store = PassportStore(history: svc)
        await store.load()
        let before = store.allFlights.count
        let km = store.stats.distanceKm

        #expect(await store.add(Self.manual()))
        #expect(store.allFlights.count == before + 1)
        #expect(store.stats.distanceKm > km, "the figures follow at once")
        let added = try #require(store.allFlights.first { $0.ident == "AF84" && $0.isEditable })

        var edit = added
        edit.notes = "Edited"
        #expect(await store.update(edit))
        #expect(store.allFlights.first { $0.id == added.id }?.notes == "Edited")

        #expect(await store.delete(added.id))
        #expect(store.allFlights.count == before)

        // A refused write keeps the history and says why.
        await svc.setNextError(.offline)
        #expect(await !store.add(Self.manual()))
        #expect(store.writeError == .offline)
        #expect(store.allFlights.count == before)

        let csv = "date,from,to\n2019-06-20,KSFO,KJFK\n2019-06-21,KJFK,KSFO\n"
        let preview = try store.importPreview(Data(csv.utf8), now: Self.now)
        #expect(preview.rows.count == 2)
        #expect(await store.importFlights(preview.flights) == 2)
        #expect(store.writeError == nil)
        #expect(store.allFlights.count == before + 2)
        // The same file again: both rows are now duplicates.
        #expect(try store.importPreview(Data(csv.utf8), now: Self.now).duplicates.count == 2)

        await svc.setNextError(.providerUnavailable)
        #expect(await store.importFlights(preview.flights) == nil)
        #expect(store.writeError == .providerUnavailable)
    }
}
