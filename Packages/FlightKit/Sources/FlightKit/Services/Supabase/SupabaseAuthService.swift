import Foundation
import Supabase

/// Supabase Auth: Sign in with Apple (an Apple identity token and the raw nonce whose SHA256 the
/// request carried), an email magic link that comes back through `somaflight://auth-callback`, and
/// account deletion through `delete-account`.
public final class SupabaseAuthService: AuthService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    private var auth: AuthClient { backend.client.auth }

    private struct ProfileRow: Decodable { var plan: Plan }

    /// The account's plan from `profiles` (free when it cannot be read).
    private func plan(for user: UUID) async -> Plan {
        let id = user.uuidString.lowercased()
        guard let data = try? await backend.rows({ $0.from("profiles").select("plan").eq("user_id", value: id).limit(1) }),
              let row = try? FlightJSON.decoder.decode([ProfileRow].self, from: data).first else { return .free }
        return row.plan
    }

    /// Follows Supabase's auth state. The stored session is reported at once, expired or not: it is
    /// refreshed in the background, and reporting nobody while offline would hand the device's saved
    /// flights to nobody. The plan is read once per user.
    public var session: AsyncStream<UserSession?> {
        let (stream, continuation) = AsyncStream<UserSession?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = auth.authStateChanges
        let task = Task { [weak self] in
            var plans: [UUID: Plan] = [:]
            var last: UserSession??
            for await (_, session) in changes {
                guard let self else { break }
                var next: UserSession?
                if let user = session?.user {
                    let plan: Plan
                    if let known = plans[user.id] { plan = known } else {
                        plan = await self.plan(for: user.id)
                        plans[user.id] = plan
                    }
                    next = UserSession(userId: user.id, email: user.email, plan: plan)
                }
                if last != .some(next) {
                    last = .some(next)
                    continuation.yield(next)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func signInWithApple(idToken: String, nonce: String) async throws(APIError) {
        do {
            _ = try await auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        } catch { throw SupabaseBackend.map(error) }
    }

    /// Sends the magic link. Locally it lands in the stack's mail catcher (Mailpit).
    public func signInWithEmail(_ email: String) async throws(APIError) {
        do {
            try await auth.signInWithOTP(email: email, redirectTo: SupabaseBackend.authCallback, shouldCreateUser: true)
        } catch { throw SupabaseBackend.map(error) }
    }

    /// The magic link's way back: `somaflight://auth-callback?code=…` becomes a session. Other URLs are
    /// not for auth and are ignored.
    public func handleOpenURL(_ url: URL) async throws(APIError) {
        guard url.scheme == SupabaseBackend.authCallback.scheme, url.host() == SupabaseBackend.authCallback.host() else { return }
        do { _ = try await auth.session(from: url) } catch { throw SupabaseBackend.map(error) }
    }

    /// Ends the session here and on the server; a failed server call still clears the local session.
    public func signOut() async {
        do { try await auth.signOut() } catch {
            try? await auth.signOut(scope: .local)
        }
    }

    /// Erases the account on the server, then forgets the session (its user no longer exists).
    public func deleteAccount() async throws(APIError) {
        try await backend.call("delete-account", body: Data("{}".utf8))
        try? await auth.signOut(scope: .local)
    }
}
