import Foundation
import Supabase

/// `sms-verify` (POST, signed in): one action per call. A refusal comes back as the backend's error body,
/// whose message is shown as it is ("This number is already used by another account").
public final class SupabaseTextAlertsService: TextAlertsService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    struct Checked: Decodable, Sendable {
        var result: TextCodeResult
        var triesLeft: Int
    }

    struct ErrorBody: Decodable {
        struct Inner: Decodable { var code: String; var message: String? }
        var error: Inner
    }

    static func body(_ action: String, _ fields: [String: Any?] = [:]) -> Data {
        var object: [String: Any] = ["action": action]
        for (k, v) in fields { object[k] = v ?? NSNull() }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// The error a failed call means: offline, the backend's own words for a refusal, else unavailable.
    static func error(status: Int, body: Data) -> TextAlertsError {
        guard let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body) else { return .unavailable }
        if parsed.error.code == "provider_unavailable" || status >= 500 { return .unavailable }
        return .refused(parsed.error.message ?? "That did not work. Try again.")
    }

    private func invoke(_ body: Data) async throws(TextAlertsError) -> Data {
        let options = FunctionInvokeOptions(method: .post, headers: ["Content-Type": "application/json"], body: body)
        do {
            return try await backend.client.functions.invoke("sms-verify", options: options) { data, _ in data }
        } catch let FunctionsError.httpError(code, data) {
            throw Self.error(status: code, body: data)
        } catch {
            throw SupabaseBackend.map(error) == .offline ? .offline : .unavailable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(TextAlertsError) -> T {
        do { return try FlightJSON.decoder.decode(type, from: data) } catch { throw .unavailable }
    }

    public func status(flight: Flight.ID?) async throws(TextAlertsError) -> TextAlertsStatus {
        try decode(TextAlertsStatus.self, try await invoke(Self.body("status", ["flightId": flight?.uuidString.lowercased()])))
    }

    public func start(phone: String) async throws(TextAlertsError) -> TextAlertsStatus {
        try decode(TextAlertsStatus.self, try await invoke(Self.body("start", ["phone": phone])))
    }

    public func check(code: String) async throws(TextAlertsError) -> (TextCodeResult, TextAlertsStatus, triesLeft: Int) {
        let data = try await invoke(Self.body("check", ["code": code]))
        let c = try decode(Checked.self, data)
        return (c.result, try decode(TextAlertsStatus.self, data), c.triesLeft)
    }

    public func set(enabled: Bool?, inFlight: Bool?) async throws(TextAlertsError) -> TextAlertsStatus {
        var fields: [String: Any?] = [:]
        if let enabled { fields["enabled"] = enabled }
        if let inFlight { fields["inFlight"] = inFlight }
        return try decode(TextAlertsStatus.self, try await invoke(Self.body("settings", fields)))
    }

    public func setFlight(_ flight: Flight.ID, inFlight: Bool?) async throws(TextAlertsError) {
        _ = try await invoke(Self.body("flight", ["flightId": flight.uuidString.lowercased(), "inFlight": inFlight]))
    }

    public func forget() async throws(TextAlertsError) -> TextAlertsStatus {
        try decode(TextAlertsStatus.self, try await invoke(Self.body("forget")))
    }
}
