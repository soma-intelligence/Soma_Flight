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
    func signInWithApple(idToken: String, nonce: String) async throws(APIError)
    func signInWithEmail(_ email: String) async throws(APIError)
    func signOut() async
    func deleteAccount() async throws(APIError)
}
