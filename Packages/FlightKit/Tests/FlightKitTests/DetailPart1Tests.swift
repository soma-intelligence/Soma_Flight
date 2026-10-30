import Foundation
import Testing
@testable import FlightKit

/// Task 15: the flight sheet's header, countdown, times, day marker and the booking code, seat and
/// notes the user keeps on a followed flight.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct DetailPart1Tests {
    static let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco",
                             country: "US", lat: 37.6189, lon: -122.3750, tz: "America/Los_Angeles")
    static let cdg = Airport(id: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris",
                             country: "FR", lat: 49.0097, lon: 2.5479, tz: "Europe/Paris")
    static let hnd = Airport(id: "RJTT", iata: "HND", name: "Tokyo Haneda", city: "Tokyo",
                             country: "JP", lat: 35.5523, lon: 139.7798, tz: "Asia/Tokyo")
    static let oak = Airport(id: "KOAK", iata: "OAK", name: "Oakland International", city: "Oakland",
                             country: "US", lat: 37.7213, lon: -122.2208, tz: "America/Los_Angeles")


    /// UA 990, SFO 15:20 Friday 30 October 2026 to CDG 10:15 the next morning.
    static var ua990: Flight {
        Flight(providerId: "p", ident: "UA990", operator: "UAL", originIcao: "KSFO", originIata: "SFO",
               destinationIcao: "LFPG", destinationIata: "CDG",
               scheduledOut: date("2026-10-30T22:20:00Z"), scheduledIn: date("2026-10-31T09:15:00Z"),
               gateOrigin: "G5", terminalOrigin: "I", terminalDestination: "1", status: .scheduled)
    }

    @Test func headerLine() {
        #expect(DetailFacts.headerLine(Self.ua990, origin: Self.sfo) == "UA 990 · FRI, 30 OCT")
        var bare = Self.ua990
        bare.scheduledOut = nil
        #expect(DetailFacts.headerLine(bare, origin: Self.sfo) == "UA 990")
    }

    @Test func countdownCases() {
        let f = Self.ua990
        let out = f.scheduledOut!
        #expect(DetailFacts.countdown(f, destination: Self.cdg, now: out.addingTimeInterval(-86_400)) == "Departs in 1 day")
        #expect(DetailFacts.countdown(f, destination: Self.cdg, now: out.addingTimeInterval(-47 * 3600)) == "Departs in 1 day")
        #expect(DetailFacts.countdown(f, destination: Self.cdg, now: out.addingTimeInterval(-3 * 86_400 - 60)) == "Departs in 3 days")
        #expect(DetailFacts.countdown(f, destination: Self.cdg, now: out.addingTimeInterval(-(3 * 3600 + 20 * 60))) == "Departs in 3h 20m")
        #expect(DetailFacts.countdown(f, destination: Self.cdg, now: out.addingTimeInterval(-12 * 60)) == "Departs in 12m")

        var air = f
        air.status = .enRoute
        air.actualOut = out
        air.estimatedIn = date("2026-10-31T09:15:00Z")
        #expect(DetailFacts.countdown(air, destination: Self.cdg,
                                      now: air.estimatedIn!.addingTimeInterval(-(2 * 3600 + 5 * 60))) == "Arrives in 2h 05m")

        for s in [FlightStatus.landed, .arrived] {
            var done = f
            done.status = s
            #expect(DetailFacts.countdown(done, destination: Self.cdg, now: out) == "Landed")
        }
        var canceled = f
        canceled.status = .canceled
        #expect(DetailFacts.countdown(canceled, destination: Self.cdg, now: out) == "Canceled")

        var diverted = f
        diverted.status = .diverted
        #expect(DetailFacts.countdown(diverted, destination: Self.oak, now: out) == "Diverted to OAK")
        let noIata = Airport(id: "KXYZ", name: "Field", city: "Somewhere", country: "US", lat: 0, lon: 0, tz: "UTC")
        #expect(DetailFacts.countdown(diverted, destination: noIata, now: out) == "Diverted to KXYZ")
        #expect(DetailFacts.countdown(diverted, destination: Self.cdg, now: out) == "Diverted")
    }

    /// Review Focus 2: each side is read in its own airport's zone, never in UTC or the phone's zone.
    @Test func dayMarkerAcrossDateLine() {
        let f = Self.ua990
        // SFO 15:20 Friday to CDG 10:15 Saturday.
        #expect(DetailFacts.dayMarker(departure: f.scheduledOut!, depTz: Self.sfo.timeZone,
                                      arrival: f.scheduledIn!, arrTz: Self.cdg.timeZone) == "+1")
        // HND 00:30 Saturday 31 October to SFO 16:30 Friday 30 October: both on 30 October in UTC
        // (15:30Z and 23:30Z), yet the arrival is a local day earlier.
        let dep = date("2026-10-30T15:30:00Z"), arr = date("2026-10-30T23:30:00Z")
        #expect(DetailFacts.dayMarker(departure: dep, depTz: Self.hnd.timeZone, arrival: arr, arrTz: Self.sfo.timeZone) == "-1")
        // The same instants read in UTC would say nothing changed.
        #expect(DetailFacts.dayMarker(departure: dep, depTz: .gmt, arrival: arr, arrTz: .gmt) == nil)
        // Two days later: SFO late evening to Sydney two local dates on.
        let syd = TimeZone(identifier: "Australia/Sydney")!
        #expect(DetailFacts.dayMarker(departure: date("2026-10-30T06:30:00Z"), depTz: Self.sfo.timeZone,
                                      arrival: date("2026-10-30T21:30:00Z"), arrTz: syd) == "+2")
        // Same local date.
        #expect(DetailFacts.dayMarker(departure: date("2026-10-30T16:00:00Z"), depTz: Self.sfo.timeZone,
                                      arrival: date("2026-10-30T19:00:00Z"), arrTz: Self.oak.timeZone) == nil)
    }

    @Test func overnightOnlyWhenPositive() {
        let f = Self.ua990
        #expect(DetailFacts.isOvernight(departure: f.scheduledOut!, depTz: Self.sfo.timeZone,
                                        arrival: f.scheduledIn!, arrTz: Self.cdg.timeZone))
        let dep = date("2026-10-30T15:30:00Z"), arr = date("2026-10-30T23:30:00Z")
        #expect(!DetailFacts.isOvernight(departure: dep, depTz: Self.hnd.timeZone, arrival: arr, arrTz: Self.sfo.timeZone))
        #expect(!DetailFacts.isOvernight(departure: date("2026-10-30T16:00:00Z"), depTz: Self.sfo.timeZone,
                                         arrival: date("2026-10-30T19:00:00Z"), arrTz: Self.oak.timeZone))
    }

    @Test func middleLine() {
        let line = DetailFacts.middleLine(Self.ua990, origin: Self.sfo, destination: Self.cdg, unit: .km)
        #expect(line?.hasPrefix("10h 55m · 8,9") == true)
        #expect(line?.hasSuffix(" km · Overnight") == true)
        let miles = DetailFacts.middleLine(Self.ua990, origin: Self.sfo, destination: Self.cdg, unit: .mi)
        #expect(miles?.contains(" mi · ") == true)
        #expect(DetailFacts.middleLine(Self.ua990, origin: nil, destination: nil, unit: .km) == "10h 55m")
    }

    @Test func timeWordCases() {
        let s = date("2026-10-30T22:20:00Z")
        #expect(DetailFacts.timeWord(scheduled: s, estimated: nil, actual: nil) == "Scheduled")
        #expect(DetailFacts.timeWord(scheduled: s, estimated: s.addingTimeInterval(30), actual: nil) == "Scheduled")
        #expect(DetailFacts.timeWord(scheduled: s, estimated: s.addingTimeInterval(60), actual: nil) == "Estimated")
        #expect(DetailFacts.timeWord(scheduled: s, estimated: s.addingTimeInterval(-300), actual: nil) == "Estimated")
        #expect(DetailFacts.timeWord(scheduled: nil, estimated: s, actual: nil) == "Estimated")
        #expect(DetailFacts.timeWord(scheduled: s, estimated: s.addingTimeInterval(600), actual: s) == "Actual")
    }

    @Test func shareTextAndAirportLine() {
        #expect(DetailFacts.shareText(Self.ua990, origin: Self.sfo, destination: Self.cdg)
                == "UA 990 San Francisco to Paris, departs Fri 30 Oct 15:20 SFO")
        #expect(DetailFacts.airportLine(code: "SFO", airport: Self.sfo) == "SFO · San Francisco Intl.")
        #expect(DetailFacts.airportLine(code: "CDG", airport: Self.cdg) == "CDG · Paris Charles de Gaulle")
        #expect(DetailFacts.span(minutes: 655) == "10h 55m")
        #expect(DetailFacts.span(minutes: 125) == "2h 05m")
        #expect(DetailFacts.span(minutes: 12) == "12m")
    }

    // MARK: Store

    private func followedStore() async throws -> (FlightDetailStore, FakeFlightService, Flight) {
        let flights = FakeFlightService(now: FakeSeed.reference)
        let flight = try #require(try await flights.followed().first)
        let store = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: FakeSeed.reference))
        await store.load()
        return (store, flights, flight)
    }

    @Test func loadsDetailsOfAFollowedFlight() async throws {
        let (store, _, _) = try await followedStore()
        #expect(store.details == .empty)
    }

    @Test func savesNormalisedDetails() async throws {
        let (store, flights, flight) = try await followedStore()
        await store.saveDetails(FollowDetails(seatClass: .business, seat: " 23a ", bookingCode: "k7pq2x", notes: "  Aisle  "))
        let expected = FollowDetails(seatClass: .business, seat: "23A", bookingCode: "K7PQ2X", notes: "Aisle")
        #expect(store.details == expected)
        #expect(try await flights.followDetails(flight.id) == expected)
        #expect(store.detailsError == nil && !store.isSavingDetails)
    }

    /// Review Focus 3: a refused save puts the tiles back and says why.
    @Test func saveDetailsRollsBack() async throws {
        let (store, flights, flight) = try await followedStore()
        let first = FollowDetails(seat: "12A", bookingCode: "ABC123")
        await store.saveDetails(first)
        await flights.setNextError(.offline)
        await store.saveDetails(FollowDetails(seat: "14C", bookingCode: "ABC123"))
        #expect(store.details == first)
        #expect(store.detailsError == .offline)
        #expect(!store.isSavingDetails)
        #expect(try await flights.followDetails(flight.id) == first)
        // The next good save clears the error.
        await store.saveDetails(FollowDetails(seat: "14C", bookingCode: "ABC123"))
        #expect(store.detailsError == nil)
        #expect(store.details?.seat == "14C")
    }

    /// Review Focus 3: a value that does not normalise never reaches the server.
    @Test func invalidSeatNotSent() async throws {
        let (store, flights, flight) = try await followedStore()
        // An error queued for the next call proves no call happens: it would be consumed.
        await flights.setNextError(.offline)
        await store.saveDetails(FollowDetails(seat: "ZZ"))
        await store.saveDetails(FollowDetails(bookingCode: "AB"))
        await store.saveDetails(FollowDetails(notes: String(repeating: "a", count: 2001)))
        #expect(store.details == .empty)
        #expect(store.detailsError == nil)
        #expect(await flights.nextError == .offline)
        await flights.setNextError(nil)
        #expect(try await flights.followDetails(flight.id) == .empty)
    }

    @Test func clearingStoresNil() async throws {
        let (store, flights, flight) = try await followedStore()
        await store.saveDetails(FollowDetails(seatClass: .first, seat: "1A", bookingCode: "ABC123", notes: "Hi"))
        await store.saveDetails(FollowDetails(seatClass: .first, seat: "  ", bookingCode: "", notes: "\n"))
        let cleared = FollowDetails(seatClass: .first)
        #expect(store.details == cleared)
        #expect(try await flights.followDetails(flight.id) == cleared)
    }

    @Test func tilesHiddenWhenNotFollowed() async throws {
        let flights = FakeFlightService(now: FakeSeed.reference)
        let flight = try #require(try await flights.followed().first)
        try await flights.unfollow(flight.id)
        let store = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: FakeSeed.reference))
        await store.load()
        #expect(store.flight != nil)
        #expect(store.details == nil)
        // Nothing to save onto: the call is ignored.
        await store.saveDetails(FollowDetails(seat: "12A"))
        #expect(store.details == nil && store.detailsError == nil)
    }

    // MARK: Fix round 1

    @Test func dayMarkerOnClockChangeDays() {
        let la = Self.sfo.timeZone, paris = Self.cdg.timeZone
        let london = TimeZone(identifier: "Europe/London")!
        // US fall back, 1 November 2026: SFO 23:30 PDT Saturday to LAX 01:30 PST Sunday.
        #expect(DetailFacts.dayMarker(departure: date("2026-11-01T06:30:00Z"), depTz: la,
                                      arrival: date("2026-11-01T09:30:00Z"), arrTz: la) == "+1")
        // The repeated hour: 01:30 PDT to 01:10 PST, same local date.
        #expect(DetailFacts.dayMarker(departure: date("2026-11-01T08:30:00Z"), depTz: la,
                                      arrival: date("2026-11-01T09:10:00Z"), arrTz: la) == nil)
        // Europe falls back on 25 October 2026: CDG 23:00 CEST Saturday to LHR 00:30 BST Sunday.
        #expect(DetailFacts.dayMarker(departure: date("2026-10-24T21:00:00Z"), depTz: paris,
                                      arrival: date("2026-10-24T23:30:00Z"), arrTz: london) == "+1")
        // CDG 01:30 CEST to LHR 01:45 GMT, both Sunday.
        #expect(DetailFacts.dayMarker(departure: date("2026-10-24T23:30:00Z"), depTz: paris,
                                      arrival: date("2026-10-25T01:45:00Z"), arrTz: london) == nil)
    }

    @Test func editValidation() {
        let draft = FollowDetails(seatClass: .business)
        #expect(DetailEditModel.validated(field: .seat, text: " 23a", draft: draft)
                == .success(FollowDetails(seatClass: .business, seat: "23A")))
        #expect(DetailEditModel.validated(field: .seat, text: "ZZ", draft: draft)
                == .failure(.init("Use a row and a letter, like 23A")))
        #expect(DetailEditModel.validated(field: .bookingCode, text: "ab", draft: draft)
                == .failure(.init("Use 5 to 8 letters or digits")))
        #expect(DetailEditModel.validated(field: .bookingCode, text: "", draft: FollowDetails(bookingCode: "ABC123"))
                == .success(.empty))
        #expect(DetailEditModel.validated(field: .notes, text: String(repeating: "a", count: 2001), draft: draft)
                == .failure(.init("Use at most 2000 characters")))
    }

    @Test func pastedBookingCode() {
        #expect(DetailFacts.pastedBookingCode(" k7pq2x\n") == "K7PQ2X")
        #expect(DetailFacts.pastedBookingCode("hello world") == nil)
        #expect(DetailFacts.pastedBookingCode("") == nil)
    }

    /// The sheet's model: an offline save keeps the typed text and says why under the field, the store
    /// rolls back, and trying again stores it.
    @Test func editSheetKeepsTextWhenOffline() async throws {
        let (store, flights, flight) = try await followedStore()
        let model = DetailEditModel(field: .seat, details: store.details ?? .empty)
        model.text = "14c"
        await flights.setNextError(.offline)
        #expect(await model.save(to: store) == false)
        #expect(model.text == "14c")
        #expect(model.error == APIError.offline.message)
        #expect(store.details == .empty)
        #expect(try await flights.followDetails(flight.id) == .empty)

        #expect(await model.save(to: store))
        #expect(model.error == nil)
        #expect(store.details?.seat == "14C")
        #expect(store.detailsError == nil)
    }

    @Test func editSheetInvalidTextSendsNothing() async throws {
        let (store, flights, _) = try await followedStore()
        let model = DetailEditModel(field: .bookingCode, details: store.details ?? .empty)
        model.text = "AB"
        await flights.setNextError(.offline)
        #expect(await model.save(to: store) == false)
        #expect(model.error == DetailFacts.bookingCodeError)
        #expect(await flights.nextError == .offline)
    }

    /// Two edits close together: both are sent in order (or the older skipped) and the newer one stays.
    @Test func concurrentEditsLatestWins() async throws {
        let (store, flights, flight) = try await followedStore()
        async let first = store.saveDetails(FollowDetails(seat: "1A"))
        async let second = store.saveDetails(FollowDetails(seat: "2B"))
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(store.details == FollowDetails(seat: "2B"))
        #expect(try await flights.followDetails(flight.id) == FollowDetails(seat: "2B"))
        #expect(!store.isSavingDetails)
    }

    @Test func staleErrorClearedOnNewAttempt() async throws {
        let (store, flights, _) = try await followedStore()
        await flights.setNextError(.offline)
        await store.saveDetails(FollowDetails(seat: "3C"))
        #expect(store.detailsError == .offline)
        store.clearDetailsError()
        #expect(store.detailsError == nil)
        await flights.setNextError(.offline)
        await store.saveDetails(FollowDetails(seat: "3C"))
        #expect(store.detailsError == .offline)
        // A new attempt clears it even when nothing changed since.
        #expect(await store.saveDetails(.empty))
        #expect(store.detailsError == nil)
    }

    @Test func stopTrackingSucceeds() async throws {
        let (store, flights, flight) = try await followedStore()
        #expect(store.isFollowed)
        #expect(await store.stopTracking())
        #expect(!store.isFollowed && store.notify == nil && store.trackingError == nil)
        #expect(try await flights.followed().contains { $0.id == flight.id } == false)
    }

    @Test func stopTrackingFailureKeepsSheet() async throws {
        let (store, flights, flight) = try await followedStore()
        await flights.setNextError(.offline)
        #expect(await store.stopTracking() == false)
        #expect(store.trackingError == .offline)
        #expect(store.isFollowed)
        #expect(try await flights.followed().contains { $0.id == flight.id })
        store.clearTrackingError()
        #expect(store.trackingError == nil)
    }

    @Test func stopTrackingThroughTheShell() async throws {
        let (store, _, flight) = try await followedStore()
        var asked: [Flight.ID] = []
        #expect(await store.stopTracking(via: { id in asked.append(id); return .rateLimited }) == false)
        #expect(store.trackingError == .rateLimited && store.isFollowed)
        #expect(await store.stopTracking(via: { id in asked.append(id); return nil }))
        #expect(asked == [flight.id, flight.id])
        #expect(!store.isFollowed && store.trackingError == nil)
    }

    /// Stop Tracking follows the followed state, not the alert switch: a failed alerts fetch keeps it.
    @Test func stopTrackingGatedOnFollowed() async throws {
        let flights = FakeFlightService(now: FakeSeed.reference)
        let flight = try #require(try await flights.followed().first)
        try await flights.unfollow(flight.id)
        let store = FlightDetailStore(id: flight.id, flights: flights, airports: FakeAirportService(now: FakeSeed.reference))
        await store.load()
        #expect(!store.isFollowed)
        #expect(await store.stopTracking() == false)
        #expect(store.trackingError == nil)
    }
}
