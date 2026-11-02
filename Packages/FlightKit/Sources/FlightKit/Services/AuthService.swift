import Foundation

public struct UserSession: Sendable, Equatable {
    public var userId: UUID
    public var email: String?
    /// The account signs in with Apple: deleting it needs a fresh Apple authorization (token revocation).
    public var usesApple: Bool

    public init(userId: UUID, email: String?, usesApple: Bool = false) {
        self.userId = userId; self.email = email; self.usesApple = usesApple
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
    /// Erases the account on the server. An account that signs in with Apple sends the authorization
    /// code of a fresh Apple sign-in, which the server uses to revoke the account's Apple tokens.
    func deleteAccount(appleAuthorizationCode: String?) async throws(APIError)
}

public extension AuthService {
    /// Services without a link flow (the fakes) have nothing to do.
    func handleOpenURL(_ url: URL) async throws(APIError) {}

    /// Apple sign-in without a name (every authorization after the first).
    func signInWithApple(idToken: String, nonce: String) async throws(APIError) {
        try await signInWithApple(idToken: idToken, nonce: nonce, fullName: nil)
    }

    func signInWithGoogle() async throws(APIError) { throw .providerUnavailable }

    /// Deletion without an Apple authorization (email and Google accounts).
    func deleteAccount() async throws(APIError) {
        try await deleteAccount(appleAuthorizationCode: nil)
    }
}
