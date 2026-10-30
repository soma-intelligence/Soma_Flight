import Foundation
import os
import Supabase

/// Where the app's backend lives: the project URL and its anon (publishable) key. Never the service key.
public struct SupabaseConfig: Sendable, Equatable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url; self.anonKey = anonKey
    }

    public enum Failure: Error, Equatable {
        /// `SupabaseURL` or `SupabaseAnonKey` is missing from Info.plist, empty, or not a URL.
        case missing(String)
        /// A plain http URL to a host that is not this machine.
        case insecure(String)
    }

    /// Reads `SupabaseURL` and `SupabaseAnonKey` from Info.plist. Debug builds get the local stack from
    /// `Config.Debug.xcconfig`; Release builds have none and need `Config.local.xcconfig` (gitignored), so
    /// a Release build without it fails here and the app says it has no server.
    public static func fromBundle(_ bundle: Bundle = .main) throws(Failure) -> SupabaseConfig {
        try from(url: bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
                 anonKey: bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String)
    }

    /// Validates raw values: both present (an unexpanded `$(...)` counts as missing), an https URL, or
    /// http only to this machine (the local stack).
    static func from(url rawURL: String?, anonKey rawKey: String?) throws(Failure) -> SupabaseConfig {
        func value(_ v: String?, _ key: String) throws(Failure) -> String {
            guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !v.hasPrefix("$(") else {
                throw .missing(key)
            }
            return v
        }
        let raw = try value(rawURL, "SupabaseURL")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw .missing("SupabaseURL")
        }
        if scheme == "http", !["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { throw .insecure(raw) }
        return SupabaseConfig(url: url, anonKey: try value(rawKey, "SupabaseAnonKey"))
    }
}

/// The one `SupabaseClient` the five services share, the JSON both ways, and the mapping of every
/// failure to `APIError`.
public final class SupabaseBackend: Sendable {
    public let client: SupabaseClient
    /// The project URL (signed storage URLs are only followed to this host).
    public let projectURL: URL
    /// Where the email sign-in link sends the user back (registered in both apps' Info.plist).
    public static let authCallback = URL(string: "somaflight://auth-callback")!

    static let log = Logger(subsystem: "me.somalabs.flight", category: "backend")

    /// - Parameter authStorage: where the session persists; nil is the Keychain. Tests pass memory.
    public init(config: SupabaseConfig, authStorage: (any AuthLocalStorage)? = nil) {
        let auth: SupabaseClientOptions.AuthOptions
        if let authStorage {
            auth = .init(storage: authStorage, redirectToURL: Self.authCallback, emitLocalSessionAsInitialSession: true)
        } else {
            auth = .init(redirectToURL: Self.authCallback, emitLocalSessionAsInitialSession: true)
        }
        projectURL = config.url
        client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey,
                                options: SupabaseClientOptions(auth: auth))
    }

    // MARK: Edge functions

    /// Calls an edge function and decodes its JSON answer with `decode` (the same path the contract
    /// tests use).
    func call<T: Sendable>(_ name: String, method: FunctionInvokeOptions.Method = .post, query: [URLQueryItem] = [],
                           body: Data? = nil, decode: @Sendable (Data) throws -> T) async throws(APIError) -> T {
        let options: FunctionInvokeOptions = if let body {
            FunctionInvokeOptions(method: method, query: query, headers: ["Content-Type": "application/json"], body: body)
        } else {
            FunctionInvokeOptions(method: method, query: query)
        }
        let data: Data
        do {
            data = try await client.functions.invoke(name, options: options) { data, _ in data }
        } catch {
            let mapped = Self.map(error)
            Self.log.error("\(name, privacy: .public) failed: \(String(describing: mapped), privacy: .public)")
            throw mapped
        }
        do { return try decode(data) } catch { throw Self.map(error) }
    }

    /// Calls an edge function that answers `{ ok: true }`.
    func call(_ name: String, method: FunctionInvokeOptions.Method = .post, body: Data) async throws(APIError) {
        _ = try await call(name, method: method, body: body) { _ in () }
    }

    // MARK: Tables

    /// Runs a PostgREST query and returns the raw JSON (decoded by the caller with `FlightJSON.decoder`).
    func rows(_ query: @Sendable (SupabaseClient) -> PostgrestBuilder) async throws(APIError) -> Data {
        do { return try await query(client).execute().data } catch { throw Self.map(error) }
    }

    /// `rows` for a query that can fail while it is built (an `update` encodes its values).
    func write(_ query: @Sendable (SupabaseClient) throws -> PostgrestBuilder) async throws(APIError) -> Data {
        do { return try await query(client).execute().data } catch { throw Self.map(error) }
    }

    // MARK: Error mapping

    /// Body of a failed edge function: `{ "error": { "code", "message" } }`.
    private struct FunctionErrorBody: Decodable {
        struct Inner: Decodable { var code: String }
        var error: Inner
    }

    /// The `APIError` an edge function's failure means. The body's `code` wins; a body that is not the
    /// backend's (gateway or boot failures) falls back on the status.
    static func functionError(status: Int, body: Data) -> APIError {
        if let parsed = try? JSONDecoder().decode(FunctionErrorBody.self, from: body) {
            return APIError(code: parsed.error.code)
        }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429: return .rateLimited
        default: return .providerUnavailable
        }
    }

    /// Connectivity failures: the request never got an answer from the server.
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]

    /// Every failure the client can throw, as the `APIError` the stores understand.
    static func map(_ error: any Error) -> APIError {
        switch error {
        case let e as APIError:
            return e
        case let e as URLError:
            return offlineCodes.contains(e.code) ? .offline : .providerUnavailable
        case let e as FunctionsError:
            switch e {
            case .httpError(let code, let data): return functionError(status: code, body: data)
            case .relayError: return .providerUnavailable
            }
        case let e as PostgrestError:
            // PGRST301/302: the JWT is missing, expired or invalid.
            if e.code == "PGRST301" || e.code == "PGRST302" { return .unauthorized }
            if e.code == "PGRST116" { return .notFound }
            return .providerUnavailable
        case let e as AuthError:
            switch e {
            case .sessionMissing, .jwtVerificationFailed: return .unauthorized
            case .api(_, _, _, let response):
                switch response.statusCode {
                case 401, 403: return .unauthorized
                case 429: return .rateLimited
                default: return .providerUnavailable
                }
            default: return .unauthorized
            }
        case let e as DecodingError:
            return .decoding(String(describing: e))
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return map(URLError(URLError.Code(rawValue: ns.code))) }
            return .providerUnavailable
        }
    }

    // MARK: Request bodies

    /// `YYYY-MM-DD` of `date` on the calendar of `timeZone` (the day the user picked).
    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The `flight-lookup` body for an ident or a route search; nil for an airport (served by boards).
    /// `timeZone` is the calendar the query's day was picked in.
    static func lookupBody(for query: FlightQuery, timeZone: TimeZone = .current) -> Data? {
        let fields: [String: String]
        switch query {
        case .ident(let ident, let date):
            fields = ["ident": ident, "date": day(date, in: timeZone)]
        case .route(let origin, let destination, let date):
            fields = ["origin": origin, "destination": destination, "date": day(date, in: timeZone)]
        case .airport:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    static func json(_ object: [String: Any]) -> Data {
        // Only strings, booleans and nulls go in: serialization cannot fail.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
