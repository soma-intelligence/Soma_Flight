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
    /// The account is still signed in on this device, but the server refused its session and a refresh
    /// did not renew it (E3). Screens offer Sign In (as a sheet over what is open) instead of Retry; a new
    /// sign-in or a later successful refresh clears it.
    public private(set) var isSessionExpired = false
    /// The account whose session the server ended on its own (a refresh token refused, a sign-out from
    /// elsewhere) while it was signed in here (E3). `session` is nil, but nothing is handed over yet: the
    /// device keeps the account's data and the shell keeps what is open, with sign-in as a sheet over it.
    /// Signing in again as this account picks up where it was; another account, an explicit `signOut()` or
    /// giving up on the sheet (`clearSessionExpired()`) hands the device over as a sign-out does.
    public private(set) var expiredUserId: UUID?
    /// An account deletion is running: the nil the auth stream may report meanwhile is not an expiry.
    @ObservationIgnored private var deleting = false
    /// The refresh running now, shared by every store that met `.unauthorized` at the same time.
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
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
        // The server ended the session of the account signed in here, and nobody asked for it: keep the
        // account's data and the open screens, and ask for sign-in over them (E3).
        if s == nil, !deleting, let gone = session?.userId ?? expiredUserId {
            expiredUserId = gone
            isSessionExpired = true
            session = nil
            return
        }
        if await handOver(to: s?.userId) {
            // Any session reported again (a sign-in, a refresh) is good until a store meets a refusal.
            if s != nil { isSessionExpired = false }
            expiredUserId = nil
            session = s
            return
        }
        expiredUserId = nil
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

    // MARK: Expired session

    /// A store met `.unauthorized`: tries to renew the session once. True when it was renewed (the store
    /// retries its call); false sets `isSessionExpired` when the server refused the renewal. A failure
    /// that is not a refusal (offline) leaves the flag alone. Calls made while a refresh runs share it.
    @discardableResult
    public func recoverSession() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let auth = auth
        let task = Task { @MainActor [weak self] () -> Bool in
            do throws(APIError) {
                try await auth.refreshSession()
                self?.isSessionExpired = false
                return true
            } catch {
                if error == .unauthorized { self?.isSessionExpired = true }
                return false
            }
        }
        refreshTask = task
        let renewed = await task.value
        refreshTask = nil
        return renewed
    }

    /// The sign-in sheet was dismissed without signing in, or a test resets the state. When the server had
    /// already ended the session (`expiredUserId`), this is the user giving up on it: the device is handed
    /// over as at a sign-out, and the home is rebuilt for nobody.
    public func clearSessionExpired() {
        isSessionExpired = false
        guard expiredUserId != nil, session == nil else { return }
        Task { await abandonExpiredSession() }
    }

    /// Ends an expired account's stay on the device: its data is wiped, then `expiredUserId` goes, which
    /// rebuilds the stores for nobody. When the wipe fails `error` is `.localData` and `expiredUserId` still
    /// goes: the stores rebuilt for nobody read nothing, and the next sign-in hands the device over again.
    public func abandonExpiredSession() async {
        guard expiredUserId != nil, session == nil else { return }
        isSessionExpired = false
        await handOver(to: nil)
        expiredUserId = nil
    }

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
        // Asked for here: the nil the auth stream reports next is a sign-out, not an expiry (E3).
        expiredUserId = nil
        isSessionExpired = false
        session = nil
        await auth.signOut()
    }

    /// True once the server erased the account; the session is then gone, even when the local sign-out
    /// that follows did not report it (the user no longer exists). On failure `error` is set, the session
    /// stays and the result is false. `appleAuthorizationCode` comes from a fresh Apple sign-in when the
    /// account uses Apple (`UserSession.usesApple`): the server revokes the Apple tokens with it.
    @discardableResult
    public func deleteAccount(appleAuthorizationCode: String? = nil) async -> Bool {
        deleting = true
        defer { deleting = false }
        do {
            try await auth.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
        } catch {
            self.error = error
            return false
        }
        error = nil
        retryTask?.cancel()
        await handOver(to: nil)
        expiredUserId = nil
        isSessionExpired = false
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
