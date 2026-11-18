import Foundation
import SwiftUI
import Testing
@testable import FlightKit

/// E3: when the backend ends the session on its own, the open cards and the stores behind their editors
/// stay, and sign-in shows over them. Only another account, an explicit sign-out or giving up on the
/// sign-in sheet rebuilds the home.
@MainActor @Suite(.serialized) struct SessionExpiryTests {
    /// A home on the fakes that needs an account, signed in by email and started, with an airport card open.
    private func signedInHome() async throws -> (HomeModel, AppEnvironment, UUID) {
        var env = try await AppEnvironment.fake()
        env.requiresSignIn = true
        let home = HomeModel(env: env)
        home.session.startIfNeeded()
        try await waitUntil { home.session.isResolved }
        try await env.auth.signInWithEmail("traveller@example.com")
        try await waitUntil { home.owner != nil }
        await home.start()
        home.shell.open(airport: "KSFO")
        let owner = try #require(home.owner)
        return (home, env, owner)
    }

    @Test func expiryKeepsTheShellAndTheStores() async throws {
        let (home, env, owner) = try await signedInHome()
        let flights = home.myFlights, passport = home.passport
        let path = home.shell.path
        #expect(!path.isEmpty)

        // The server ends the session: the auth stream reports nobody, without a sign-out here.
        await env.auth.signOut()
        try await waitUntil { home.isSessionExpired }
        #expect(home.owner == nil)
        #expect(home.session.expiredUserId == owner)
        #expect(home.shellOwner == owner)
        #expect(home.needsSignIn, "the gate shows sign-in, as a sheet over the home it already showed")
        #expect(SignInGate<EmptyView>.screen(needsSignIn: home.needsSignIn, sessionExpired: home.isSessionExpired,
                                             homeShown: true, awaitingSession: home.awaitingSession,
                                             gate: .hidden, profileWaitOver: false) == .home)
        try await Task.sleep(for: .milliseconds(50))
        #expect(home.myFlights === flights)
        #expect(home.passport === passport)
        #expect(home.shell.path == path, "the open card and its editor stay")
        #expect(home.profileOwner == owner)

        // The same account signs in again: nothing is rebuilt, the expiry clears.
        try await env.auth.signInWithEmail("traveller@example.com")
        try await waitUntil { home.owner == owner }
        #expect(!home.isSessionExpired)
        #expect(home.session.expiredUserId == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(home.myFlights === flights)
        #expect(home.shell.path == path)
    }

    @Test func anotherAccountAfterExpiryRebuilds() async throws {
        let (home, env, owner) = try await signedInHome()
        let flights = home.myFlights
        await env.auth.signOut()
        try await waitUntil { home.isSessionExpired }
        try await env.auth.signInWithApple(idToken: "t", nonce: "n")
        try await waitUntil { home.owner != nil && home.owner != owner }
        try await waitUntil { home.myFlights !== flights }
        #expect(home.shell.path.isEmpty)
        #expect(!home.isSessionExpired)
    }

    @Test func givingUpOnTheSheetRebuildsForNobody() async throws {
        let (home, env, _) = try await signedInHome()
        let flights = home.myFlights
        await env.auth.signOut()
        try await waitUntil { home.isSessionExpired }
        // The sign-in sheet closed without signing in.
        home.session.clearSessionExpired()
        try await waitUntil { home.session.expiredUserId == nil }
        try await waitUntil { home.myFlights !== flights }
        #expect(home.shellOwner == nil)
        #expect(home.shell.path.isEmpty)
        #expect(home.needsSignIn)
        #expect(!home.isSessionExpired)
    }

    @Test func explicitSignOutRebuildsAtOnce() async throws {
        let (home, _, _) = try await signedInHome()
        let flights = home.myFlights
        await home.session.signOut()
        try await waitUntil { home.myFlights !== flights }
        #expect(!home.isSessionExpired, "asked for: no sign-in sheet over the home")
        #expect(home.session.expiredUserId == nil)
        #expect(home.shell.path.isEmpty)
    }

    @Test func expiryKeepsTheCacheUntilGivenUp() async throws {
        let auth = FakeAuthService()
        let cache = try CacheStore.inMemory()
        let session = SessionStore(auth: auth, onUserChange: { try await cache.claim(for: $0) })
        session.start()
        try await auth.signInWithEmail("a@example.com")
        try await waitUntil { session.session != nil }
        await cache.save(flights: try await FakeFlightService().followed())
        await auth.signOut()
        try await waitUntil { session.isSessionExpired }
        #expect(!(await cache.flights()).isEmpty, "the expired account's flights stay while sign-in shows")
        await session.abandonExpiredSession()
        #expect(await cache.flights().isEmpty)
        #expect(session.expiredUserId == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met in 3 s")
    }
}
