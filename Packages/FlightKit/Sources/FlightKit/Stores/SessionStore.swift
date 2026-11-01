import Foundation
import Observation
import os

@MainActor @Observable
public final class SessionStore {
    public private(set) var session: UserSession?
    public private(set) var error: APIError?
    /// False until the auth stream has reported once: before that nobody is known to be signed out, so
    /// the shells do not flash Sign In at launch.
    public private(set) var isResolved = false
    private let auth: any AuthService
    private let onUserChange: (@Sendable (UUID?) async throws -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    private let retryDelays: [Duration]

    private static let log = Logger(subsystem: "me.somalabs.flight", category: "session")

    /// - Parameter onUserChange: hands what is saved on the device to the user now signed in (nil for
    ///   nobody), wiping it when it belonged to someone else. It runs for every session the auth stream
    ///   reports, before `session` changes, so screens rebuilt for a new account never read the previous
    ///   one's data. It also runs before `signOut()` reaches the server and after a successful
    ///   `deleteAccount()`. It must be cheap when the user is unchanged. A throw sets `error` to `.localData`.
    /// - Parameter retryDelays: the waits before each new try when handing the device to a newly signed-in
    ///   account fails.
    public init(auth: any AuthService, onUserChange: (@Sendable (UUID?) async throws -> Void)? = nil,
                retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(60)]) {
        self.auth = auth; self.onUserChange = onUserChange; self.retryDelays = retryDelays
    }

    deinit { task?.cancel(); retryTask?.cancel() }

    /// Starts following auth state unless it already does.
    public func startIfNeeded() {
        guard task == nil else { return }
        start()
    }

    /// Starts following auth state. Calling it again replaces the previous loop.
    public func start() {
        task?.cancel()
        let stream = auth.session
        task = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                await self.follow(s)
            }
        }
    }

    /// Publishes `s` only once the device's saved data is handed to its user, so a new account never sees
    /// the previous one's. When that wipe fails, nobody is shown as signed in (the stores then read an
    /// empty cache), `error` is `.localData`, and the hand-over is tried again a few times; the next auth
    /// event tries again too.
    private func follow(_ s: UserSession?) async {
        retryTask?.cancel()
        defer { isResolved = true }
        if await handOver(to: s?.userId) {
            session = s
            return
        }
        session = nil
        guard let s else { return }
        let delays = retryDelays
        retryTask = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                if await self.handOver(to: s.userId) {
                    guard !Task.isCancelled else { return }
                    self.session = s
                    return
                }
            }
        }
    }

    #if DEBUG
    /// Previews and snapshots: sets the state a screen shows without running the auth flow.
    func seed(session: UserSession? = nil, error: APIError? = nil) {
        self.session = session; self.error = error
    }
    #endif

    // MARK: Signing in

    /// Sign in with Apple: the identity token and the raw nonce whose hash the request carried. The session
    /// arrives through the auth stream; on failure `error` is set.
    public func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents? = nil) async {
        // Apple gives the name once: kept here too, so onboarding can prefill it even if saving it failed.
        if let fullName, fullName.givenName?.isEmpty == false || fullName.familyName?.isEmpty == false {
            appleName = fullName
        }
        do {
            try await auth.signInWithApple(idToken: idToken, nonce: nonce, fullName: fullName)
            error = nil
        } catch { self.error = error }
    }

    /// The name Apple handed over at this launch's sign-in, if any (Apple gives it only on the first
    /// authorization). Onboarding adds it to what the account's metadata says.
    public private(set) var appleName: PersonNameComponents?

    /// Google sign-in (web OAuth); the session arrives through the auth stream. On failure `error` is set.
    public func signInWithGoogle() async {
        do {
            try await auth.signInWithGoogle()
            error = nil
        } catch { self.error = error }
    }

    /// Sends the sign-in link; true when it went out. On failure `error` is set.
    public func signInWithEmail(_ email: String) async -> Bool {
        do {
            try await auth.signInWithEmail(email)
            error = nil
            return true
        } catch {
            self.error = error
            return false
        }
    }

    /// A URL the app was opened with: the email link's way back becomes a session.
    public func handle(url: URL) async {
        do {
            try await auth.handleOpenURL(url)
        } catch { self.error = error }
    }

    /// Wipes the device first, then signs out: an app killed between the two keeps nothing of the account.
    /// When the wipe fails the account stays signed in and `error` is `.localData`, so the user can retry.
    public func signOut() async {
        guard await handOver(to: nil) else { return }
        await auth.signOut()
    }

    /// True once the server erased the account; the session is then gone, even when the local sign-out
    /// that follows did not report it (the user no longer exists). On failure `error` is set, the session
    /// stays and the result is false.
    @discardableResult
    public func deleteAccount() async -> Bool {
        do {
            try await auth.deleteAccount()
        } catch {
            self.error = error
            return false
        }
        error = nil
        retryTask?.cancel()
        await handOver(to: nil)
        session = nil
        return true
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
