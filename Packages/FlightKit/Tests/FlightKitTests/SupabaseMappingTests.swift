import CryptoKit
import Foundation
@testable import FlightKit
import Supabase
import Testing

/// Pure mapping of the Supabase services: error bodies, request bodies, decoding. No network.
@Suite struct SupabaseMappingTests {
    private func body(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8)
    }

    @Test(arguments: [
        ("not_found", APIError.notFound, 404), ("rate_limited", .rateLimited, 429), ("plan_limit", .planLimit, 403),
        ("unauthorized", .unauthorized, 401), ("provider_unavailable", .providerUnavailable, 503),
    ])
    func mapsFunctionErrorBody(code: String, expected: APIError, status: Int) {
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: status, data: body(code))) == expected)
    }

    @Test func unknownCodesAreProviderUnavailable() {
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 400, data: body("out_of_window"))) == .providerUnavailable)
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 400, data: body("invalid_request"))) == .providerUnavailable)
    }

    /// A body that is not the backend's (gateway, worker boot failure) falls back on the status.
    @Test func mapsForeignBodiesByStatus() {
        let boot = Data(#"{"code":"BOOT_ERROR","message":"Worker failed to boot"}"#.utf8)
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 503, data: boot)) == .providerUnavailable)
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 401, data: Data("Invalid JWT".utf8))) == .unauthorized)
        #expect(SupabaseBackend.map(FunctionsError.httpError(code: 429, data: Data())) == .rateLimited)
        #expect(SupabaseBackend.map(FunctionsError.relayError) == .providerUnavailable)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                      .cannotFindHost, .dataNotAllowed])
    func mapsURLErrorToOffline(code: URLError.Code) {
        #expect(SupabaseBackend.map(URLError(code)) == .offline)
        #expect(SupabaseBackend.map(NSError(domain: NSURLErrorDomain, code: code.rawValue)) == .offline)
    }

    @Test func otherURLErrorsAreNotOffline() {
        #expect(SupabaseBackend.map(URLError(.badServerResponse)) == .providerUnavailable)
    }

    @Test func mapsPostgrestAndAuthErrors() {
        #expect(SupabaseBackend.map(PostgrestError(code: "PGRST301", message: "JWT expired")) == .unauthorized)
        #expect(SupabaseBackend.map(PostgrestError(code: "42501", message: "denied")) == .providerUnavailable)
        #expect(SupabaseBackend.map(AuthError.sessionMissing) == .unauthorized)
    }

    private func fields(_ data: Data?) throws -> [String: String] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test func buildsLookupBodyForRoute() throws {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_188_800) // 2026-10-28T12:00:00Z
        let data = SupabaseBackend.lookupBody(for: .route(origin: "CDG", destination: "SFO", date: date), timeZone: utc)
        #expect(try fields(data) == ["origin": "CDG", "destination": "SFO", "date": "2026-10-28"])
    }

    @Test func buildsLookupBodyForIdent() throws {
        let date = Date(timeIntervalSince1970: 1_793_188_800)
        let data = SupabaseBackend.lookupBody(for: .ident("AF84", date: date), timeZone: TimeZone(identifier: "UTC")!)
        #expect(try fields(data) == ["ident": "AF84", "date": "2026-10-28"])
        #expect(SupabaseBackend.lookupBody(for: .airport("KAUS")) == nil)
    }

    /// The day is the one on the calendar it was picked on, not the UTC day.
    @Test func lookupDayFollowsThePickersCalendar() {
        let lateEvening = Date(timeIntervalSince1970: 1_793_239_200) // 2026-10-29T02:00:00Z
        #expect(SupabaseBackend.day(lateEvening, in: TimeZone(identifier: "America/Los_Angeles")!) == "2026-10-28")
        #expect(SupabaseBackend.day(lateEvening, in: TimeZone(identifier: "UTC")!) == "2026-10-29")
    }

    @Test func buildsPushBody() throws {
        let id = UUID(uuidString: "9F849CB8-B065-5A02-9D37-3A28DB71E0DE")!
        let data = SupabasePushService.body(token: Data([0x0a, 0xff, 0x10]), kind: .liveActivity, flightId: id, platform: "ios")
        #expect(try fields(data) == ["token": "0aff10", "kind": "live_activity", "platform": "ios",
                                     "flightId": "9f849cb8-b065-5a02-9d37-3a28db71e0de"])
        let alert = SupabasePushService.body(token: Data([1]), kind: .alert, flightId: nil, platform: "ipados")
        #expect(try fields(alert) == ["token": "01", "kind": "alert", "platform": "ipados"])
    }

    @Test func appleNonceHashIsSHA256Hex() {
        #expect(AppleNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let n = AppleNonce.random()
        #expect(n.raw.count == 32)
        #expect(n.raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        #expect(n != AppleNonce.random())
    }

    // MARK: Decoding rows as PostgREST and Realtime send them

    @Test func decodesPostgresTimestamps() throws {
        #expect(FlightJSON.parse("2026-11-03T16:00:00.123456+00:00") != nil)
        #expect(FlightJSON.parse("2026-11-03T16:00:00+00:00") == Date(timeIntervalSince1970: 1_793_721_600))
        #expect(FlightJSON.parse("2026-11-03 16:00:00+00") == Date(timeIntervalSince1970: 1_793_721_600))
        #expect(FlightJSON.parse("2026-11-03 16:00:00.5+00") == Date(timeIntervalSince1970: 1_793_721_600.5))
        #expect(FlightJSON.parse("not a date") == nil)
    }

    @Test func decodesAFlightsRow() throws {
        let row = #"""
        [{"id":"6f1c3a52-0d8e-4c3b-9b7a-2f1e5d4c3b2a","provider_id":"AFR84-1","ident":"AF84","operator":"AF",
          "origin_icao":"LFPG","origin_iata":"CDG","destination_icao":"KSFO","destination_iata":"SFO",
          "scheduled_out":"2026-10-28T08:30:00+00:00","scheduled_in":"2026-10-28T19:40:00+00:00",
          "estimated_out":null,"estimated_in":null,"actual_out":null,"actual_off":null,"actual_on":null,"actual_in":null,
          "gate_origin":null,"gate_destination":null,"terminal_origin":"2E","terminal_destination":null,"baggage_belt":null,
          "aircraft_type":"B77W","registration":null,"status":"en_route","position_lat":60.1,"position_lon":-30.2,
          "position_altitude_ft":37000,"position_ground_speed_kt":480,"position_heading":271,
          "position_at":"2026-10-28T12:01:02.123456+00:00","alert_id":42,"updated_at":"2026-10-28T12:01:03.5+00:00"}]
        """#
        let flights = try FlightJSON.decoder.decode([Flight].self, from: Data(row.utf8))
        #expect(flights.first?.position?.altitudeFt == 37000)
        #expect(flights.first?.status == .enRoute)
    }

    @Test func decodesAPastFlightsRow() throws {
        let row = #"""
        [{"id":"0b6d1c2e-3f4a-4b5c-8d9e-0f1a2b3c4d5e","date":"2026-09-02T07:15:00+00:00","ident":"UA1630",
          "origin_icao":"KAUS","destination_icao":"KLAX","airline":"UA","aircraft_type":"B739","registration":null,
          "seat":null,"distance_km":1993,"block_minutes":null,"delay_minutes":0,"status":"completed",
          "origin_tz":"America/Chicago"}]
        """#
        let past = try SupabaseHistoryService.decode(Data(row.utf8))
        #expect(past.first?.distanceKm == 1993)
        #expect(past.first?.originTz == "America/Chicago")
    }

    // MARK: Board ids

    /// Ids that were never handed out as board rows are already `flights.id`: no lookup, no network.
    @Test func resolvesUnknownIdsToThemselves() async throws {
        let backend = SupabaseBackend(config: SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "k"),
                                      authStorage: MemoryAuthStorage())
        let service = SupabaseFlightService(backend: backend, airport: { _ in nil })
        let id = UUID()
        #expect(try await service.resolve(id) == id)
    }

    @Test func configNeedsBothInfoPlistKeys() {
        #expect(throws: SupabaseConfig.Failure.missing("SupabaseURL")) { try SupabaseConfig.fromBundle(.main) }
    }

    /// Release ships empty values unless Config.local.xcconfig sets them: the app must refuse to start.
    @Test func releaseConfigFailsClosed() throws {
        #expect(throws: SupabaseConfig.Failure.missing("SupabaseURL")) { try SupabaseConfig.from(url: "", anonKey: "") }
        #expect(throws: SupabaseConfig.Failure.missing("SupabaseURL")) {
            try SupabaseConfig.from(url: "$(SUPABASE_URL)", anonKey: "k")
        }
        #expect(throws: SupabaseConfig.Failure.missing("SupabaseAnonKey")) {
            try SupabaseConfig.from(url: "https://abc.supabase.co", anonKey: " ")
        }
        #expect(throws: SupabaseConfig.Failure.insecure("http://abc.supabase.co")) {
            try SupabaseConfig.from(url: "http://abc.supabase.co", anonKey: "k")
        }
        #expect(try SupabaseConfig.from(url: "http://127.0.0.1:58321", anonKey: "k").url.port == 58321)
        #expect(try SupabaseConfig.from(url: "https://abc.supabase.co", anonKey: "k").anonKey == "k")
    }

    @MainActor @Test func aMissingConfigSaysSoAtLaunch() {
        #expect(LaunchPlaceholder.failure(for: SupabaseConfig.Failure.missing("SupabaseURL")) == LaunchPlaceholder.configFailure)
        #expect(LaunchPlaceholder.failure(for: SupabaseConfig.Failure.insecure("http://x")) == LaunchPlaceholder.configFailure)
    }

    // MARK: Auth callback

    @Test(arguments: ["somaflight://auth-callback?code=abc", "SomaFlight://auth-callback?code=abc",
                      "somaflight://auth-callback/?code=abc&state=x"])
    func acceptsPKCECallbacks(_ raw: String) {
        #expect(SupabaseAuthService.isPKCECallback(URL(string: raw)!))
    }

    @Test(arguments: [
        "somaflight://auth-callback#access_token=a&refresh_token=b",
        "somaflight://auth-callback?code=abc#access_token=a&refresh_token=b",
        "somaflight://auth-callback?code=",
        "somaflight://auth-callback?error=access_denied",
        "somaflight://auth-callback",
        "somaflight://other?code=abc",
        "somaflight://auth-callback/extra?code=abc",
        "https://auth-callback?code=abc",
    ])
    func rejectsEverythingElse(_ raw: String) {
        #expect(!SupabaseAuthService.isPKCECallback(URL(string: raw)!))
    }

    /// A rejected URL never reaches the auth client: no network, no error, no session.
    @Test func ignoredCallbacksDoNothing() async throws {
        let auth = SupabaseAuthService(backend: unreachable())
        try await auth.handleOpenURL(URL(string: "somaflight://auth-callback#access_token=a&refresh_token=b")!)
    }

    // MARK: Realtime groups

    @Test func realtimeIdsSplitIntoChannelsOf100() {
        let ids = (0..<201).map { _ in UUID() }
        let groups = SupabaseFlightService.channelGroups(ids)
        #expect(groups.map(\.count) == [100, 100, 1])
        #expect(groups.flatMap { $0 } == ids)
        #expect(SupabaseFlightService.channelGroups(Array(ids.prefix(100))).count == 1)
        #expect(SupabaseFlightService.channelGroups(Array(ids.prefix(101))).map(\.count) == [100, 1])
        #expect(SupabaseFlightService.channelGroups([]).isEmpty)
    }

    // MARK: Push tokens

    @Test func pushRemembersTokensUntilTheyAreRemoved() async {
        let push = SupabasePushService(backend: unreachable(), defaults: nil)
        await push.unregisterDevice() // nothing registered: no call
        push.remember("0aff")
        push.remember("0aff")
        push.remember("10")
        #expect(push.registered == ["0aff", "10"])
        await push.unregisterDevice() // the backend is unreachable: the list is kept for next time
        #expect(push.registered == ["0aff", "10"])
        push.forgetDevice()
        #expect(push.registered.isEmpty)
    }

    private func unreachable() -> SupabaseBackend {
        SupabaseBackend(config: SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "k"), authStorage: MemoryAuthStorage())
    }
}

/// Session storage in memory, for tests that build a client.
final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// The backend's airport-board example files, decoded by the same functions the service uses. They
/// are read from `supabase/functions/airport-board/contract/` in the repository, so a change on the
/// backend side that the app cannot read fails here.
@Suite struct AirportBoardContractTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/airport-board/contract")

    static var files: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct Kind: Decodable { var kind: BoardKind }

    @Test func everyKindHasAnExample() {
        let names = Set(Self.files.map { $0.deletingPathExtension().lastPathComponent })
        #expect(names.isSuperset(of: ["departures", "arrivals", "stats", "weather"]), "contract files: \(names)")
    }

    @Test(arguments: files)
    func decodesContractFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        switch try JSONDecoder().decode(Kind.self, from: data).kind {
        case .departures, .arrivals:
            let board = try SupabaseAirportService.decodeBoard(data)
            #expect(!board.flights.isEmpty)
            for f in board.flights { #expect(f.position == nil) }
        case .stats:
            let stats = try SupabaseAirportService.decodeStats(data)
            #expect(stats.departures.total >= stats.departures.onTime)
        case .weather:
            let weather = try SupabaseAirportService.decodeWeather(data)
            #expect(!weather.weather.metarRaw.isEmpty)
        }
    }

    /// Board ids are UUID v5 of `provider_id` (the contract's namespace), never `flights.id`.
    @Test func boardIdsAreV5OfProviderId() throws {
        let namespace = UUID(uuidString: "7b3e1c4a-5d2f-4e8b-9a61-0c3f5d7e9b21")!
        for url in Self.files where ["departures", "arrivals"].contains(url.deletingPathExtension().lastPathComponent) {
            let board = try SupabaseAirportService.decodeBoard(try Data(contentsOf: url))
            for f in board.flights { #expect(f.id == Self.v5(namespace, f.providerId)) }
        }
    }

    static func v5(_ namespace: UUID, _ name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes += Array(name.utf8)
        var h = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        h[6] = (h[6] & 0x0f) | 0x50
        h[8] = (h[8] & 0x3f) | 0x80
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }
}
