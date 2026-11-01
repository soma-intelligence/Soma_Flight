import Foundation
@testable import FlightKit
import Testing

/// The import's real insert path against the LOCAL Supabase stack (see `SupabaseIntegrationTests` for
/// the environment). Off unless `INTEGRATION=1`. A throwaway user signs in, the realistic export
/// (`Fixtures/flighty_export.csv`) goes through the Import screen's store and `SupabaseHistoryService` in
/// batches, and the history is read back: the past_flights checks, the fill trigger and the row policies
/// all run. A row the database refuses comes back with its reason, alone.
///
/// `FLIGHTY_EXPORT=/path/to/file.csv` also imports a real export of your own for a second user and prints
/// only counts, never a row.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1"), .serialized)
struct ImportIntegrationTests {
    static func signIn(_ prefix: String) async throws -> (SupabaseBackend, UserSession) {
        let backend = SupabaseBackend(config: SupabaseConfig(url: SupabaseIntegrationTests.url,
                                                             anonKey: SupabaseIntegrationTests.localAnonKey),
                                      authStorage: MemoryAuthStorage())
        let auth = SupabaseAuthService(backend: backend)
        let email = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let sessions = auth.session
        try await auth.signInWithEmail(email)
        let code = try await SupabaseIntegrationTests.linkCode(to: email)
        var callback = URLComponents(url: SupabaseBackend.authCallback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: code)]
        try await auth.handleOpenURL(callback.url!)
        var signedIn: UserSession?
        for await s in sessions where s != nil { signedIn = s; break }
        return (backend, try #require(signedIn))
    }

    static func store(_ history: any HistoryService, now: Date = .now) -> ImportStore {
        let directory = AirportDirectory.bundled()
        let s = ImportStore(passport: PassportStore(history: history, airports: directory.lookup),
                            flights: ImportSourcesTests.StubFlights(), queue: FollowLaterQueue(owner: nil, defaults: nil),
                            calendar: nil, airport: directory.lookup, now: { now })
        s.batchSize = 50
        return s
    }

    @Test func fixtureGoesIntoTheHistory() async throws {
        let (backend, user) = try await Self.signIn("import-it")
        var failure: (any Error)?
        do {
            let history = SupabaseHistoryService(backend: backend)
            let s = Self.store(history)
            await s.read(FlightyImportFlowTests.fixture, as: .flighty, name: "flighty_export.csv")
            let review = try #require(s.review)
            let sent = s.selectedPast.count
            print("INTEGRATION import review rows \(review.found) new \(sent) duplicates \(review.duplicates.count) unreadable \(review.unreadable.count)")
            #expect(sent >= 300)
            await s.commit()
            guard case .done(let summary) = s.phase else { Issue.record("not done: \(s.phase)"); return }
            print("INTEGRATION import added \(summary.added) failed \(summary.addFailures.map(\.reason))")
            #expect(summary.added == sent)
            #expect(summary.addFailures.isEmpty)

            let back = try await history.pastFlights()
            #expect(back.count == sent)
            #expect(back.allSatisfy { $0.source == .import })
            // Filled by the server from its airports: the distance and the origin's zone.
            let known = back.filter { $0.originIcao != "XZQ" }
            #expect(known.allSatisfy { $0.distanceKm > 0 && $0.originTz != nil })
            #expect(back.contains { $0.originIcao == "XZQ" && $0.distanceKm == 0 })
            #expect(back.contains { $0.notes == "Line one\nline two" })
            #expect(back.contains { $0.seat == "12A" } && back.contains { $0.aircraftType == "B739" })

            // The same file again: nothing new.
            await s.passport.load()
            s.reset()
            await s.read(FlightyImportFlowTests.fixture, as: .flighty, name: "again.csv")
            #expect(s.review?.past.isEmpty == true)

            // A row the database refuses fails alone, with why; its batch neighbours go in.
            var bad = PastFlight(id: UUID(), date: .now.addingTimeInterval(-86_400 * 400), ident: "AF1",
                                 originIcao: "LFPG", destinationIcao: "KJFK", distanceKm: 0, source: .import)
            bad.aircraftType = "BOEING 737"
            let good = PastFlight(id: UUID(), date: .now.addingTimeInterval(-86_400 * 401), ident: "AF2",
                                  originIcao: "LFPG", destinationIcao: "KJFK", distanceKm: 0, source: .import)
            let out = await HistoryImport.run([good, bad], into: history, batchSize: 50)
            print("INTEGRATION refused row -> \(out.failed.map(\.error))")
            #expect(out.stored.map(\.id) == [good.id])
            #expect(out.failed.map(\.error) == [.rejected("An airport code, the flight number, the aircraft or the date isn't accepted")])
        } catch { failure = error }
        await SupabaseIntegrationTests.deleteUser(user.userId)
        if let failure { throw failure }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLIGHTY_EXPORT"] != nil))
    func ownExportGoesIntoTheHistory() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["FLIGHTY_EXPORT"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let (backend, user) = try await Self.signIn("import-own")
        var failure: (any Error)?
        do {
            let history = SupabaseHistoryService(backend: backend)
            let s = Self.store(history)
            await s.read(data, as: .flighty, name: "export.csv")
            let review = try #require(s.review)
            let sent = s.selectedPast.count
            print("INTEGRATION own export rows \(review.found) new \(sent) follow \(review.upcoming.count) duplicates \(review.duplicates.count) unreadable \(review.unreadable.count)")
            await s.commit()
            guard case .done(let summary) = s.phase else { Issue.record("not done"); return }
            let back = try await history.pastFlights()
            print("INTEGRATION own export added \(summary.added) failed \(summary.addFailures.count) read back \(back.count)")
            #expect(summary.addFailures.isEmpty)
            #expect(back.count == sent)
        } catch { failure = error }
        await SupabaseIntegrationTests.deleteUser(user.userId)
        if let failure { throw failure }
    }
}
