import Foundation
@testable import FlightKit
import Supabase
import Synchronization
import Testing

/// Smoke test against the LOCAL Supabase stack (`npx supabase start` and `npx supabase functions serve`).
/// Off unless `INTEGRATION=1`. It signs a throwaway user in with the magic link the stack's mail catcher
/// received (opened the way the app opens it), calls the services the app uses, and deletes the user.
///
/// Environment: `SUPABASE_URL` (default http://127.0.0.1:58321), `SUPABASE_ANON_KEY` (default the local
/// demo anon key), `MAILPIT_URL` (default http://127.0.0.1:58324), and `INTEGRATION_SERVICE_KEY`, the
/// local service role key, used only here to delete the test user. Never commit that key.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] == "1"), .serialized)
struct SupabaseIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    /// `npx supabase status` prints it; it is the public demo key of every local stack.
    static let localAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    static let url = URL(string: env["SUPABASE_URL"] ?? "http://127.0.0.1:58321")!
    static let mailpit = URL(string: env["MAILPIT_URL"] ?? "http://127.0.0.1:58324")!

    @Test func localStackSmoke() async throws {
        let backend = SupabaseBackend(config: SupabaseConfig(url: Self.url, anonKey: env("SUPABASE_ANON_KEY") ?? Self.localAnonKey),
                                      authStorage: MemoryAuthStorage())
        let auth = SupabaseAuthService(backend: backend)
        let directory = AirportDirectory.bundled()
        let flights = SupabaseFlightService(backend: backend, airport: directory.lookup)
        let airports = SupabaseAirportService(backend: backend, airport: directory.lookup)
        let history = SupabaseHistoryService(backend: backend)

        // Sign up through the app's own call, open the mailed link, and hand its code back the way the
        // app's URL handler does (somaflight://auth-callback?code=...).
        let email = "flight-it-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let sessions = auth.session
        try await auth.signInWithEmail(email)
        let code = try await Self.linkCode(to: email)
        var callback = URLComponents(url: SupabaseBackend.authCallback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: code)]
        try await auth.handleOpenURL(callback.url!)
        var signedIn: UserSession?
        for await s in sessions where s != nil { signedIn = s; break }
        let user = try #require(signedIn)
        print("INTEGRATION signed in \(user.userId) plan=\(user.plan)")
        #expect(user.email == email)
        #expect(user.plan == .free)

        var failure: (any Error)?
        do { try await checks(auth: auth, flights: flights, airports: airports, history: history) } catch { failure = error }
        await Self.deleteUser(user.userId)
        if let failure { throw failure }
    }

    /// The brand chain, end to end on the local stack: run `brand-assets-sync` first with
    /// `LOGO_PROVIDER=commons` (see docs/operations.md), then `INTEGRATION=1 INTEGRATION_BRAND=1`. A signed-in
    /// user asks `brand-asset` for the UAL, DLH and AFR logos through `SupabaseBrandAssetService`: the signed
    /// paths join the app's project URL (127.0.0.1, while the function signs on kong:8000) and come back as
    /// PNG bytes. The cache lives in a temporary folder removed at the end.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTEGRATION_BRAND"] == "1"))
    func brandChainServesLogos() async throws {
        let backend = SupabaseBackend(config: SupabaseConfig(url: Self.url, anonKey: env("SUPABASE_ANON_KEY") ?? Self.localAnonKey),
                                      authStorage: MemoryAuthStorage())
        let auth = SupabaseAuthService(backend: backend)
        let email = "flight-brand-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let sessions = auth.session
        try await auth.signInWithEmail(email)
        let code = try await Self.linkCode(to: email)
        var callback = URLComponents(url: SupabaseBackend.authCallback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: code)]
        try await auth.handleOpenURL(callback.url!)
        var signedIn: UserSession?
        for await s in sessions where s != nil { signedIn = s; break }
        let user = try #require(signedIn)
        let dir = FileManager.default.temporaryDirectory.appending(path: "brand-chain-\(UUID().uuidString)")
        var failure: (any Error)?
        do {
            let service = SupabaseBrandAssetService(backend: backend, cacheDir: dir)
            for icao in ["UAL", "DLH", "AFR"] {
                let lookup = await service.lookup(icao, .logo, type: nil)
                let asset = try #require(lookup.asset, "\(icao) logo -> \(lookup)")
                let png = asset.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                print("INTEGRATION brand \(icao) logo -> v\(asset.version) \(asset.format) \(asset.data.count) bytes png=\(png)")
                #expect(png && asset.format == "png" && asset.decodes)
            }
        } catch { failure = error }
        try? FileManager.default.removeItem(at: dir)
        await auth.signOut()
        await Self.deleteUser(user.userId)
        if let failure { throw failure }
    }

    private func checks(auth: SupabaseAuthService, flights: SupabaseFlightService, airports: SupabaseAirportService,
                        history: SupabaseHistoryService) async throws {
        // No AEROAPI_KEY locally: the lookup fails and must surface as providerUnavailable.
        do {
            let found = try await flights.lookup(.ident("UA1630", date: .now))
            Issue.record("lookup unexpectedly answered \(found.count) flights")
        } catch {
            print("INTEGRATION flight-lookup -> \(error)")
            #expect(error == .providerUnavailable)
        }

        // Weather comes from aviationweather.gov (free). It may work, or the function may not run here;
        // either way it must never be a decoding failure.
        do {
            let w = try await airports.weather("KAUS")
            print("INTEGRATION weather KAUS -> \(w.weather.category) observed \(w.weather.observedAt) stale=\(w.stale)")
        } catch {
            print("INTEGRATION weather KAUS -> \(error)")
            #expect(error == .providerUnavailable || error == .notFound)
        }

        let past = try await history.pastFlights()
        print("INTEGRATION past flights -> \(past.count)")
        #expect(past.isEmpty)

        let followed = try await flights.followed()
        print("INTEGRATION followed -> \(followed.count)")
        #expect(followed.isEmpty)

        try await realtime(flights)

        do {
            try await auth.deleteAccount()
            print("INTEGRATION delete-account -> ok")
        } catch {
            print("INTEGRATION delete-account -> \(error)")
        }
        await auth.signOut()
    }

    private func env(_ key: String) -> String? { Self.env[key] }

    /// Realtime: a flights row written with the service key (clients cannot write flights), then
    /// `updates(for:)` must yield it once on join and again after an UPDATE. Without the key it only
    /// subscribes and cancels.
    private func realtime(_ flights: SupabaseFlightService) async throws {
        guard let key = Self.env["INTEGRATION_SERVICE_KEY"] else {
            let listener = Task { for await _ in flights.updates(for: [UUID()]) {} }
            try await Task.sleep(for: .seconds(2))
            listener.cancel()
            await listener.value
            print("INTEGRATION realtime subscribe and cancel ok (no service key, no row)")
            return
        }
        let id = UUID()
        let pid = "INTEGRATION-\(id.uuidString.lowercased())"
        let row: [String: Any] = ["id": id.uuidString.lowercased(), "provider_id": pid, "ident": "ZZ1",
                                  "origin_icao": "KAUS", "destination_icao": "KLAX", "status": "scheduled"]
        _ = try await Self.rest("POST", "rest/v1/flights", key: key, body: row)
        defer { Task { _ = try? await Self.rest("DELETE", "rest/v1/flights?id=eq.\(id.uuidString.lowercased())", key: key) } }

        let seen = Seen()
        let listener = Task { for await f in flights.updates(for: [id]) { seen.add(f) } }
        let first = try #require(await seen.next(after: 0, within: .seconds(10)))
        #expect(first.status == .scheduled)
        print("INTEGRATION realtime join read -> \(first.status)")
        _ = try await Self.rest("PATCH", "rest/v1/flights?id=eq.\(id.uuidString.lowercased())", key: key,
                                body: ["status": "departed", "gate_origin": "B6"])
        let changed = try #require(await seen.next(after: 1, within: .seconds(10)))
        print("INTEGRATION realtime update -> \(changed.status) gate \(changed.gateOrigin ?? "nil")")
        #expect(changed.status == .departed)
        #expect(changed.gateOrigin == "B6")
        listener.cancel()
        await listener.value
        _ = try await Self.rest("DELETE", "rest/v1/flights?id=eq.\(id.uuidString.lowercased())", key: key)
        print("INTEGRATION realtime cancel ok")
    }

    /// What a stream yielded, polled by the test.
    final class Seen: Sendable {
        private let items = Mutex<[Flight]>([])
        func add(_ f: Flight) { items.withLock { $0.append(f) } }
        /// The item at `index` once it arrives, or nil after `limit`.
        func next(after index: Int, within limit: Duration) async -> Flight? {
            let end = ContinuousClock.now + limit
            while ContinuousClock.now < end {
                if let f = items.withLock({ $0.count > index ? $0[index] : nil }) { return f }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
    }

    @discardableResult
    static func rest(_ method: String, _ path: String, key: String, body: [String: Any]? = nil) async throws -> Int {
        var request = URLRequest(url: URL(string: path, relativeTo: url)!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw APIError.providerUnavailable }
        return status
    }

    /// Opens the newest sign-in link mailed to `address` (waiting up to 10 seconds) without following
    /// its redirect, and returns the PKCE `code` the redirect carries.
    static func linkCode(to address: String) async throws -> String {
        for _ in 0..<20 {
            var search = URLComponents(url: mailpit.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)!
            search.queryItems = [URLQueryItem(name: "query", value: "to:\"\(address)\"")]
            let (data, _) = try await URLSession.shared.data(from: search.url!)
            struct Search: Decodable { struct Message: Decodable { var ID: String }; var messages: [Message] }
            if let id = try JSONDecoder().decode(Search.self, from: data).messages.first?.ID {
                let (body, _) = try await URLSession.shared.data(from: mailpit.appending(path: "api/v1/message/\(id)"))
                struct Message: Decodable { var Text: String }
                let text = try JSONDecoder().decode(Message.self, from: body).Text
                guard let m = text.firstMatch(of: /(https?:\/\/[^\s)]+\/auth\/v1\/verify[^\s)]+)/),
                      let link = URL(string: String(m.1)) else { throw APIError.notFound }
                let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
                let (_, response) = try await session.data(from: link)
                let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
                print("INTEGRATION magic link redirects to \(location.split(separator: "?").first ?? "")")
                guard let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    throw APIError.unauthorized
                }
                return code
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw APIError.notFound
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Deletes the test user through the Auth admin API with the local service role key.
    static func deleteUser(_ id: UUID) async {
        guard let key = env["INTEGRATION_SERVICE_KEY"] else {
            print("INTEGRATION cleanup skipped: no INTEGRATION_SERVICE_KEY, user \(id) left in the local stack")
            return
        }
        var request = URLRequest(url: url.appending(path: "auth/v1/admin/users/\(id.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let status = (try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse
        // The profile outlives its auth user by design (status deleted); a test user leaves nothing.
        let uid = id.uuidString.lowercased()
        let rate = try? await rest("DELETE", "rest/v1/rate_events?user_id=eq.\(uid)", key: key)
        let profile = try? await rest("DELETE", "rest/v1/profiles?user_id=eq.\(uid)", key: key)
        print("INTEGRATION cleanup user \(id) -> auth \(status?.statusCode ?? -1), rate events \(rate ?? -1), profile \(profile ?? -1)")
    }
}
