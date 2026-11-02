import Foundation
import Testing
import FlightImportKit
@testable import FlightKit
import PostgREST

/// The import from the other tracker, end to end on this side of the network: a realistic export
/// (`Fixtures/flighty_export.csv`, 307 invented rows in all 33 columns, with the quirks a real export has)
/// in every encoding a file can arrive in, the picker that lost the picked file, the batches with their
/// progress, a bad row, a lost network and a stop, and the store's result, retry, toast and notification.
@MainActor @Suite struct FlightyImportFlowTests {
    static let directory = AirportDirectory.bundled()
    static let reference = ReferenceData.bundled()
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    static let fixture: Data = {
        let url = Bundle.module.url(forResource: "flighty_export", withExtension: "csv", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }()

    static func store(history: any HistoryService = FakeHistoryService(limit: 0),
                      notifier: FakeImportNotifier? = nil) -> ImportStore {
        let s = ImportStore(passport: PassportStore(history: history, airports: directory.lookup),
                            flights: ImportSourcesTests.StubFlights(), queue: FollowLaterQueue(owner: nil, defaults: nil),
                            calendar: nil, airport: directory.lookup, reference: reference, now: { now })
        s.notifier = notifier
        s.batchSize = 50
        return s
    }

    static func flights(_ r: ImportStore.Review) -> [PastFlight] {
        r.past.compactMap { if case .addPast(let f) = $0.action { f } else { nil } }
    }

    // MARK: Reading the realistic export

    @Test func fixtureReadsEveryRow() throws {
        let rows = try FlightyImport.read(Self.fixture)
        #expect(rows.count == 307)
        let s = Self.store()
        s.readFlighty(Self.fixture, name: "flighty_export.csv")
        let r = try #require(s.review)
        #expect(r.found == 307)
        #expect(r.upcoming.count == 1)
        #expect(r.past.count == 301)
        #expect(Set(r.unreadable.map(\.reason)).isSuperset(of: [
            "No date", "Date \u{201C}2024-02-30\u{201D} not understood", "No departure airport",
            "Departs and arrives at the same airport"]))
        #expect(r.unreadable.count == 4)
        #expect(r.duplicates.map(\.reason) == ["Listed twice"])
        #expect(s.commitTitle == "Import 301, Add 1")

        let past = Self.flights(r)
        // An airport the bundled list does not know is kept as written; the server knows more.
        #expect(past.contains { $0.originIcao == "XZQ" && $0.destinationIcao == "KSFO" })
        // Quoted fields keep their commas, quotes, line breaks and accents; a formula-looking note stays text.
        let notes = Set(past.compactMap(\.notes))
        #expect(notes.isSuperset(of: ["Window, great views", "He said \"welcome aboard\"", "Line one\nline two",
                                      "=SUM(A1)", "Café au lait, merci"]))
        // Seats written "12 A" or "7a" are seats; "40L" is not one the server takes, and is left out.
        let seats = Set(past.compactMap(\.seat))
        #expect(seats.contains("12A") && seats.contains("7A") && !seats.contains("40L"))
        #expect(!seats.contains { $0.contains(" ") })
        // Range variants the reference list does not name apart.
        let types = Set(past.compactMap(\.aircraftType))
        #expect(types.isSuperset(of: ["B739", "B772", "B38M", "B77W", "A21N", "CRJ9"]))
        // Every flight passes the rules the database checks.
        for f in past {
            #expect(f.source == .import)
            #expect(PastFlightRules.ident(f.ident) != nil, "\(f.ident)")
            #expect(f.aircraftType.map { PastFlightRules.aircraftType($0) != nil } ?? true)
            #expect(f.seat.map { FollowDetails.normalizedSeat($0) != nil } ?? true)
            #expect(PastFlightRules.allows(date: f.date, now: Self.now))
            #expect(f.originIcao != f.destinationIcao)
        }
        // "0084" is flight 84.
        #expect(past.contains { $0.ident == "LH84" })
    }

    /// The same file as UTF-8 with a byte order mark, UTF-16 either way with and without one, and with
    /// Windows line ends: the same flights each time.
    @Test func everyEncodingReadsTheSame() throws {
        let text = String(decoding: Self.fixture, as: UTF8.self)
        var variants: [String: Data] = [:]
        variants["utf8 bom"] = Data([0xEF, 0xBB, 0xBF]) + Self.fixture
        variants["utf16le bom"] = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        variants["utf16be bom"] = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        variants["utf16le"] = text.data(using: .utf16LittleEndian)!
        variants["utf16be"] = text.data(using: .utf16BigEndian)!
        variants["crlf"] = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let base = Self.store()
        base.readFlighty(Self.fixture)
        let expected = Self.flights(try #require(base.review)).map { "\($0.ident) \($0.originIcao) \($0.date) \($0.notes ?? "")" }
        for (name, data) in variants {
            #expect(FlightyImport.recognizes(data), "\(name)")
            let s = Self.store()
            s.readFlighty(data)
            let got = s.review.map(Self.flights)?.map { "\($0.ident) \($0.originIcao) \($0.date) \($0.notes ?? "")" }
            // A quoted line break written CRLF stays CRLF inside the note; compare without it.
            #expect(got?.map { $0.replacingOccurrences(of: "\r\n", with: "\n") } == expected, "\(name)")
        }
    }

    @Test func eitherPickerReadsEitherFile() async throws {
        // The export picked as "a CSV file" is still read as the export (its follows, its columns).
        let s = Self.store()
        await s.read(Self.fixture, as: .csv, name: "x.csv")
        #expect(s.review?.source == .flighty && s.review?.upcoming.count == 1)
        // A plain CSV picked as the export is read as a CSV file.
        let plain = Data("date,from,to,flight\n2024-01-10,SFO,LAX,UA1\n2024-01-11,LAX,SFO,UA2\n2024-01-11,LAX,SFO,UA2\nnope,SFO,LAX,\n".utf8)
        await s.read(plain, as: .flighty, name: "mine.csv")
        let r = try #require(s.review)
        #expect(r.source == .csv && r.past.count == 2 && r.duplicates.count == 1 && r.unreadable.count == 1)
        // Neither: the export's own words.
        await s.read(Data("hello,world\n1,2\n".utf8), as: .flighty, name: "x.csv")
        guard case .failed(.flighty, let message) = s.phase else { Issue.record("not failed: \(s.phase)"); return }
        #expect(message.contains("Date") && message.contains("From"))
    }

    @Test func largeFileReadsOffTheMainActor() async throws {
        // 2,000 rows: the fixture's body repeated, a day apart so they are not duplicates.
        let lines = String(decoding: Self.fixture, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var body = [String(lines[0])]
        for i in 0..<2000 {
            body.append("\(2000 + i / 365)-\(String(format: "%02d", i % 12 + 1))-\(String(format: "%02d", i % 28 + 1)),AFR,\(i + 1),CDG,SFO,,,,,false,,,,,,,,,,Boeing 787-9,,,,,ECONOMY,LEISURE,,,,,,,")
        }
        let data = Data(body.joined(separator: "\n").utf8)
        let s = Self.store()
        await s.read(data, as: .flighty, name: "big.csv")
        let r = try #require(s.review)
        #expect(r.found == 2000)
        #expect(r.past.count + r.duplicates.count == 2000)
    }

    // MARK: Picker

    /// The bug the owner hit: SwiftUI clears the picker's `isPresented` before its completion runs, and
    /// the first screen kept the source there, so the picked file was dropped.
    @Test func pickerKeepsItsSourceWhileClosing() {
        var p = ImportPicker<ImportView.Picker>()
        p.open(.flighty)
        #expect(p.isPresented && p.kind == .flighty)
        p.isPresented = false            // what the system does first
        #expect(p.kind == .flighty)      // the types stay, and so does the source
        #expect(p.take() == .flighty)    // what the completion reads
        #expect(p.take() == nil && !p.isPresented)
        #expect(ImportView.Picker.flighty.types.contains(.commaSeparatedText))
        #expect(ImportView.Picker.flighty.types.contains(.data))
    }

    // MARK: Files

    @Test func fileReadChecksSizeAndEmptiness() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "import-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appending(path: "flights.csv"), empty = dir.appending(path: "empty.csv"), big = dir.appending(path: "big.csv")
        try Self.fixture.write(to: ok)
        try Data().write(to: empty)
        try Data(count: 2_000).write(to: big)
        #expect(try await ImportFile.read(ok).get() == Self.fixture)
        #expect(await ImportFile.read(empty) == .failure(.empty))
        #expect(await ImportFile.read(big, maxBytes: 1_000) == .failure(.tooLarge))
        #expect(await ImportFile.read(dir.appending(path: "gone.csv")) == .failure(.unreadable))
    }

    // MARK: Batches

    /// A history that records each request and refuses what the test says.
    actor ScriptedHistory: HistoryService {
        var batches: [Int] = []
        var stored: [PastFlight] = []
        /// Ids the "database" refuses (a check constraint): a batch holding one fails whole.
        var poisoned: Set<PastFlight.ID> = []
        /// Origins it refuses, the same way.
        var refusedOrigins: Set<String> = []
        /// From this request on, every request fails offline.
        var offlineFrom: Int?
        /// Waits this long per request (so a test can stop the import mid way).
        var delay: Duration = .zero

        init(poisoned: Set<PastFlight.ID> = [], refusedOrigins: Set<String> = [], offlineFrom: Int? = nil,
             delay: Duration = .zero) {
            self.poisoned = poisoned; self.refusedOrigins = refusedOrigins; self.offlineFrom = offlineFrom; self.delay = delay
        }

        func heal() { poisoned = []; refusedOrigins = []; offlineFrom = nil }

        func pastFlights() async throws(APIError) -> [PastFlight] { stored }
        func export(_ format: ExportFormat) async throws(APIError) -> Data { Data() }
        func addAll(_ flights: [PastFlight]) async throws(APIError) -> [PastFlight] {
            batches.append(flights.count)
            if delay > .zero { try? await Task.sleep(for: delay) }
            if let offlineFrom, batches.count >= offlineFrom { throw .offline }
            if flights.contains(where: { poisoned.contains($0.id) || refusedOrigins.contains($0.originIcao) }) {
                throw .rejected("An airport code, the flight number, the aircraft or the date isn't accepted")
            }
            stored += flights
            return flights
        }
    }

    static func pastFlights(_ n: Int) -> [PastFlight] {
        (0..<n).map { i in
            PastFlight(id: UUID(), date: now.addingTimeInterval(-Double(i + 1) * 86_400), ident: "AF\(i + 1)",
                       originIcao: "LFPG", destinationIcao: "KSFO", distanceKm: 0, source: .import)
        }
    }

    @Test func importGoesInBatchesWithProgress() async {
        let history = ScriptedHistory()
        var seen: [Int] = []
        let out = await HistoryImport.run(Self.pastFlights(300), into: history, batchSize: 50) { seen.append($0.done) }
        #expect(out.stored.count == 300 && out.failed.isEmpty && !out.canceled)
        #expect(await history.batches == [50, 50, 50, 50, 50, 50])
        #expect(seen == [0, 50, 100, 150, 200, 250, 300])
    }

    @Test func oneBadRowCostsOnlyItself() async {
        let flights = Self.pastFlights(300)
        let history = ScriptedHistory(poisoned: [flights[123].id])
        let out = await HistoryImport.run(flights, into: history, batchSize: 50)
        #expect(out.stored.count == 299)
        #expect(out.failed.map(\.flight.id) == [flights[123].id])
        #expect(out.failed.first?.reason == "An airport code, the flight number, the aircraft or the date isn't accepted")
        // The third batch went again one flight at a time.
        let batches = await history.batches
        #expect(batches.prefix(3) == [50, 50, 50] && batches.dropFirst(3).prefix(50).allSatisfy { $0 == 1 })
        #expect(batches.count == 3 + 50 + 3)
    }

    @Test func lostNetworkStopsAndListsTheRest() async {
        let history = ScriptedHistory(offlineFrom: 3)
        let out = await HistoryImport.run(Self.pastFlights(300), into: history, batchSize: 50)
        #expect(out.stored.count == 100)
        #expect(out.failed.count == 200)
        #expect(out.failed.allSatisfy { $0.error == .offline })
        #expect(await history.batches.count == 3)
    }

    @Test func stoppingLeavesTheStoredOnes() async {
        let history = ScriptedHistory(delay: .milliseconds(30))
        let flights = Self.pastFlights(300)
        let task = Task { @MainActor in
            await HistoryImport.run(flights, into: history, batchSize: 50) { p in
                if p.done == 100 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let out = await task.value
        #expect(out.stored.count == 100)
        #expect(out.notSent.count == 200 && out.canceled)
        #expect(await history.stored.count == 100)
    }

    // MARK: Store

    @Test func storeImportsShowsProgressAndRefreshesThePassport() async throws {
        let history = FakeHistoryService(limit: 0)
        let notifier = FakeImportNotifier(active: true)
        let s = Self.store(history: history, notifier: notifier)
        s.readFlighty(Self.fixture, name: "flighty_export.csv")
        s.isScreenVisible = true
        let total = s.selectedPast.count
        var phases: [Int] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if case .importing(let p) = s.phase, phases.last != p.done { phases.append(p.done) }
                await Task.yield()
            }
        }
        await s.commit()
        watcher.cancel()
        guard case .done(let summary) = s.phase else { Issue.record("not done: \(s.phase)"); return }
        #expect(summary.added == total && summary.addFailures.isEmpty)
        #expect(summary.skipped == 307 - total - 1)
        #expect(summary.later == 1)
        #expect(summary.headline == "301 flights added to your Passport")
        #expect(s.passport.allFlights.count == total)
        #expect(phases.last == total || phases.isEmpty)
        // A long import asks for notification permission (when never answered), in front.
        #expect(notifier.prepared == 1)
        // On its screen, in front: no toast, no notification.
        #expect(s.toast == nil && notifier.posted.isEmpty)
        // Reading the file again finds them all there.
        s.reset()
        s.readFlighty(Self.fixture)
        #expect(s.review?.past.isEmpty == true)
    }

    @Test func endingInTheBackgroundNotifiesAndClosedScreenToasts() async throws {
        let notifier = FakeImportNotifier(active: false)
        let s = Self.store(notifier: notifier)
        s.readFlighty(Self.fixture)
        await s.commit()
        #expect(notifier.posted.map(\.title) == ["Import finished"])
        #expect(notifier.posted.first?.body == "301 flights added to your Passport.")
        #expect(s.toast == nil)

        let front = FakeImportNotifier(active: true)
        let t = Self.store(notifier: front)
        t.readFlighty(Self.fixture)
        t.isScreenVisible = false
        await t.commit()
        #expect(front.posted.isEmpty)
        #expect(t.toast == "Import finished: 301 flights added to your Passport")
    }

    @Test func failuresAreListedAndRetried() async throws {
        // The "server" refuses the flight from the airport it does not know.
        let history = ScriptedHistory(refusedOrigins: ["XZQ"])
        let s = Self.store(history: history)
        s.readFlighty(Self.fixture)
        let total = s.selectedPast.count
        await s.commit()
        guard case .done(let summary) = s.phase else { Issue.record("not done"); return }
        #expect(summary.added == total - 1)
        #expect(summary.addFailures.count == 1)
        let failure = try #require(summary.addFailures.first)
        #expect(failure.flight.originIcao == "XZQ")
        #expect(failure.label == "Row 305")
        #expect(failure.reason == "An airport code, the flight number, the aircraft or the date isn't accepted")
        #expect(summary.headline == "\(total - 1) flights added to your Passport")
        #expect(s.passport.writeError != nil)

        await history.heal()
        await s.retryFailed()
        guard case .done(let after) = s.phase else { Issue.record("not done"); return }
        #expect(after.added == total && after.addFailures.isEmpty)
        #expect(await history.stored.count == total)
    }

    @Test func stopFromTheScreenKeepsWhatWasSaved() async throws {
        let history = ScriptedHistory(delay: .milliseconds(40))
        let s = Self.store(history: history)
        s.readFlighty(Self.fixture)
        let run = Task { await s.commit() }
        while true {
            if case .importing(let p) = s.phase, p.done >= 50 { break }
            await Task.yield()
        }
        s.cancel()
        await run.value
        guard case .done(let summary) = s.phase else { Issue.record("not done"); return }
        #expect(summary.stopped)
        #expect(summary.added >= 50 && summary.added < 301)
        #expect(summary.added + summary.addFailures.count == 301)
        #expect(summary.addFailures.allSatisfy { $0.reason == ImportStore.stoppedReason })
        #expect(await history.stored.count == summary.added)
    }

    // MARK: Errors the server gives

    @Test func refusedRowsSayWhy() {
        let check = PostgrestError(code: "23514", message: "new row for relation \"past_flights\" violates check constraint \"past_flights_client_shape_check\"")
        #expect(SupabaseBackend.map(check) == .rejected("An airport code, the flight number, the aircraft or the date isn't accepted"))
        let seat = PostgrestError(code: "23514", message: "violates check constraint \"past_flights_seat_check\"")
        #expect(SupabaseBackend.map(seat) == .rejected("The seat isn't one the server accepts"))
        #expect(SupabaseBackend.map(PostgrestError(code: "23505", message: "duplicate key")) == .rejected("Already in your Passport"))
        #expect(SupabaseBackend.map(PostgrestError(code: "42501", message: "row-level security")).message.contains("Sign in again"))
        #expect(SupabaseBackend.map(PostgrestError(code: "22P02", message: "invalid input")).message.contains("format"))
        #expect(SupabaseBackend.map(PostgrestError(code: "PGRST301", message: "jwt")) == .unauthorized)
        #expect(SupabaseBackend.map(PostgrestError(code: "XX000", message: "boom")) == .providerUnavailable)
    }
}
