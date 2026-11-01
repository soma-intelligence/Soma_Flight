import AuthenticationServices
import Foundation
import Supabase

/// Supabase Auth: Sign in with Apple (an Apple identity token and the raw nonce whose SHA256 the
/// request carried), an email magic link that comes back through `somaflight://auth-callback`, and
/// account deletion through `delete-account`.
public final class SupabaseAuthService: AuthService {
    private let backend: SupabaseBackend
    private let push: SupabasePushService?

    /// - Parameter push: whose device tokens sign-out removes while the session is still valid.
    public init(backend: SupabaseBackend, push: SupabasePushService? = nil) {
        self.backend = backend; self.push = push
    }

    private var auth: AuthClient { backend.client.auth }

    private struct ProfileRow: Decodable { var plan: Plan }

    /// The account's plan from `profiles`; nil when it cannot be read (offline), so it is read again later.
    private func plan(for user: UUID) async -> Plan? {
        let id = user.uuidString.lowercased()
        guard let data = try? await backend.rows({ $0.from("profiles").select("plan").eq("user_id", value: id).limit(1) }),
              let row = try? FlightJSON.decoder.decode([ProfileRow].self, from: data).first else { return nil }
        return row.plan
    }

    /// Follows Supabase's auth state. The stored session is reported at once, expired or not: it is
    /// refreshed in the background, and reporting nobody while offline would hand the device's saved
    /// flights to nobody. The plan is read once per user, once a read succeeds.
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
                    // A plan that could not be read shows as free and is read again on the next auth event
                    // (token refreshes come at least hourly).
                    let plan: Plan
                    if let known = plans[user.id] { plan = known } else if let read = await self.plan(for: user.id) {
                        plan = read
                        plans[user.id] = read
                    } else {
                        plan = .free
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

    public func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws(APIError) {
        let session: Session
        do {
            session = try await auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        } catch { throw SupabaseBackend.map(error) }
        if let name = Self.appleName(fullName) {
            await saveAppleName(name, user: session.user.id)
        }
    }

    /// Apple's given and family names, trimmed; nil when Apple gave none (every sign-in after the first).
    static func appleName(_ components: PersonNameComponents?) -> (given: String?, family: String?, full: String)? {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : String(t.prefix(DisplayName.maxLength))
        }
        let given = clean(components?.givenName), family = clean(components?.familyName)
        guard given != nil || family != nil else { return nil }
        return (given, family, DisplayName.join(first: given ?? "", last: family ?? ""))
    }

    /// Keeps Apple's one-time name: in the account's metadata (`full_name`, `given_name`, `family_name`, what
    /// Google fills too) and in the profile's names when they are still empty. Best effort: sign-in has
    /// already succeeded, and the session store keeps the name in memory for onboarding if a write fails.
    private func saveAppleName(_ name: (given: String?, family: String?, full: String), user: UUID) async {
        var data: [String: AnyJSON] = ["full_name": .string(name.full)]
        if let g = name.given { data["given_name"] = .string(g) }
        if let f = name.family { data["family_name"] = .string(f) }
        _ = try? await auth.update(user: UserAttributes(data: data))
        struct Row: Encodable, Sendable {
            var first_name: String?
            var last_name: String?
            var display_name: String
        }
        let id = user.uuidString.lowercased()
        let row = Row(first_name: name.given, last_name: name.family, display_name: name.full)
        _ = try? await backend.write {
            try $0.from("profiles").update(row).eq("user_id", value: id).is("first_name", value: nil).is("last_name", value: nil)
        }
    }

    /// Google through the web: an `ASWebAuthenticationSession` on Supabase's authorize URL (PKCE), back
    /// through `somaflight://auth-callback`. Works once the owner turns the provider on (docs/profile-onboarding.md).
    public func signInWithGoogle() async throws(APIError) {
        do {
            _ = try await auth.signInWithOAuth(provider: .google, redirectTo: SupabaseBackend.authCallback)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return
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
        guard Self.isPKCECallback(url) else { return }
        do { _ = try await auth.session(from: url) } catch { throw SupabaseBackend.map(error) }
    }

    /// Only a PKCE callback is taken: `somaflight://auth-callback?code=<non-empty>` with no fragment. Any
    /// app can open the scheme, and a fragment carrying implicit-flow tokens would sign this device into
    /// whatever account those tokens belong to; a PKCE code is useless without this app's stored verifier.
    static func isPKCECallback(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == SupabaseBackend.authCallback.scheme,
              parts.host?.lowercased() == SupabaseBackend.authCallback.host(),
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return false }
        return true
    }

    static let unregisterLimit = Duration.seconds(4)

    /// Removes this device's push tokens (waiting at most `unregisterLimit`), then ends the session here and on the server; a failed server
    /// call still clears the local session.
    public func signOut() async {
        // Offline, the request would hold sign-out for the URLSession timeout; the token list is kept
        // when it does not finish, and removed at the next sign-out.
        if let push { await waitingAtMost(Self.unregisterLimit) { await push.unregisterDevice() } }
        do { try await auth.signOut() } catch {
            try? await auth.signOut(scope: .local)
        }
    }

    /// Erases the account on the server, then forgets the session (its user no longer exists).
    public func deleteAccount() async throws(APIError) {
        try await backend.call("delete-account", body: Data("{}".utf8))
        push?.forgetDevice()
        try? await auth.signOut(scope: .local)
    }
}
