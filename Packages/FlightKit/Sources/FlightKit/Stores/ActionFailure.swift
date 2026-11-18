import Foundation

/// A failed user action (unfollow, follow from Search, accept a friend, a switch), kept apart from the
/// store's load error so the screen's Retry runs the action again instead of reloading the list (E6).
/// `retry` re-runs exactly what failed; the screen clears the failure with the store's `clearActionError()`.
public struct ActionFailure: Identifiable {
    /// What the action was, for the screen's wording and for tests.
    public enum Kind: String, Sendable, Hashable {
        case unfollow, follow, respond, cancelRequest, removeFriend, updateFriend, pauseSharing, saveProfile,
             invite, resetCode, notify
    }

    public let id = UUID()
    public let kind: Kind
    public let error: APIError
    /// Runs the failed action again with the same arguments.
    public let retry: @MainActor () async -> Void

    public init(_ kind: Kind, _ error: APIError, retry: @escaping @MainActor () async -> Void) {
        self.kind = kind; self.error = error; self.retry = retry
    }

    /// The session ended: the screen offers Sign In instead of Retry (E3).
    public var needsSignIn: Bool { error.needsSignIn }
}

public extension APIError {
    /// The session is gone or refused: Retry cannot help, signing in again can (E3).
    var needsSignIn: Bool { self == .unauthorized }
}
