import Foundation
import Supabase
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Device and Live Activity tokens go through the `register-push-token` function. Clients cannot write
/// `push_tokens` themselves: the function checks the follow and moves a token between accounts.
public final class SupabasePushService: PushService {
    private let backend: SupabaseBackend
    /// Where the tokens this device registered are remembered, so sign-out can remove them.
    /// UserDefaults is documented thread-safe; it is only not marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults?
    private let memory = Mutex<[String]>([])
    static let registeredKey = "push.registeredTokens"

    /// - Parameter defaults: where registered tokens persist across launches; nil keeps them in memory.
    public init(backend: SupabaseBackend, defaults: UserDefaults? = .standard) {
        self.backend = backend; self.defaults = defaults
    }

    /// Hex tokens this device registered and has not removed yet.
    var registered: [String] {
        if let defaults { return defaults.stringArray(forKey: Self.registeredKey) ?? [] }
        return memory.withLock { $0 }
    }

    private func setRegistered(_ tokens: [String]) {
        if let defaults {
            if tokens.isEmpty { defaults.removeObject(forKey: Self.registeredKey) } else { defaults.set(tokens, forKey: Self.registeredKey) }
        } else {
            memory.withLock { $0 = tokens }
        }
    }

    func remember(_ hex: String) {
        let current = registered
        if !current.contains(hex) { setRegistered(current + [hex]) }
    }

    /// The function takes `ios` or `ipados`; the Mac gets no pushes from this backend.
    @MainActor static var platform: String? {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        nil
        #endif
    }

    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    static func body(token: Data, kind: PushTokenKind, flightId: Flight.ID?, platform: String) -> Data {
        var fields: [String: Any] = [
            "token": hex(token),
            "kind": kind.rawValue,
            "platform": platform,
        ]
        if let flightId { fields["flightId"] = flightId.uuidString.lowercased() }
        return SupabaseBackend.json(fields)
    }

    /// On the Mac this does nothing: the backend only sends to iPhone and iPad.
    public func register(deviceToken: Data, kind: PushTokenKind, flightId: Flight.ID?) async throws(APIError) {
        guard let platform = await Self.platform else { return }
        try await backend.call("register-push-token",
                               body: Self.body(token: deviceToken, kind: kind, flightId: flightId, platform: platform))
        remember(Self.hex(deviceToken))
    }

    /// Deletes this device's rows from `push_tokens`. Clients keep delete there (RLS: own rows only) for
    /// exactly this; inserts and updates go through the function. A failure keeps the list for next time.
    public func unregisterDevice() async {
        let tokens = registered
        guard !tokens.isEmpty else { return }
        do {
            _ = try await backend.rows { $0.from("push_tokens").delete().in("token", values: tokens) }
            setRegistered([])
        } catch {
            SupabaseBackend.log.error("push tokens not removed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The account is gone and the backend erased its tokens: only the local list is cleared.
    func forgetDevice() { setRegistered([]) }
}
