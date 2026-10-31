import Foundation
import Testing
@testable import FlightKit
@testable import FlightWatchKit

/// The Apple Watch: the snapshot the phone sends over WatchConnectivity (its encoding, the barcode's
/// modules, the sender's skips), the watch's models (list, flight screen, the snapshot it keeps) and the
/// complications' Smart Stack relevance.
@Suite @MainActor struct WatchTests {
    let now = Date(timeIntervalSince1970: 1_792_770_120) // 2026-10-23T15:42:00Z

    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func flight(_ ident: String = "AF84", status: FlightStatus = .scheduled, outIn minutes: Double = 120,
                duration: Double = 600, belt: String? = nil, id: UUID = UUID()) -> Flight {
        let out = at(minutes)
        return Flight(id: id, providerId: ident, ident: ident, originIcao: "LFPG", originIata: "CDG",
                      destinationIcao: "KSFO", destinationIata: "SFO",
                      scheduledOut: out, scheduledIn: out.addingTimeInterval(duration * 60),
                      gateOrigin: "K42", gateDestination: "G91", terminalOrigin: "2E", terminalDestination: "I",
                      baggageBelt: belt, status: status, updatedAt: now)
    }

    func widgetFlight(status: FlightStatus = .scheduled, out: Double = 120, duration: Double = 600,
                      depDelay: Int? = nil, arrDelay: Int? = nil, id: UUID = UUID()) -> WidgetFlight {
        WidgetFlight(id: id, ident: "AF84", airlineIcao: "AFR",
                     origin: WidgetAirport(code: "CDG", city: "Paris", timeZone: "Europe/Paris"),
                     destination: WidgetAirport(code: "SFO", city: "San Francisco", timeZone: "America/Los_Angeles"),
                     scheduledOut: at(out - Double(depDelay ?? 0)), scheduledIn: at(out + duration - Double(arrDelay ?? 0)),
                     bestOut: at(out), bestIn: at(out + duration), status: status,
                     gateOrigin: "K42", gateDestination: "G91", terminalOrigin: "2E", terminalDestination: "I",
                     departureDelayMinutes: depDelay, arrivalDelayMinutes: arrDelay)
    }

    func snapshot(_ flights: [WidgetFlight], extras: [WatchFlightExtras] = []) -> WatchSnapshot {
        WatchSnapshot(flights: WidgetSnapshot(generatedAt: now, flights: flights), extras: extras)
    }

    func suite() -> UserDefaults { UserDefaults(suiteName: "WatchTests.\(UUID().uuidString)")! }

    func pass(for id: UUID, format: PassBarcode.Format = .aztec) -> BoardingPass {
        var p = FakeBoardingPass.af84(now: now)
        p.flightId = id
        p.barcode?.format = format
        return p
    }

    // MARK: Encoding

    @Test func snapshotRoundTrip() throws {
        let f = widgetFlight(depDelay: 25)
        let matrix = try #require(BarcodeMatrix(width: 3, height: 2, modules: [true, false, true, false, true, false]))
        let s = WatchSnapshot(flights: WidgetSnapshot(generatedAt: now, flights: [f]),
                              extras: [WatchFlightExtras(id: f.id, baggageBelt: "5", seat: "32A",
                                                         pass: WatchPass(format: "aztec", message: "M1TEST", passenger: "Camille Laurent",
                                                                         boardingGroup: "1", modules: matrix))],
                              twelveHour: true)
        let data = try s.encoded()
        #expect(WatchSnapshot.decode(data) == s)
        // Equal snapshots encode alike: the phone's skip and the store compare bytes safely.
        #expect(try s.encoded() == data)
    }

    @Test func applicationContextRoundTrip() throws {
        let s = snapshot([widgetFlight()])
        let context = try s.applicationContext()
        #expect(context.keys.sorted() == [WatchSnapshot.contextKey])
        #expect(context[WatchSnapshot.contextKey] is Data)
        #expect(WatchSnapshot.from(applicationContext: context) == s)
        #expect(WatchSnapshot.from(applicationContext: [:]) == nil)
        #expect(WatchSnapshot.from(applicationContext: [WatchSnapshot.contextKey: "nope"]) == nil)
    }

    @Test func otherVersionOrGarbageReadsAsNothing() throws {
        var s = snapshot([widgetFlight()])
        s.version = WatchSnapshot.currentVersion + 1
        #expect(WatchSnapshot.decode(try s.encoded()) == nil)
        #expect(WatchSnapshot.decode(Data("{}".utf8)) == nil)
        #expect(WatchSnapshot.decode(Data()) == nil)
    }

    @Test func extrasOnlyForCarriedFlightsAndNotEmpty() {
        let f = widgetFlight()
        let s = snapshot([f], extras: [WatchFlightExtras(id: f.id, seat: " 6A "), WatchFlightExtras(id: UUID(), seat: "1A"),
                                       WatchFlightExtras(id: f.id, baggageBelt: "  ")])
        #expect(s.extras == [WatchFlightExtras(id: f.id, seat: "6A")])
        #expect(s.extras(for: f.id)?.seat == "6A")
    }

    @Test func sameContentIgnoresWriteTimeAndProgress() {
        let f = widgetFlight(status: .enRoute, out: -60)
        var a = snapshot([f]), b = a
        b.flights.generatedAt = at(10)
        b.flights.flights[0].progress = 0.5
        #expect(a.sameContent(as: b))
        a.twelveHour = true
        #expect(!a.sameContent(as: b))
        b.twelveHour = true
        b.extras = [WatchFlightExtras(id: f.id, baggageBelt: "5")]
        #expect(!a.sameContent(as: b))
    }

    // MARK: Barcode modules

    @Test func matrixPacksRowsFromTheTop() throws {
        let modules = (0..<(11 * 3)).map { $0 % 3 == 0 }
        let m = try #require(BarcodeMatrix(width: 11, height: 3, modules: modules))
        #expect(m.bits.count == 5)
        #expect(m.isValid)
        for y in 0..<3 { for x in 0..<11 { #expect(m[x, y] == modules[y * 11 + x]) } }
        #expect(!m[11, 0] && !m[-1, 0] && !m[0, 3])
        #expect(BarcodeMatrix(width: 2, height: 2, modules: [true]) == nil)
        #expect(BarcodeMatrix(width: 0, height: 0, modules: []) == nil)
    }

    @Test func passModulesMatchCoreImage() throws {
        for format in [PassBarcode.Format.aztec, .pdf417, .qr] {
            let p = pass(for: UUID(), format: format)
            let barcode = try #require(p.barcode)
            let image = try #require(PassBarcodeImage.make(barcode, scale: 1))
            let m = try #require(PassBarcodeImage.modules(barcode))
            #expect(m.width == image.width && m.height == image.height)
            let dark = (0..<m.height).reduce(0) { n, y in n + (0..<m.width).filter { m[$0, y] }.count }
            // A real code: neither blank nor solid.
            #expect(dark > m.width * m.height / 5 && dark < m.width * m.height * 4 / 5)
        }
    }

    // MARK: Phone side

    @Test func snapshotFromFlightsAddsBeltSeatAndPass() throws {
        let a = flight("AF84", outIn: 120, belt: "5"), b = flight("UA1527", outIn: 300)
        let p = pass(for: a.id)
        let s = WatchSnapshot.from([b, a], passes: [a.id: p], lookup: { _ in nil }, twelveHour: true, now: now)
        #expect(s.flights.flights.map(\.ident) == ["AF84", "UA1527"])
        #expect(s.twelveHour)
        let extras = try #require(s.extras(for: a.id))
        #expect(extras.baggageBelt == "5")
        #expect(extras.seat == "6A")
        #expect(extras.pass?.format == "aztec")
        #expect(extras.pass?.message == p.barcode?.message)
        #expect(extras.pass?.passenger == "Camille Laurent")
        #expect(extras.pass?.boardingGroup == "1")
        #expect(extras.pass?.modules?.isValid == true)
        // Nothing to add for the second flight.
        #expect(s.extras(for: b.id) == nil)
        // Small enough for the application context.
        #expect(try s.encoded().count < 16_000)
    }

    final class RecordingTransport: WatchTransport {
        var canSend = true
        var sent: [WatchSnapshot] = []
        var onRequest: (@MainActor () -> Void)?
        func send(_ data: Data) throws { sent.append(try #require(WatchSnapshot.decode(data))) }
    }

    @Test func senderSkipsWhatChangesNothing() async {
        let t = RecordingTransport()
        let sender = WatchSnapshotSender(transport: t, lookup: { _ in nil }, twelveHour: { false }, now: { self.now })
        let a = flight("AF84", belt: "5")
        await sender.update([a])
        #expect(t.sent.count == 1)
        await sender.update([a])
        #expect(t.sent.count == 1)
        var later = a
        later.gateOrigin = "K44"
        await sender.update([later])
        #expect(t.sent.count == 2)
        #expect(t.sent.last?.flights.flights.first?.gateOrigin == "K44")
        sender.clear()
        #expect(t.sent.count == 3)
        #expect(t.sent.last?.flights.flights.isEmpty == true)
        sender.clear()
        #expect(t.sent.count == 3)
    }

    @Test func senderReadsPassesAndWaitsForAWatch() async {
        let t = RecordingTransport()
        t.canSend = false
        let sender = WatchSnapshotSender(transport: t, lookup: { _ in nil }, twelveHour: { true }, now: { self.now })
        let a = flight("AF84")
        let p = pass(for: a.id)
        sender.passes = { id in id == a.id ? p : nil }
        await sender.update([a])
        #expect(t.sent.isEmpty)
        #expect(sender.lastSent == nil)
        // A watch paired: the next change goes.
        t.canSend = true
        await sender.update([a])
        #expect(t.sent.count == 1)
        #expect(t.sent[0].extras(for: a.id)?.pass?.message == p.barcode?.message)
        #expect(t.sent[0].twelveHour)
    }

    // MARK: Watch model

    @Test func modelKeepsTheSnapshotOffline() {
        let defaults = suite()
        var reloads = 0
        let model = WatchFlightsModel(defaults: defaults) { reloads += 1 }
        #expect(!model.hasSynced)
        #expect(model.rows(at: now).isEmpty)
        let s = snapshot([widgetFlight()])
        #expect(model.receive(s))
        #expect(reloads == 1)
        // The same flights again: no complication reload.
        var again = s
        again.flights.generatedAt = at(5)
        #expect(!model.receive(again))
        #expect(reloads == 1)
        // A relaunch reads what was kept.
        let relaunched = WatchFlightsModel(defaults: defaults)
        #expect(relaunched.hasSynced)
        #expect(relaunched.snapshot == again)
        #expect(relaunched.updatedText(at: at(17)) == "Updated 12 min ago")
        #expect(relaunched.updatedText(at: at(5)) == "Updated just now")
        #expect(relaunched.updatedText(at: at(5 + 180)) == "Updated 3 hr ago")
    }

    @Test func rowsInTheWidgetsOrder() {
        let model = WatchFlightsModel(defaults: suite())
        let later = widgetFlight(out: 600), air = widgetFlight(status: .enRoute, out: -60), soon = widgetFlight(out: 30)
        let landedLongAgo = widgetFlight(status: .arrived, out: -900, duration: 600)
        model.receive(snapshot([later, landedLongAgo, soon, air]))
        #expect(model.rows(at: now).map(\.flight.id) == [air.id, soon.id, later.id])
        #expect(model.rows(at: now)[1].countdown.value == "30")
    }

    @Test func detailBeforeDeparture() throws {
        let model = WatchFlightsModel(defaults: suite())
        let f = widgetFlight(out: 125, depDelay: 25, arrDelay: 10)
        model.receive(snapshot([f], extras: [WatchFlightExtras(id: f.id, baggageBelt: "5", seat: "6A",
                                                                pass: WatchPass(format: "qr", message: "M1", boardingGroup: "2"))]))
        let d = try #require(model.detail(for: f.id, at: now))
        #expect(d.status == "25m Late")
        #expect(d.level == .late)
        #expect(d.countdownLine == "Departs in 2 hrs")
        #expect(d.departure.code == "CDG" && d.departure.city == "Paris")
        #expect(d.departure.scheduled != nil)
        #expect(d.departure.tone == .late)
        #expect(d.departure.offset == "25m Late")
        #expect(d.facts.map(\.label) == ["Gate", "Terminal", "Seat", "Group", "Belt"])
        #expect(d.facts.first?.value == "K42" && d.facts.first?.isGate == true)
        #expect(d.progress == nil)
        #expect(d.pass?.message == "M1")
        #expect(model.detail(for: UUID(), at: now) == nil)
    }

    @Test func detailInTheAirAndLanded() throws {
        let model = WatchFlightsModel(defaults: suite())
        let air = widgetFlight(status: .enRoute, out: -150, duration: 600, depDelay: 5, arrDelay: 0)
        let extras = WatchFlightExtras(id: air.id, baggageBelt: "5", seat: "6A", pass: WatchPass(format: "qr", message: "M1"))
        model.receive(snapshot([air], extras: [extras]))
        let d = try #require(model.detail(for: air.id, at: now))
        #expect(d.status == "In the Air")
        #expect(d.countdownLine == "Arrives in 7h")
        #expect(d.timeLeft == "7h 30m left")
        #expect(abs((d.progress ?? 0) - 0.25) < 0.001)
        #expect(d.facts.map(\.label) == ["Gate", "Terminal", "Belt", "Seat"])
        #expect(d.facts.first?.value == "G91")
        #expect(d.pass != nil)

        var landed = air
        landed.status = .arrived
        model.receive(snapshot([landed], extras: [extras]))
        let l = try #require(model.detail(for: air.id, at: now))
        #expect(l.status == "Arrived")
        #expect(l.countdownLine == "Landed")
        #expect(l.progress == nil)
        #expect(l.pass == nil)
    }

    // MARK: Complications

    @Test func relevanceRisesAroundDeparture() {
        func score(_ f: WidgetFlight, at minutes: Double) -> Float {
            WatchRelevance.score(for: WidgetSnapshot(generatedAt: now, flights: [f]), at: at(minutes))
        }
        let f = widgetFlight(out: 600, duration: 300)
        #expect(score(f, at: 0) == 0) // 10 h out
        #expect(score(f, at: 400) == 0.5) // 3 h 20 out
        #expect(score(f, at: 560) == 1) // 40 min out
        #expect(score(f, at: 610) == 1) // past departure, still at the gate
        var air = f
        air.status = .enRoute
        #expect(score(air, at: 700) == 0.6)
        #expect(score(air, at: 880) == 1) // 20 min before arrival
        var landed = f
        landed.status = .arrived
        #expect(score(landed, at: 910) == 0.8)
        #expect(score(landed, at: 940) == 0)
        var canceled = f
        canceled.status = .canceled
        #expect(score(canceled, at: 560) == 0)
        #expect(WatchRelevance.score(for: .empty(at: now), at: now) == 0)
    }

    @Test func complicationTimelineMarksTheRelevanceSteps() {
        let f = widgetFlight(out: 360, duration: 300)
        let plan = WatchComplicationTimeline.plan(for: snapshot([f]), now: now)
        let dates = plan.entries.map(\.date)
        #expect(dates.first == now)
        #expect(dates.contains(at(360 - 240)))
        #expect(dates.contains(at(360 - 60)))
        #expect(dates == dates.sorted())
        #expect(plan.entries.first?.score == 0.5 || plan.entries.first?.score == 0)
        #expect(plan.entries.first { $0.date == at(300) }?.score == 1)
        for (e, next) in zip(plan.entries, plan.entries.dropFirst()) {
            #expect(e.duration == next.date.timeIntervalSince(e.date))
        }
        #expect(plan.reload != nil)
        let none = WatchComplicationTimeline.plan(for: nil, now: now)
        #expect(none.entries.count == 1 && none.reload == nil)
    }
}
