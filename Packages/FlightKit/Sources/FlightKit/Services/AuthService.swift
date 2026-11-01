import Foundation

public enum Plan: String, Sendable, Hashable, Codable {
    case free, pro
}

public struct UserSession: Sendable, Equatable {
    public var userId: UUID
    public var email: String?
    public var plan: Plan

    public init(userId: UUID, email: String?, plan: Plan) {
        self.userId = userId; self.email = email; self.plan = plan
    }
}

public protocol AuthService: Sendable {
    var session: AsyncStream<UserSession?> { get }
    /// Signs in with Apple's identity token. `fullName` is the name Apple hands over on the first
    /// authorization only (never again, never a photo): the service saves it to the profile and the account's
    /// metadata at once, so it is not lost.
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws(APIError)
    /// Google through Supabase's web OAuth flow, back through `somaflight://auth-callback`. Off until the owner
    /// switches the provider on (docs/profile-onboarding.md); services without it throw `.providerUnavailable`.
    func signInWithGoogle() async throws(APIError)
    func signInWithEmail(_ email: String) async throws(APIError)
    /// The email link coming back to the app (`somaflight://auth-callback`). Other URLs are ignored.
    func handleOpenURL(_ url: URL) async throws(APIError)
    func signOut() async
    func deleteAccount() async throws(APIError)
}

public extension AuthService {
    /// Services without a link flow (the fakes) have nothing to do.
    func handleOpenURL(_ url: URL) async throws(APIError) {}

    /// Apple sign-in without a name (every authorization after the first).
    func signInWithApple(idToken: String, nonce: String) async throws(APIError) {
        try await signInWithApple(idToken: idToken, nonce: nonce, fullName: nil)
    }

    func signInWithGoogle() async throws(APIError) { throw .providerUnavailable }
}
