import Foundation
import Observation

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: UserSession?
    public private(set) var error: APIError?
    private let auth: any AuthService
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(auth: any AuthService) { self.auth = auth }

    deinit { task?.cancel() }

    /// Starts following auth state. Calling it again replaces the previous loop.
    public func start() {
        task?.cancel()
        let stream = auth.session
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                self.session = s
            }
        }
    }

    public func signOut() async {
        await auth.signOut()
    }

    /// On failure `error` is set and the session stays.
    public func deleteAccount() async {
        do {
            try await auth.deleteAccount()
            error = nil
        } catch { self.error = error }
    }
}
