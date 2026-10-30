import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// The home screen and lock screen widgets: the snapshot the app writes to the App Group, the wording
/// each family shows, the timeline's entry dates and the link that opens a flight.
@Suite @MainActor struct WidgetTests {
    let now = Date(timeIntervalSince1970: 1_792_770_120) // 2026-10-23T15:42:00Z

    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func flight(_ ident: String = "AF84", status: FlightStatus = .scheduled, outIn minutes: Double = 120,
                duration: Double = 600, id: UUID = UUID()) -> Flight {
        let out = at(minutes)
        return Flight(id: id, providerId: ident, ident: ident, originIcao: "LFPG", originIata: "CDG",
                      destinationIcao: "KSFO", destinationIata: "SFO",
                      scheduledOut: out, scheduledIn: out.addingTimeInterval(duration * 60),
                      gateOrigin: "K42", gateDestination: "G91", terminalOrigin: "2E", terminalDestination: "I",
                      status: status, updatedAt: now)
    }

    func widgetFlight(status: FlightStatus = .scheduled, out: Double = 120, duration: Double = 600,
                      depDelay: Int? = nil, arrDelay: Int? = nil, gate: String? = "G91") -> WidgetFlight {
        WidgetFlight(id: UUID(), ident: "AF84", airlineIcao: "AFR",
                     origin: WidgetAirport(code: "CDG", city: "Paris", timeZone: "Europe/Paris"),
                     destination: WidgetAirport(code: "SFO", city: "San Francisco", timeZone: "America/Los_Angeles"),
                     scheduledOut: at(out - Double(depDelay ?? 0)), scheduledIn: at(out + duration - Double(arrDelay ?? 0)),
                     bestOut: at(out), bestIn: at(out + duration), status: status,
                     gateOrigin: gate, gateDestination: "A7", terminalOrigin: "2E", terminalDestination: "I",
                     departureDelayMinutes: depDelay, arrivalDelayMinutes: arrDelay)
    }

    func suite() -> UserDefaults { UserDefaults(suiteName: "WidgetTests.\(UUID().uuidString)")! }

    // MARK: Snapshot from My Flights

    @Test func snapshotFromFlights() {
        var late = flight("AF84", outIn: 120)
        late.estimatedOut = late.scheduledOut!.addingTimeInterval(25 * 60)
        late.estimatedIn = late.scheduledIn!.addingTimeInterval(-4 * 60)
        late.operator = "AFR"
        let air = flight("UA1527", status: .enRoute, outIn: -60, duration: 240)
        let snap = WidgetSnapshot.from([late, air], lookup: PreviewData.airport, now: now)
        #expect(snap.version == WidgetSnapshot.currentVersion)
        #expect(snap.generatedAt == now)
        // In the air first, as My Flights lists them.
        #expect(snap.flights.map(\.ident) == ["UA1527", "AF84"])
        let f = snap.flights[1]
        #expect(f.airlineIcao == "AFR")
        #expect(f.origin.code == "CDG" && f.destination.code == "SFO")
        #expect(f.destination.city == PreviewData.airport("KSFO")?.city)
        #expect(f.destination.timeZone == PreviewData.airport("KSFO")?.tz)
        #expect(f.bestOut == late.estimatedOut && f.bestIn == late.estimatedIn)
        #expect(f.scheduledOut == late.scheduledOut)
        #expect(f.departureDelayMinutes == 25)
        #expect(f.arrivalDelayMinutes == -4)
        #expect(f.gateOrigin == "K42" && f.terminalOrigin == "2E" && f.gateDestination == "G91")
        #expect(snap.flights[0].progress == 0.25)
    }

    @Test func onlyAnEstimateMakesADelay() {
        let f = WidgetFlight.from(flight(), lookup: { _ in nil }, now: now)
        #expect(f.departureDelayMinutes == nil && f.arrivalDelayMinutes == nil)
        #expect(f.bestOut == f.scheduledOut)
        // Unknown airport: the code alone, no city or zone.
        #expect(f.origin.city == nil && f.origin.timeZone == nil && f.origin.name == "CDG")
    }

    @Test func airlineFromTheFlightNumber() {
        #expect(WidgetFlight.from(flight("AFR84"), lookup: { _ in nil }).airlineIcao == "AFR")
        #expect(WidgetFlight.from(flight("AF84"), lookup: { _ in nil }).airlineIcao == nil)
    }

    @Test func keepsTheFirstEight() {
        let list = (0..<12).map { flight("AF\($0)", outIn: Double($0) * 60 + 60) }
        let snap = WidgetSnapshot.from(list, lookup: { _ in nil }, now: now)
        #expect(snap.flights.count == WidgetSnapshot.maxFlights)
        #expect(snap.flights.first?.ident == "AF0")
    }

    // MARK: Encoding and storage

    @Test func roundTrip() throws {
        let snap = WidgetSnapshot.preview(now: now.addingTimeInterval(0.125))
        let data = try snap.encoded()
        #expect(WidgetSnapshot.decode(data) == snap)
        #expect(try snap.encoded() == data) // sorted keys: equal snapshots encode alike
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["generatedAt"] as? String == "2026-10-23T15:42:00.125Z")
        let first = try #require((obj["flights"] as? [[String: Any]])?.first)
        #expect(first["status"] as? String == "en_route")
    }

    @Test func otherVersionsAndGarbageReadAsNothing() throws {
        var snap = WidgetSnapshot.preview(now: now)
        snap.version = WidgetSnapshot.currentVersion + 1
        #expect(WidgetSnapshot.decode(try snap.encoded()) == nil)
        #expect(WidgetSnapshot.decode(Data("not json".utf8)) == nil)
        let d = suite()
        d.set(Data("{}".utf8), forKey: WidgetSnapshotStore.key)
        #expect(WidgetSnapshotStore.load(from: d).flights.isEmpty)
    }

    @Test func storeSavesAndLoads() {
        let d = suite()
        #expect(WidgetSnapshotStore.load(from: d).flights.isEmpty)
        let snap = WidgetSnapshot.preview(now: now)
        #expect(WidgetSnapshotStore.save(snap, to: d))
        #expect(WidgetSnapshotStore.load(from: d) == snap)
    }

    @Test func sameContentIgnoresTheClock() {
        let a = WidgetSnapshot.preview(now: now)
        var b = a
        b.generatedAt = now.addingTimeInterval(300)
        b.flights[0].progress = 0.5
        #expect(a.sameContent(as: b))
        b.flights[0].gateDestination = "G92"
        #expect(!a.sameContent(as: b))
    }

    @Test func flightsDropAnHourAfterArrival() {
        let landed = widgetFlight(status: .arrived, out: -300, duration: 240) // arrived an hour ago
        let soon = widgetFlight(out: 60)
        let air = widgetFlight(status: .enRoute, out: -30)
        let snap = WidgetSnapshot(generatedAt: now, flights: [soon, landed, air])
        #expect(snap.flights(at: now).map(\.id) == [air.id, soon.id])
        #expect(snap.flights(at: at(-1)).map(\.id) == [air.id, landed.id, soon.id])
    }

    // MARK: Writer

    @Test func writerSavesAndReloadsOnlyOnChange() {
        let d = suite()
        var reloads = 0
        var clock = now
        let w = WidgetSnapshotWriter(defaults: d, lookup: PreviewData.airport, reload: { reloads += 1 }, now: { clock })
        w.clear()
        #expect(reloads == 0) // nothing saved and nothing to show: no reload
        var f = flight(status: .enRoute, outIn: -60)
        w.write([f])
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore.load(from: d).flights.map(\.id) == [f.id])
        // Later, the same flight a bit further along: nothing the widgets show changed.
        clock = clock.addingTimeInterval(120)
        w.write([f])
        #expect(reloads == 1)
        f.gateDestination = "G92"
        w.write([f])
        #expect(reloads == 2)
        w.clear()
        #expect(reloads == 3)
        #expect(WidgetSnapshotStore.load(from: d).flights.isEmpty)
    }

    @Test func homeWritesTheSnapshotOnLoad() async throws {
        let d = suite()
        var reloads = 0
        let home = HomeModel(env: try await AppEnvironment.fake())
        home.attachWidgets(WidgetSnapshotWriter(defaults: d, lookup: home.env.lookup, reload: { reloads += 1 }))
        await home.load()
        let saved = WidgetSnapshotStore.load(from: d)
        #expect(!saved.flights.isEmpty)
        #expect(Set(saved.flights.map(\.id)).isSubset(of: Set(home.followed.map(\.id))))
        #expect(reloads >= 1)
    }

    /// A sign-out empties the widgets: the next account never sees the previous one's flights.
    @Test func signOutClearsTheWidgets() async throws {
        var env = try await AppEnvironment.fake()
        env.requiresSignIn = true
        let home = HomeModel(env: env)
        let d = suite()
        home.attachWidgets(WidgetSnapshotWriter(defaults: d, lookup: env.lookup, reload: {}))
        home.session.startIfNeeded()
        for _ in 0..<200 where !home.session.isResolved { try? await Task.sleep(for: .milliseconds(10)) }
        try await env.auth.signInWithApple(idToken: "t", nonce: "n")
        for _ in 0..<200 where home.owner == nil { try? await Task.sleep(for: .milliseconds(10)) }
        await home.start()
        #expect(!WidgetSnapshotStore.load(from: d).flights.isEmpty)
        await home.session.signOut()
        for _ in 0..<200 where !WidgetSnapshotStore.load(from: d).flights.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(WidgetSnapshotStore.load(from: d).flights.isEmpty)
    }

    // MARK: Link

    @Test func flightLink() {
        let id = UUID()
        let url = FlightLink.url(for: id)
        #expect(url.absoluteString == "somaflight://flight/\(id.uuidString.lowercased())")
        #expect(FlightLink.flightID(from: url) == id)
        #expect(FlightLink.flightID(from: URL(string: "somaflight://auth-callback?code=abc")!) == nil)
        #expect(FlightLink.flightID(from: URL(string: "somaflight://flight/not-a-uuid")!) == nil)
        #expect(FlightLink.flightID(from: URL(string: "https://flight/\(id.uuidString)")!) == nil)
    }

    // MARK: Display

    @Test func countdownLikeMyFlights() {
        let f = widgetFlight(out: 26 * 60)
        func c(_ minutes: Double) -> String {
            let x = FlightWidgetDisplay(f, at: at(minutes)).countdown
            return [x.value, x.unit].filter { !$0.isEmpty }.joined(separator: " ")
        }
        #expect(c(0) == "1 DAY")
        #expect(c(2 * 60 + 1) == "23 HRS")
        #expect(c(25 * 60) == "1 HR")
        #expect(c(25 * 60 + 20) == "40 MIN")
        #expect(c(26 * 60 - 0.5) == "DEPARTING")
        let air = widgetFlight(status: .enRoute, out: -60, duration: 200)
        #expect(FlightWidgetDisplay(air, at: now).countdown == ("2h", "LEFT"))
        #expect(FlightWidgetDisplay(air, at: at(100)).countdown == ("40m", "LEFT"))
        #expect(FlightWidgetDisplay(air, at: at(140)).countdown == ("", "ARRIVING"))
        #expect(FlightWidgetDisplay(air, at: now).shortCountdown == "2h")
        #expect(FlightWidgetDisplay(f, at: now).shortCountdown == "1d")
        #expect(FlightWidgetDisplay(widgetFlight(status: .canceled), at: now).shortCountdown == nil)
    }

    @Test func inlineLine() {
        let late = widgetFlight(out: 90, depDelay: 25)
        #expect(FlightWidgetDisplay(late, at: now).inlineText == "AF 84 · Gate G91 · 25m late")
        // In the air: the arrival gate and the arrival's offset.
        let air = widgetFlight(status: .enRoute, out: -60, depDelay: 10, arrDelay: -5)
        #expect(FlightWidgetDisplay(air, at: now).inlineText == "AF 84 · Gate A7 · 5m early")
        #expect(FlightWidgetDisplay(widgetFlight(gate: nil), at: now).inlineText == "AF 84")
        #expect(FlightWidgetDisplay(widgetFlight(depDelay: 0, gate: nil), at: now).inlineText == "AF 84 · on time")
        #expect(FlightWidgetDisplay(widgetFlight(status: .canceled), at: now).inlineText == "AF 84 · Gate G91 · Canceled")
    }

    @Test func statusLinesAndTones() {
        let late = FlightWidgetDisplay(widgetFlight(out: 90, depDelay: 25), at: now)
        #expect(late.statusLine == "Departs \(late.departureTime) · 25m Late")
        #expect(late.departureTone == .late && late.headlineTone == .late)
        #expect(late.headlineTime == late.departureTime)
        #expect(late.scheduledDeparture != nil)
        #expect(late.gate == "G91" && late.terminal == "2E")
        #expect(late.routeCodes == "CDG → SFO" && late.routeCities == "Paris to San Francisco")

        let air = FlightWidgetDisplay(widgetFlight(status: .enRoute, out: -60, duration: 200, arrDelay: -3), at: now)
        #expect(air.statusLine == "Arrives \(air.arrivalTime) · 2h left")
        #expect(air.headlineTime == air.arrivalTime && air.headlineTone == .onTime)
        #expect(air.gate == "A7" && air.terminal == "I")
        #expect(abs(air.progress - 0.3) < 0.001)

        let plain = FlightWidgetDisplay(widgetFlight(), at: now)
        #expect(plain.statusLine == "Departs \(plain.departureTime) · Scheduled")
        #expect(plain.departureTone == .neutral && plain.scheduledDeparture == nil)
        #expect(FlightWidgetDisplay(widgetFlight(status: .landed, out: -300, duration: 240), at: now).statusLine
                .hasPrefix("Landed "))
        #expect(FlightWidgetDisplay.offsetWord(65) == "1h 5m Late")
    }

    @Test func clockSetting() {
        let f = widgetFlight(out: 0) // 15:42Z is 17:42 in Paris
        #expect(FlightWidgetDisplay(f, at: now).departureTime == "17:42")
        #expect(FlightWidgetDisplay(f, at: now, twelveHour: true).departureTime == "5:42 PM")
    }

    // MARK: Timeline

    @Test func entriesAtTheMomentsThatChange() {
        let f = widgetFlight(out: 3 * 60 + 30, duration: 600)
        let snap = WidgetSnapshot(generatedAt: now, flights: [f])
        let dates = WidgetTimeline.entryDates(for: snap, now: now)
        #expect(dates.first == now)
        #expect(dates == dates.sorted() && Set(dates).count == dates.count)
        #expect(dates.allSatisfy { $0 <= now.addingTimeInterval(WidgetTimeline.horizon) })
        let out = f.bestOut!
        func mark(_ seconds: Double) -> Date { out.addingTimeInterval(-seconds + 1) }
        // Just past each hour mark under a day and each minute mark in the last hour, and the departure.
        #expect(dates.contains(mark(3 * 3600)))
        #expect(dates.contains(mark(3600)))
        #expect(dates.contains(mark(40 * 60)))
        #expect(dates.contains(mark(60)))
        #expect(dates.contains(out))
        #expect(!dates.contains(f.bestIn!)) // 13h30 away, past the 12 hour horizon
        // Nothing between two minute marks, nor between two hour marks.
        #expect(!dates.contains(mark(90 * 60)))
        #expect(dates.filter { $0 > mark(41 * 60) && $0 < mark(40 * 60) }.isEmpty)
        #expect(FlightWidgetDisplay(f, at: mark(3 * 3600)).countdown == ("2", "HRS"))
        // Every entry changes what a widget shows.
        for (a, b) in zip(dates, dates.dropFirst()) {
            let x = FlightWidgetDisplay(f, at: a), y = FlightWidgetDisplay(f, at: b)
            #expect(x.countdown != y.countdown || a < out && b >= out, "\(a) to \(b)")
        }
        #expect(WidgetTimeline.reloadDate(for: snap, entries: dates, now: now) == dates.last)
    }

    @Test func inTheAirTheProgressMoves() {
        let f = widgetFlight(status: .enRoute, out: -60, duration: 180)
        let dates = WidgetTimeline.entryDates(for: WidgetSnapshot(generatedAt: now, flights: [f]), now: now)
        let inn = f.bestIn!
        #expect(dates.contains(now.addingTimeInterval(WidgetTimeline.progressStep)))
        #expect(dates.contains(inn.addingTimeInterval(-3600 + 1)))
        #expect(dates.contains(inn.addingTimeInterval(-60 + 1)))
        #expect(dates.contains(inn))
        #expect(dates.contains(inn.addingTimeInterval(3600))) // drops off
        #expect(dates.last == inn.addingTimeInterval(3600))
    }

    @Test func entriesAreCappedAndEmptyNeverReloads() {
        let many = (0..<4).map { i in widgetFlight(status: i == 0 ? .enRoute : .scheduled, out: Double(i) * 45 + 5) }
        let snap = WidgetSnapshot(generatedAt: now, flights: many)
        let dates = WidgetTimeline.entryDates(for: snap, now: now)
        #expect(dates.count == WidgetTimeline.maxEntries)
        #expect(WidgetTimeline.reloadDate(for: snap, entries: dates, now: now) == dates.last)

        let empty = WidgetSnapshot.empty(at: now)
        #expect(WidgetTimeline.entryDates(for: empty, now: now) == [now])
        #expect(WidgetTimeline.reloadDate(for: empty, entries: [now], now: now) == nil)

        // A flight far off: no change within the horizon, the timeline asks again at its end.
        let far = WidgetSnapshot(generatedAt: now, flights: [widgetFlight(out: 3 * 24 * 60 + 13 * 60)])
        let farDates = WidgetTimeline.entryDates(for: far, now: now)
        #expect(farDates == [now])
        #expect(WidgetTimeline.reloadDate(for: far, entries: farDates, now: now) == now.addingTimeInterval(WidgetTimeline.horizon))
    }

    // MARK: Palette

    @Test func widgetColoursMatchTheApp() {
        var env = EnvironmentValues()
        env.colorScheme = .dark
        for (a, b) in [(ActivityPalette.gate, GateBadge.yellow), (ActivityPalette.pill, Theme.pill)] {
            let x = a.resolve(in: env), y = b.resolve(in: env)
            #expect(abs(x.red - y.red) < 0.01 && abs(x.green - y.green) < 0.01 && abs(x.blue - y.blue) < 0.01)
        }
    }
}
