import Foundation
import Testing
@testable import FlightKit

@Suite struct FlightQueryTests {
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesIdent() {
        for text in ["AF84", "AF 84", " af84 ", "DL2204", "B6417", "9W 123"] {
            guard case .ident(let s, let d)? = FlightQuery.parse(text, date: day) else {
                Issue.record("not ident: \(text)"); continue
            }
            #expect(d == day)
            #expect(s == text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "").uppercased())
        }
    }

    @Test func parsesRoute() {
        for text in ["CDG SFO", "CDG-SFO", "cdg to sfo", "KAUS KSFO", "CDG - SFO"] {
            guard case .route(let o, let d, _)? = FlightQuery.parse(text, date: day) else {
                Issue.record("not route: \(text)"); continue
            }
            #expect(o.count >= 3 && d.count >= 3)
            #expect(o == o.uppercased())
        }
        if case .route(let o, let d, _)? = FlightQuery.parse("cdg to sfo", date: day) { #expect(o == "CDG" && d == "SFO") }
    }

    @Test func parsesAirport() {
        for text in ["SFO", "kaus", " AUS "] {
            guard case .airport(let c)? = FlightQuery.parse(text, date: day) else {
                Issue.record("not airport: \(text)"); continue
            }
            #expect(c == text.trimmingCharacters(in: .whitespaces).uppercased())
        }
    }

    @Test func rejectsGarbage() {
        #expect(FlightQuery.parse("hello world", date: day) == nil)
        #expect(FlightQuery.parse("", date: day) == nil)
        #expect(FlightQuery.parse("   ", date: day) == nil)
    }
}

@Suite struct FakeServicesTests {
    @Test func fakeErrorInjection() async throws {
        let svc = FakeFlightService()
        await svc.setNextError(.rateLimited)
        do {
            _ = try await svc.lookup(.ident("AF84", date: .now))
            Issue.record("expected throw")
        } catch { #expect(error == .rateLimited) }
        let ok = try await svc.lookup(.ident("AF84", date: .now))
        #expect(ok.first?.ident == "AF84")
    }

    @Test func fakeUpdatesStream() async throws {
        let svc = FakeFlightService()
        let flight = try await svc.followed().first!
        let stream = svc.updates(for: [flight.id])
        var updated = flight
        updated.gateOrigin = "Z99"
        await svc.push(updated)
        var it = stream.makeAsyncIterator()
        let got = await it.next()
        #expect(got?.gateOrigin == "Z99")
        #expect(try await svc.flight(flight.id).gateOrigin == "Z99")
    }

    @Test func seedCoversRequiredStates() async throws {
        let svc = FakeFlightService()
        let f = try await svc.followed()
        #expect(f.count >= 4)
        let statuses = Set(f.map(\.status))
        #expect(statuses.isSuperset(of: [.enRoute, .scheduled, .canceled, .diverted]))
        // Offsets from now (the seed's clock is shifted to load time): one later today, one the next day.
        let sched = f.filter { $0.status == .scheduled }.compactMap { $0.scheduledOut?.timeIntervalSinceNow }
        #expect(sched.contains { $0 > 0 && $0 < 6 * 3600 })
        #expect(sched.contains { $0 > 12 * 3600 && $0 < 30 * 3600 })
        #expect(f.contains { $0.status == .diverted && $0.destinationIcao == "KOAK" })
        let en = try #require(f.first { $0.status == .enRoute })
        #expect(abs(en.updatedAt.timeIntervalSinceNow) < 3600)
    }

    @Test func followUnfollow() async throws {
        let svc = FakeFlightService()
        let id = try await svc.followed()[0].id
        try await svc.unfollow(id)
        #expect(try await svc.followed().contains { $0.id == id } == false)
        try await svc.follow(id, notify: true)
        #expect(try await svc.followed().contains { $0.id == id })
        do { _ = try await svc.flight(UUID()); Issue.record("expected throw") } catch { #expect(error == .notFound) }
    }

    @Test func lookupRouteAndAirport() async throws {
        let svc = FakeFlightService()
        let r = try await svc.lookup(.route(origin: "KLAX", destination: "OAK", date: .now))
        #expect(r.contains { $0.ident == "WN4410" })
        let a = try await svc.lookup(.airport("AUS"))
        #expect(!a.isEmpty)
        do { _ = try await svc.lookup(.ident("ZZ9999", date: .now)); Issue.record("expected throw") } catch { #expect(error == .notFound) }
    }

    @Test func eventsAreSynthesised() async throws {
        let svc = FakeFlightService()
        let en = try await svc.followed().first { $0.status == .enRoute }!
        let ev = try await svc.events(en.id)
        #expect(ev.contains { $0.kind == .departure })
    }

    @Test func airportBoardsStatsWeather() async throws {
        let svc = FakeAirportService()
        for code in ["KAUS", "KSFO"] {
            let dep = try await svc.board(code, .departures)
            let arr = try await svc.board(code, .arrivals)
            #expect(dep.flights.count >= 25 && arr.flights.count >= 25)
            #expect(dep.kind == .departures)
            #expect(Set(dep.flights.map(\.status)).count > 1)
            let s = try await svc.stats(code)
            #expect(s.departures.total > 0 && s.arrivals.total > 0 && !s.stale)
            let w = try await svc.weather(code)
            #expect(!w.weather.metarRaw.isEmpty)
        }
        #expect(try await svc.airport("SFO").id == "KSFO")
        #expect(try await svc.airport("kaus").iata == "AUS")
        await svc.setNextError(.offline)
        do { _ = try await svc.airport("KSFO"); Issue.record("expected throw") } catch { #expect(error == .offline) }
        do { _ = try await svc.board("KXXX", .departures); Issue.record("expected throw") } catch { #expect(error == .notFound) }
    }

    @Test func timesShiftToNow() async throws {
        let svc = FakeAirportService()
        let dep = try await svc.board("KAUS", .departures)
        let first = try #require(dep.flights.compactMap(\.scheduledOut).min())
        #expect(abs(first.timeIntervalSinceNow) < 6 * 3600)
        let w = try await svc.weather("KAUS")
        #expect(abs(w.weather.observedAt.timeIntervalSinceNow) < 3600)
    }

    @Test func historyAndExport() async throws {
        let svc = FakeHistoryService()
        let past = try await svc.pastFlights()
        #expect(past.count == 8)
        #expect(past.contains { $0.status == .canceled })
        let years = Set(past.map { Calendar(identifier: .gregorian).component(.year, from: $0.date) })
        #expect(years == [2024, 2025, 2026])
        let csv = String(decoding: try await svc.export(.csv), as: UTF8.self)
        #expect(csv.split(separator: "\n").count == 9)
        let json = try await svc.export(.json)
        #expect(try FlightJSON.decoder.decode([PastFlight].self, from: json).count == 8)
    }

    @Test func authFlow() async throws {
        let auth = FakeAuthService()
        var it = auth.session.makeAsyncIterator()
        #expect(await it.next() == .some(nil))
        try await auth.signInWithApple(idToken: "t", nonce: "n")
        let s = await it.next()
        #expect(s??.plan == .free)
        await auth.signOut()
        #expect(await it.next() == .some(nil))
        await auth.setNextError(.unauthorized)
        do { try await auth.signInWithEmail("a@b.co"); Issue.record("expected throw") } catch { #expect(error == .unauthorized) }
    }

    @Test func pushRegisters() async throws {
        let push = FakePushService()
        try await push.register(deviceToken: Data([1, 2]), kind: .liveActivity, flightId: UUID())
        #expect(await push.registrations.count == 1)
        #expect(PushTokenKind.liveActivity.rawValue == "live_activity")
    }
}
