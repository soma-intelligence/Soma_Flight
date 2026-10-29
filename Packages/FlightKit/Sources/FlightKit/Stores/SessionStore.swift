import Foundation
import Observation

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: UserSession?
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

    public func signOut() {
        Task { [auth] in await auth.signOut() }
    }

    public func deleteAccount() async {
        try? await auth.deleteAccount()
    }
}
