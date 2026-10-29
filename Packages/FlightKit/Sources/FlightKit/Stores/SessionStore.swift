import Foundation
import Observation
import os

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: UserSession?
    public private(set) var error: APIError?
    private let auth: any AuthService
    private let onUserChange: (@Sendable (UUID?) async throws -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let log = Logger(subsystem: "me.somalabs.flight", category: "session")

    /// - Parameter onUserChange: hands what is saved on the device to the user now signed in (nil for
    ///   nobody), wiping it when it belonged to someone else. It runs for every session the auth stream
    ///   reports, before `session` changes, so screens rebuilt for a new account never read the previous
    ///   one's data. It also runs before `signOut()` reaches the server and after a successful
    ///   `deleteAccount()`. It must be cheap when the user is unchanged. A throw sets `error` to `.localData`.
    public init(auth: any AuthService, onUserChange: (@Sendable (UUID?) async throws -> Void)? = nil) {
        self.auth = auth; self.onUserChange = onUserChange
    }

    deinit { task?.cancel() }

    /// Starts following auth state. Calling it again replaces the previous loop.
    public func start() {
        task?.cancel()
        let stream = auth.session
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                // The wipe lands before the new session is published. The auth state is the truth,
                // so it is published even when the wipe fails (the next hand-over retries it).
                await self.handOver(to: s?.userId)
                self.session = s
            }
        }
    }

    #if DEBUG
    /// Previews and snapshots: sets the state a screen shows without running the auth flow.
    func seed(session: UserSession? = nil, error: APIError? = nil) {
        self.session = session; self.error = error
    }
    #endif

    /// Wipes the device first, then signs out: an app killed between the two keeps nothing of the account.
    /// When the wipe fails the account stays signed in and `error` is `.localData`, so the user can retry.
    public func signOut() async {
        guard await handOver(to: nil) else { return }
        await auth.signOut()
    }

    /// On failure `error` is set and the session stays.
    public func deleteAccount() async {
        do {
            try await auth.deleteAccount()
            error = nil
            await handOver(to: nil)
        } catch { self.error = error }
    }

    @discardableResult
    private func handOver(to user: UUID?) async -> Bool {
        guard let onUserChange else { return true }
        do {
            try await onUserChange(user)
            if error == .localData { error = nil }
            return true
        } catch {
            Self.log.error("Wiping the device's saved data failed: \(String(describing: error), privacy: .public)")
            self.error = .localData
            return false
        }
    }
}
