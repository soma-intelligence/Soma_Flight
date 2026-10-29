import Foundation
import Testing
@testable import FlightKit

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Task 9: the shells show Sign In while the backend needs an account, and the sign-in calls the
/// session store makes.
@Suite @MainActor struct SignInGateTests {
    private func home(requiresSignIn: Bool) async throws -> HomeModel {
        var env = try await AppEnvironment.fake()
        env.requiresSignIn = requiresSignIn
        return HomeModel(env: env)
    }

    @Test func fakesNeverAskToSignIn() async throws {
        let home = try await home(requiresSignIn: false)
        #expect(!home.awaitingSession)
        await home.start()
        await eventually { home.session.isResolved }
        #expect(home.session.session == nil)
        #expect(!home.needsSignIn)
    }

    @Test func theBackendAsksToSignInOnceTheSessionIsKnown() async throws {
        let home = try await home(requiresSignIn: true)
        #expect(home.awaitingSession)
        #expect(!home.needsSignIn)
        home.session.startIfNeeded()
        await eventually { home.session.isResolved }
        #expect(home.needsSignIn)
        #expect(await home.session.signInWithEmail("a@example.com"))
        await eventually { home.session.session != nil }
        #expect(!home.needsSignIn)
    }

    /// The home first appears after a sign-in it did not see: `start()` builds the stores for that account.
    @Test func startRebuildsStoresForTheAccountSignedInBehindSignIn() async throws {
        let home = try await home(requiresSignIn: true)
        let before = home.myFlights
        home.session.startIfNeeded()
        await eventually { home.session.isResolved }
        try await home.env.auth.signInWithApple(idToken: "t", nonce: "n")
        await eventually { home.owner != nil }
        await home.start()
        #expect(home.myFlights !== before)
        let rebuilt = home.myFlights
        await home.start()
        #expect(home.myFlights === rebuilt)
    }

    @Test func signInFailuresLandOnTheSession() async throws {
        let auth = FakeAuthService()
        let store = SessionStore(auth: auth)
        await auth.setNextError(.rateLimited)
        #expect(await store.signInWithEmail("a@example.com") == false)
        #expect(store.error == .rateLimited)
        await auth.setNextError(.unauthorized)
        await store.signInWithApple(idToken: "t", nonce: "n")
        #expect(store.error == .unauthorized)
        await store.handle(url: URL(string: "somaflight://auth-callback?code=x")!)
        #expect(store.error == .unauthorized)
    }

    @Test func fakesLaunchWithoutABackend() async throws {
        let env = try await AppEnvironment.forLaunch(arguments: ["app", "-useFakes"])
        #expect(!env.requiresSignIn)
        #expect(env.flights is FakeFlightService)
    }
}
