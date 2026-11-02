import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A fresh Sign in with Apple before an Apple account is deleted: its authorization code lets the
/// server revoke the account's Apple tokens, as App Review requires. The code is valid for five
/// minutes and is used once.
@MainActor
final class AppleReauthorization: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    enum Outcome: Equatable { case code(String), cancelled, failed }

    private var continuation: CheckedContinuation<Outcome, Never>?
    /// Holds the request alive until Apple answers (the controller keeps only a weak delegate).
    private static var running: AppleReauthorization?

    /// Shows Apple's sheet and returns its authorization code; cancelling is not a failure.
    static func request() async -> Outcome {
        let helper = AppleReauthorization()
        running = helper
        defer { running = nil }
        return await withCheckedContinuation { continuation in
            helper.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = helper
            controller.presentationContextProvider = helper
            controller.performRequests()
        }
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated { finish(code.map(Outcome.code) ?? .failed) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: any Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated { finish(cancelled ? .cancelled : .failed) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}
