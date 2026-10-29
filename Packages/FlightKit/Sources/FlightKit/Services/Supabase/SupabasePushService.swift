import Foundation
import Supabase
#if os(iOS)
import UIKit
#endif

/// Device and Live Activity tokens go through the `register-push-token` function. Clients cannot write
/// `push_tokens` themselves: the function checks the follow and moves a token between accounts.
public final class SupabasePushService: PushService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The function takes `ios` or `ipados`; the Mac gets no pushes from this backend.
    @MainActor static var platform: String? {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        nil
        #endif
    }

    static func body(token: Data, kind: PushTokenKind, flightId: Flight.ID?, platform: String) -> Data {
        var fields: [String: Any] = [
            "token": token.map { String(format: "%02x", $0) }.joined(),
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
    }
}
