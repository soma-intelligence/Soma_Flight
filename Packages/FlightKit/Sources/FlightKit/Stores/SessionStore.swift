import Foundation
import Observation

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: UserSession?
    public private(set) var error: APIError?
    private let auth: any AuthService
    private let onSignedOut: (@Sendable () async -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameter onSignedOut: runs after sign-out, after account deletion and whenever the session
    ///   ends on its own, to wipe what the account left on the device (cache, recent searches).
    public init(auth: any AuthService, onSignedOut: (@Sendable () async -> Void)? = nil) {
        self.auth = auth; self.onSignedOut = onSignedOut
    }

    deinit { task?.cancel() }

    /// Starts following auth state. Calling it again replaces the previous loop.
    public func start() {
        task?.cancel()
        let stream = auth.session
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                let ended = self.session != nil && s == nil
                self.session = s
                if ended { await self.onSignedOut?() }
            }
        }
    }

    #if DEBUG
    /// Previews and snapshots: sets the state a screen shows without running the auth flow.
    func seed(session: UserSession? = nil, error: APIError? = nil) {
        self.session = session; self.error = error
    }
    #endif

    public func signOut() async {
        await auth.signOut()
        await onSignedOut?()
    }

    /// On failure `error` is set and the session stays.
    public func deleteAccount() async {
        do {
            try await auth.deleteAccount()
            error = nil
            await onSignedOut?()
        } catch { self.error = error }
    }
}
