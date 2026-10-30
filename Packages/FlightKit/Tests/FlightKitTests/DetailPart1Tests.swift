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
}
