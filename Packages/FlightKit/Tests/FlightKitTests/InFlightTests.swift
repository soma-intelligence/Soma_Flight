import CoreLocation
import FlightActivityKit
import Foundation
import Testing
@testable import FlightKit

/// Offline and in-flight mode: the on-device estimate (`FlightEstimate`), its plane on the globe, the Live
/// Activity moving on by time, and Text Me Too (`TextAlertsStore`, the flight switch, `sms-verify` answers).
@MainActor @Suite struct InFlightTests {
    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-03T14:00:00Z")!
    let sfo = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.379)
    let cdg = CLLocationCoordinate2D(latitude: 49.0097, longitude: 2.5479)

    /// AF 84 CDG to SFO: left 10:00, due 21:00, last heard at `updated`.
    func flight(status: FlightStatus = .enRoute, updated: Date = now.addingTimeInterval(-3600),
                out: TimeInterval = -4 * 3600, inn: TimeInterval = 7 * 3600) -> Flight {
        Flight(providerId: "AF84", ident: "AF84", originIcao: "LFPG", destinationIcao: "KSFO",
               scheduledOut: Self.now.addingTimeInterval(out), scheduledIn: Self.now.addingTimeInterval(inn),
               actualOut: status == .scheduled ? nil : Self.now.addingTimeInterval(out),
               status: status, updatedAt: updated)
    }

    // MARK: Estimate

    @Test func aStaleFlightInTheAirIsEstimatedFromItsTimes() throws {
        let e = try #require(FlightEstimate.make(for: flight(), origin: cdg, destination: sfo, online: true, now: Self.now))
        #expect(e.reason == .stale)
        #expect(abs(e.progress - 4.0 / 11.0) < 1e-6)
        #expect(e.lastUpdate == Self.now.addingTimeInterval(-3600))
        #expect(!e.probablyLanded)
        // On the great circle, placed by `RouteEstimator` (taxi, climb, cruise): over the North Atlantic, heading west.
        let c = try #require(e.coordinate)
        let route = try #require(RouteEstimator(flight: flight(), origin: cdg, destination: sfo))
        #expect(RouteEstimator.distanceKm(c, route.position(at: Self.now).coordinate) < 0.01)
        #expect(e.phase == .cruise)
        #expect(abs(distanceKm(cdg, c) - distanceKm(cdg, sfo) * 4 / 11) < 200)
        #expect(c.latitude > 50 && c.longitude < -20)
        #expect(try #require(e.heading) > 240 && e.heading! < 340)
    }

    @Test func aFreshFlightOnlineIsLive() {
        let fresh = flight(updated: Self.now.addingTimeInterval(-120))
        #expect(FlightEstimate.make(for: fresh, origin: cdg, destination: sfo, online: true, now: Self.now) == nil)
        // The same flight offline is an estimate at once.
        #expect(FlightEstimate.make(for: fresh, origin: cdg, destination: sfo, online: false, now: Self.now)?.reason == .offline)
    }

    @Test func offlineAFlightPastItsDepartureIsProbablyFlying() throws {
        let leftOnPaper = flight(status: .scheduled, updated: Self.now.addingTimeInterval(-5 * 3600))
        let e = try #require(FlightEstimate.make(for: leftOnPaper, origin: cdg, destination: sfo, online: false, now: Self.now))
        #expect(e.progress > 0.3)
        // Online, the backend would have said: no guess.
        #expect(FlightEstimate.make(for: leftOnPaper, origin: cdg, destination: sfo, online: true, now: Self.now) == nil)
        // Not yet due to leave: nothing to estimate.
        let later = flight(status: .scheduled, out: 3600, inn: 12 * 3600)
        #expect(FlightEstimate.make(for: later, origin: cdg, destination: sfo, online: false, now: Self.now) == nil)
    }

    @Test func finishedFlightsAreNeverEstimated() {
        for status in [FlightStatus.landed, .arrived, .canceled, .diverted] {
            #expect(FlightEstimate.make(for: flight(status: status), origin: cdg, destination: sfo, online: false,
                                        now: Self.now) == nil)
        }
    }

    @Test func pastItsArrivalTheEstimateSaysProbablyLanded() throws {
        let late = Self.now.addingTimeInterval(8 * 3600)
        let e = try #require(FlightEstimate.make(for: flight(), origin: cdg, destination: sfo, online: false, now: late))
        #expect(e.probablyLanded)
        #expect(e.progress == 1)
        #expect(e.detail.hasPrefix("Probably landed"))
    }

    @Test func withoutAnAirportThereIsProgressButNoPlace() throws {
        let e = try #require(FlightEstimate.make(for: flight(), origin: nil, destination: sfo, online: false, now: Self.now))
        #expect(e.coordinate == nil)
        #expect(e.progress > 0)
    }

    @Test func theLabelNamesTheLastUpdate() {
        let e = FlightEstimate(reason: .offline, progress: 0.5, coordinate: nil, heading: nil,
                               lastUpdate: ISO8601DateFormatter().date(from: "2026-11-03T14:02:00Z")!, probablyLanded: false)
        #expect(e.label(timeZone: .gmt) == "Estimated, last update 14:02")
    }

    @Test func acrossTheAntimeridianThePlaneStaysOnTheMap() throws {
        let hnd = CLLocationCoordinate2D(latitude: 35.5494, longitude: 139.7798)
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let (c, h) = FlightEstimate.point(from: hnd, to: sfo, at: p)
            #expect(c.longitude >= -180 && c.longitude <= 180)
            #expect(h >= 0 && h < 360)
        }
    }

    // MARK: Globe

    @Test func theGlobeDrawsAnEstimatedPlaneOnTheArc() throws {
        let lookup: (String) -> Airport? = { PreviewData.airport($0) }
        let f = flight()
        let live = GlobeContent.followed([f], lookup: lookup, online: true, now: f.updatedAt)
        #expect(live.planes.allSatisfy { !$0.isEstimated })
        let estimated = GlobeContent.followed([f], lookup: lookup, online: false, now: Self.now)
        if lookup("LFPG") != nil, lookup("KSFO") != nil {
            let plane = try #require(estimated.planes.first)
            #expect(plane.isEstimated)
            #expect(plane.id == f.id)
        }
    }

    // MARK: Live Activity

    @Test func theLiveActivityMovesOnByTimeInTheAir() {
        let out = Self.now.addingTimeInterval(-3600), inn = Self.now.addingTimeInterval(3600)
        let attrs = FlightActivityAttributes(flightId: UUID(), ident: "AF84", originIata: "CDG", destinationIata: "SFO",
                                             scheduledOut: out, scheduledIn: inn)
        let state = FlightActivityAttributes.ContentState(status: .enRoute, estimatedOut: out, estimatedIn: inn, progress: 0.1)
        #expect(FlightActivityDisplay(attrs, state).progress == 0.1)
        #expect(abs(FlightActivityDisplay(attrs, state, now: Self.now).progress - 0.5) < 1e-9)
        // Never backwards: a pushed state ahead of the clock wins.
        let ahead = FlightActivityAttributes.ContentState(status: .enRoute, estimatedOut: out, estimatedIn: inn, progress: 0.8)
        #expect(FlightActivityDisplay(attrs, ahead, now: Self.now).progress == 0.8)
        // Before take-off the bar stays empty whatever the clock says.
        let parked = FlightActivityAttributes.ContentState(status: .scheduled, estimatedOut: out, estimatedIn: inn)
        #expect(FlightActivityDisplay(attrs, parked, now: Self.now).progress == 0)
    }

    // MARK: Text Me Too

    @Test func textMeTooWalksFromNumberToCodeToSwitches() async {
        let service = FakeTextAlertsService()
        let store = TextAlertsStore(service: service)
        await store.load()
        #expect(store.step == .number)
        store.phoneDraft = "(415) 555-0100"
        await store.sendCode()
        #expect(store.step == .code)
        store.codeDraft = "000000"
        await store.checkCode()
        #expect(store.codeResult == .wrong)
        #expect(store.codeMessage == "That code is not right. 4 tries left.")
        store.codeDraft = FakeTextAlertsService.code
        await store.checkCode()
        #expect(store.step == .verified)
        #expect(store.status.enabled)
        await store.setInFlight(true)
        #expect(store.status.inFlight)
        await store.forget()
        #expect(store.step == .number)
        #expect(store.status.phone == nil)
    }

    @Test func textsOffOnTheServerShowAsComingSoon() async {
        let store = TextAlertsStore(service: UnavailableTextAlertsService())
        await store.load()
        #expect(store.step == .unavailable)
    }

    @Test func aRefusalShowsTheServersWords() async {
        let service = FakeTextAlertsService()
        await service.setNextError(.refused("This number is already used by another account"))
        let store = TextAlertsStore(service: service)
        store.phoneDraft = "+14155550100"
        await store.sendCode()
        #expect(store.error?.message == "This number is already used by another account")
    }

    @Test func theFlightSwitchOverridesTheAccountAndFallsBackToIt() async {
        let id = UUID()
        let service = FakeTextAlertsService(TextAlertsStatus(available: true, phone: "+14155550100", verified: true,
                                                             enabled: true, inFlight: false))
        let model = FlightTextsModel(flight: id, service: service)
        await model.load()
        #expect(model.isShown)
        #expect(!model.isOn)
        await model.set(true)
        #expect(model.isOn)
        #expect(await service.flights[id] == true)
        // Back to the account's own setting: the flight's switch is cleared, not copied.
        await model.set(false)
        #expect(!model.isOn)
        #expect(await service.flights[id] == nil)
    }

    @Test func theFlightSwitchHidesWithoutAVerifiedNumber() async {
        let model = FlightTextsModel(flight: UUID(), service: FakeTextAlertsService())
        await model.load()
        #expect(!model.isShown)
    }

    @Test func smsVerifyAnswersDecode() throws {
        let status = try FlightJSON.decoder.decode(TextAlertsStatus.self, from: Data(#"""
        {"available":true,"phone":"+14155550100","pending":false,"verified":true,"enabled":true,"inFlight":false,
         "optedOut":false,"flightInFlight":null,"result":"ok","triesLeft":5}
        """#.utf8))
        #expect(status.reachable && status.enabled && status.flightInFlight == nil)
        let checked = try FlightJSON.decoder.decode(SupabaseTextAlertsService.Checked.self, from: Data(#"{"result":"wrong","triesLeft":3}"#.utf8))
        #expect(checked.result == .wrong && checked.triesLeft == 3)
        let refusal = SupabaseTextAlertsService.error(status: 409, body: Data(
            #"{"error":{"code":"invalid_request","message":"Verify your number first"}}"#.utf8))
        #expect(refusal == .refused("Verify your number first"))
        #expect(SupabaseTextAlertsService.error(status: 503, body: Data(
            #"{"error":{"code":"provider_unavailable","message":"Texts are not available yet"}}"#.utf8)) == .unavailable)
    }
}
