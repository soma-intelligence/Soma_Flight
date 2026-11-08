import CoreLocation
import Foundation
import Testing
@testable import FlightKit

/// Landmarks overflown: the bundled table, the passes along an estimated route with their side, the
/// "Along the way" card's words and the optional in-flight alerts.
@Suite @MainActor struct LandmarksTests {
    nonisolated static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    nonisolated static let lookup = AirportDirectory.bundled()

    func route(_ a: String, _ b: String, _ off: String, _ on: String) throws -> RouteEstimator {
        let o = try #require(Self.lookup.airport(a)), d = try #require(Self.lookup.airport(b))
        return try #require(RouteEstimator(origin: o.coordinate, destination: d.coordinate,
                                           takeoff: Self.date(off), landing: Self.date(on)))
    }

    static func flight(_ from: String, _ to: String, out: String, minutes: Double,
                       id: UUID = UUID(uuidString: "6a1f0c8e-2b7d-4f3a-9c1e-5d8b7a6f4e21")!) -> Flight {
        Flight(id: id, providerId: "TEST-\(from)-\(to)", ident: "LX318", originIcao: from, destinationIcao: to,
               scheduledOut: date(out), scheduledIn: date(out).addingTimeInterval(minutes * 60), status: .scheduled)
    }

    // MARK: Table

    @Test func theTableIsBundledWithItsSourceAndSaneValues() throws {
        let t = LandmarkTable.bundled
        #expect(t.landmarks.count >= 300 && t.landmarks.count <= 500)
        #expect(Set(t.landmarks.map(\.name)).count == t.landmarks.count)
        for l in t.landmarks {
            #expect(abs(l.lat) <= 90 && abs(l.lon) <= 180, "\(l.name)")
            #expect(l.radiusKm >= 20 && l.radiusKm <= 250, "\(l.name)")
            #expect(!l.name.isEmpty)
        }
        let mb = try #require(t.named("Mont Blanc"))
        #expect(mb.kind == .mountain && abs(mb.lat - 45.83) < 0.05 && abs(mb.lon - 6.86) < 0.05)
        #expect(t.named("Grand Canyon")?.kind == .canyon)
        // The source and licence travel with the data.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/FlightKit/Resources/Reference/landmarks.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((json["license"] as? String) == "CC0-1.0")
        #expect((json["source"] as? String)?.contains("Wikidata") == true)
    }

    // MARK: Side

    @Test func sideComesFromTheBearingAgainstTheHeading() {
        #expect(WindowSide.of(bearing: 270, heading: 0) == .left)
        #expect(WindowSide.of(bearing: 90, heading: 0) == .right)
        #expect(WindowSide.of(bearing: 10, heading: 350) == .right)
        #expect(WindowSide.of(bearing: 340, heading: 10) == .left)
        #expect(WindowSide.of(bearing: 185, heading: 0, deadZone: 20) == .below)
        let here = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // Flying north, a point to the west is on the left, one to the east on the right.
        #expect(WindowSide.of(CLLocationCoordinate2D(latitude: 0, longitude: -0.5), from: here, heading: 0) == .left)
        #expect(WindowSide.of(CLLocationCoordinate2D(latitude: 0, longitude: 0.5), from: here, heading: 0) == .right)
        // Flying west, north is on the right.
        #expect(WindowSide.of(CLLocationCoordinate2D(latitude: 0.5, longitude: 0), from: here, heading: 270) == .right)
        // Right under the plane.
        #expect(WindowSide.of(CLLocationCoordinate2D(latitude: 0.03, longitude: 0), from: here, heading: 90) == .below)
    }

    // MARK: Passes

    @Test func genevaToLondonPassesMontBlanc() throws {
        let passes = Landmarks.passes(for: try route("LSGG", "EGLL", "2026-07-01T09:00:00Z", "2026-07-01T10:20:00Z"))
        let mb = try #require(passes.first { $0.landmark.name == "Mont Blanc" })
        #expect(mb.isVisible && mb.inDaylight)
        #expect(mb.distanceKm <= 80)
        #expect(mb.fraction < 0.2)
        // The trip's own cities are no sight.
        #expect(!passes.contains { $0.landmark.name == "London" })
        #expect(passes == passes.sorted { $0.time < $1.time })
    }

    @Test func milanToLondonCrossesTheAlpsWithPeaksOnASide() throws {
        let passes = Landmarks.passes(for: try route("LIMC", "EGLL", "2026-07-01T09:00:00Z", "2026-07-01T11:00:00Z"))
        let alps = passes.filter { ["Matterhorn", "Dufourspitze", "Weisshorn", "Dom", "Eiger",
                                    "Jungfrau", "Finsteraarhorn"].contains($0.landmark.name) }
        #expect(alps.count >= 2, "\(passes.map(\.landmark.name))")
        // Out of Milan north-west: the Valais peaks to the south-west on the left, the Bernese Oberland on the right.
        #expect(passes.first { $0.landmark.name == "Matterhorn" }?.side == .left)
        #expect(passes.first { $0.landmark.name == "Eiger" }?.side == .right)
        // Mont Blanc stays out of sight, some 90 km off the direct route.
        #expect(!passes.contains { $0.landmark.name == "Mont Blanc" })
    }

    @Test func anOceanCrossingListsNothingMidOcean() throws {
        // Los Angeles to Honolulu: the cities at each end, open sea between.
        let lax = Landmarks.passes(for: try route("KLAX", "PHNL", "2026-07-01T17:00:00Z", "2026-07-01T22:30:00Z"))
        #expect(lax.allSatisfy { $0.fraction < 0.15 || $0.fraction > 0.85 }, "\(lax.map { ($0.landmark.name, $0.fraction) })")
        // New York to London: nothing over the open Atlantic.
        let jfk = Landmarks.passes(for: try route("KJFK", "EGLL", "2026-07-01T23:00:00Z", "2026-07-02T06:00:00Z"))
        #expect(jfk.allSatisfy { $0.fraction < 0.35 || $0.fraction > 0.85 }, "\(jfk.map { ($0.landmark.name, $0.fraction) })")
    }

    @Test func atNightOnlyCitiesAreWorthALook() throws {
        // Geneva to London at 01:00 local: Mont Blanc in the dark, London's lights still show.
        let passes = Landmarks.passes(for: try route("LSGG", "EGLL", "2026-01-15T00:00:00Z", "2026-01-15T01:20:00Z"))
        let mb = try #require(passes.first { $0.landmark.name == "Mont Blanc" })
        #expect(!mb.isVisible)
        #expect(LandmarkFacts.shown(passes).allSatisfy { $0.landmark.kind == .city })
    }

    // MARK: Card

    @Test func theCardSaysSideAndLocalTime() throws {
        let gva = try #require(Self.lookup.airport("LSGG")), lhr = try #require(Self.lookup.airport("EGLL"))
        let f = Self.flight("LSGG", "EGLL", out: "2026-07-01T08:45:00Z", minutes: 100)
        let passes = Landmarks.passes(f, origin: gva, destination: lhr)
        let lines = LandmarkFacts.lines(passes, origin: gva, destination: lhr, clock: .h24)
        let mb = try #require(lines.first { $0.text.hasPrefix("Mont Blanc") })
        #expect(mb.text.wholeMatch(of: /Mont Blanc on the (left|right) at \d\d:\d\d Geneva time/) != nil, "\(mb.text)")
        #expect(lines.count <= LandmarkFacts.maxLines)
        // Canceled: no card.
        var canceled = f
        canceled.status = .canceled
        #expect(Landmarks.passes(canceled, origin: gva, destination: lhr).isEmpty)
    }

    @Test func theCardKeepsTheEightMostNotable() {
        let t0 = Self.date("2026-07-01T09:00:00Z")
        var passes: [LandmarkPass] = []
        for i in 0..<12 {
            let kind: Landmark.Kind = i % 3 == 0 ? .mountain : .city
            let place = Landmark(name: "Place \(i)", kind: kind, lat: 0, lon: 0, radiusKm: 40)
            let time = t0.addingTimeInterval(Double(i) * 600)
            passes.append(LandmarkPass(landmark: place, time: time, distanceKm: Double(i), side: .left,
                                       fraction: Double(i) / 12, altitudeM: 11_000, inDaylight: true))
        }
        let shown = LandmarkFacts.shown(passes)
        #expect(shown.count == 8)
        #expect(shown.filter { $0.landmark.kind == Landmark.Kind.mountain }.count == 4)
        #expect(shown == shown.sorted { $0.time < $1.time })
    }

    // MARK: Alerts

    @Test func alertsArePlannedAheadFromTheEstimate() throws {
        let mxp = try #require(Self.lookup.airport("LIMC")), lhr = try #require(Self.lookup.airport("EGLL"))
        let f = Self.flight("LIMC", "EGLL", out: "2026-07-01T08:45:00Z", minutes: 120)
        let now = Self.date("2026-07-01T06:00:00Z")
        let plan = LandmarkAlerts.plan(for: f, origin: mxp, destination: lhr, now: now)
        #expect(!plan.isEmpty && plan.count <= LandmarkAlerts.maxPerFlight)
        #expect(plan.allSatisfy { $0.kind == .landmark && $0.fireDate > now && $0.id.hasPrefix("reminder.") })
        #expect(Set(plan.map(\.id)).count == plan.count)
        #expect(plan == plan.sorted { $0.fireDate < $1.fireDate })
        let first = try #require(plan.first)
        #expect(first.body.hasPrefix("In about 5 minutes,"))
        #expect(first.title.contains(" on the ") || first.title.hasSuffix(" below"))

        // A later departure moves every alert by the same delay.
        var late = f
        late.estimatedOut = f.scheduledOut!.addingTimeInterval(40 * 60)
        late.estimatedIn = f.scheduledIn!.addingTimeInterval(40 * 60)
        let moved = LandmarkAlerts.plan(for: late, origin: mxp, destination: lhr, now: now)
        #expect(moved.map(\.title) == plan.map(\.title))
        #expect(zip(moved, plan).allSatisfy { abs($0.fireDate.timeIntervalSince($1.fireDate) - 2400) < 1 })

        // Too far ahead, canceled or landed: none.
        #expect(LandmarkAlerts.plan(for: f, origin: mxp, destination: lhr,
                                    now: Self.date("2026-06-27T00:00:00Z")).isEmpty)
        var canceled = f
        canceled.status = .canceled
        #expect(LandmarkAlerts.plan(for: canceled, origin: mxp, destination: lhr, now: now).isEmpty)
    }

    @Test func alertsAreOffByDefaultAndTheSwitchTurnsThemOn() async throws {
        let suite = "landmarks.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LandmarkAlertSettings.isOn(defaults))

        let lookup: @Sendable (String) -> Airport? = { Self.lookup.airport($0) }
        let center = FakeLocalNotificationCenter()
        let s = ReminderScheduler(center: center, lookup: lookup, now: { Self.date("2026-07-01T06:00:00Z") },
                                  clock: { .h24 })
        s.landmarkAlerts = { LandmarkAlertSettings.isOn(defaults) }
        let f = Self.flight("LIMC", "EGLL", out: "2026-07-01T08:45:00Z", minutes: 120)
        await s.sync([f])
        #expect(!center.pending.values.contains { $0.kind == .landmark })
        let base = center.pending.count

        // The Notifications screen's switch saves on this device and re-plans.
        let store = NotificationSettingsStore(service: FakeNotificationPreferencesService(), defaults: defaults)
        #expect(!store.landmarkAlerts)
        var heard: [Bool] = []
        store.onLandmarksChange = { heard.append($0); s.resync() }
        store.setLandmarkAlerts(true)
        #expect(heard == [true])
        #expect(defaults.bool(forKey: LandmarkAlertSettings.key))
        await s.sync([f])
        let landmarks = center.pending.values.filter { $0.kind == .landmark }
        #expect(!landmarks.isEmpty)
        #expect(center.pending.count == base + landmarks.count)

        // Reminders off leaves the landmark alerts to their own switch.
        s.enabled = false
        await s.sync([f])
        #expect(center.pending.values.allSatisfy { $0.kind == .landmark })

        store.setLandmarkAlerts(false)
        await s.sync([f])
        #expect(center.pending.isEmpty)
    }

    @Test func everythingPendingStaysUnderTheSystemLimit() async throws {
        let lookup: @Sendable (String) -> Airport? = { Self.lookup.airport($0) }
        let center = FakeLocalNotificationCenter()
        let s = ReminderScheduler(center: center, lookup: lookup, now: { Self.date("2026-07-01T06:00:00Z") },
                                  clock: { .h24 })
        // A few flights: every reminder and every alert fits.
        let few = (0..<2).map { i in
            Self.flight("LIMC", "EGLL", out: "2026-07-01T0\(8 + i):45:00Z", minutes: 120, id: UUID())
        }
        s.landmarkAlerts = { false }
        await s.sync(few)
        let remindersOnly = center.pending.count
        s.landmarkAlerts = { true }
        await s.sync(few)
        #expect(center.pending.count > remindersOnly)
        #expect(center.pending.count <= ReminderScheduler.pendingLimit)

        // Many flights within the alerts' horizon: the alerts get what room is left, the earliest first.
        var many: [Flight] = []
        for h in 0..<40 {
            let out = Self.date("2026-07-01T07:00:00Z").addingTimeInterval(Double(h) * 3600)
            var f = Self.flight("LIMC", "EGLL", out: "2026-07-01T08:45:00Z", minutes: 120)
            f.id = UUID()
            f.scheduledOut = out
            f.scheduledIn = out.addingTimeInterval(7200)
            many.append(f)
        }
        await s.sync(many)
        let pending = Array(center.pending.values)
        #expect(pending.count == ReminderScheduler.pendingLimit)
        let alerts = pending.filter { $0.kind == .landmark }
        let reminders = pending.filter { $0.kind != .landmark }
        #expect(reminders.count + alerts.count == ReminderScheduler.pendingLimit)
        // The alerts kept are the earliest ones planned.
        let all = many.flatMap {
            LandmarkAlerts.plan(for: $0, origin: lookup($0.originIcao), destination: lookup($0.destinationIcao),
                                now: Self.date("2026-07-01T06:00:00Z"))
        }.sorted { $0.fireDate < $1.fireDate }
        if let latestKept = alerts.map(\.fireDate).max(), alerts.count < all.count {
            #expect(all[alerts.count].fireDate >= latestKept)
        }
    }
}
