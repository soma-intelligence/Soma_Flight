import Foundation
import Testing
@testable import FlightKit

/// Task 12: the per-flight notify switch, the clock shared with the Live Activity, the named cache
/// store and the account deletion outcomes Settings relies on.
@MainActor @Suite struct SettingsReadinessTests {
    let now = PreviewData.now

    private func followedStore() async throws -> (FlightDetailStore, FakeFlightService, Flight.ID) {
        let flights = FakeFlightService(now: now)
        let id = try #require(try await flights.followed().first?.id)
        let store = FlightDetailStore(id: id, flights: flights, airports: FakeAirportService(now: now))
        await store.load()
        return (store, flights, id)
    }

    @Test func followedFlightShowsItsNotifySwitch() async throws {
        let (store, _, _) = try await followedStore()
        #expect(store.notify == true)
    }

    @Test func flightNotFollowedHasNoSwitch() async throws {
        let flights = FakeFlightService(now: now)
        let followed = Set(try await flights.followed().map(\.id))
        let other = try #require(try await flights.lookup(.airport("KAUS")).first { !followed.contains($0.id) })
        let store = FlightDetailStore(id: other.id, flights: flights, airports: FakeAirportService(now: now))
        await store.load()
        #expect(store.flight != nil)
        #expect(store.notify == nil)
    }

    @Test func turningNotifyOffCallsFollowWithFalse() async throws {
        let (store, flights, id) = try await followedStore()
        await store.setNotify(false)
        #expect(store.notify == false)
        #expect(try await flights.notifies(id) == false)
        // Still followed: the switch never unfollows.
        #expect(try await flights.followed().contains { $0.id == id })
        await store.setNotify(true)
        #expect(try await flights.notifies(id) == true)
    }

    @Test func refusedNotifyChangeSwitchesBack() async throws {
        let (store, flights, id) = try await followedStore()
        await flights.setNextError(.providerUnavailable)
        await store.setNotify(false)
        #expect(store.notify == true)
        #expect(store.error == .providerUnavailable)
        #expect(!store.isSavingNotify)
        #expect(try await flights.notifies(id) == true)
    }

    @Test func clockSettingReadsFromSharedDefaults() throws {
        let suite = "SettingsReadinessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!SharedSettings.twelveHour(in: defaults))
        defaults.set(false, forKey: SharedSettings.clock24Key)
        #expect(SharedSettings.twelveHour(in: defaults))
        defaults.set(true, forKey: SharedSettings.clock24Key)
        #expect(!SharedSettings.twelveHour(in: defaults))
        #expect(SharedSettings.appGroup == "group.me.somalabs.flight")
    }

    @Test func liveActivityTimesFollowTheClock() {
        var utc = TimeZone.gmt
        utc = TimeZone(identifier: "UTC") ?? utc
        let evening = Date(timeIntervalSince1970: 18 * 3600 + 25 * 60)
        #expect(FlightActivityDisplay.clock(evening, utc) == "18:25")
        #expect(FlightActivityDisplay.clock(evening, utc, twelveHour: true) == "6:25 PM")
        #expect(FlightActivityDisplay.clock(Date(timeIntervalSince1970: 5 * 60), utc, twelveHour: true) == "12:05 AM")
        #expect(Format.clock(evening, utc, .h12) == "6:25 PM")
    }

    @Test func cacheLivesInANamedStore() async throws {
        #expect(CacheStore.defaultURL.path().hasSuffix("/SomaFlight/cache.store"))
        let dir = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "SomaFlight/cache.store")
        let cache = try CacheStore.onDisk(url: url)
        await cache.save(flights: [PreviewData.enRoute])
        #expect(FileManager.default.fileExists(atPath: url.path()))
        let reopened = try CacheStore.onDisk(url: url)
        #expect(await reopened.flights().map(\.id) == [PreviewData.enRoute.id])
    }

    @Test func deletingTheAccountSignsOut() async throws {
        let auth = FakeAuthService()
        let session = SessionStore(auth: auth)
        session.start()
        try await auth.signInWithApple(idToken: "t", nonce: "n")
        await eventually { session.session != nil }
        await session.deleteAccount()
        await eventually { session.session == nil }
        #expect(session.session == nil)
        #expect(session.error == nil)
    }

    @Test func failedDeletionKeepsTheAccount() async throws {
        let auth = FakeAuthService()
        let session = SessionStore(auth: auth)
        session.start()
        try await auth.signInWithApple(idToken: "t", nonce: "n")
        await eventually { session.session != nil }
        await auth.setNextError(.providerUnavailable)
        await session.deleteAccount()
        #expect(session.session != nil)
        #expect(session.error == .providerUnavailable)
    }

    @Test func deletionCopyIsTheBriefs() {
        #expect(SettingsView.deleteTitle + " " + SettingsView.deleteMessage
            == "Delete your account? Your followed flights and flight history will be removed. This can't be undone.")
    }

    @Test func oldDefaultStoreIsDeletedAndCacheSkipsBackups() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = ["default.store", "default.store-wal", "default.store-shm"]
        for n in names { try Data("old".utf8).write(to: root.appending(path: n)) }
        let unrelated = root.appending(path: "other.store")
        try Data("keep".utf8).write(to: unrelated)
        let url = root.appending(path: "SomaFlight/cache.store")
        _ = try CacheStore.onDisk(url: url, legacyDirectory: root)
        for n in names { #expect(!FileManager.default.fileExists(atPath: root.appending(path: n).path())) }
        #expect(FileManager.default.fileExists(atPath: unrelated.path()))
        let folder = url.deletingLastPathComponent()
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Nothing to delete the second time.
        _ = try CacheStore.onDisk(url: url, legacyDirectory: root)
    }

    @Test func deletionClearsASessionTheAuthStreamKept() async throws {
        let auth = SilentDeleteAuth()
        let session = SessionStore(auth: auth)
        session.start()
        await eventually { session.session != nil }
        #expect(await session.deleteAccount())
        #expect(session.session == nil)
        #expect(session.error == nil)
    }

    @Test func failedDeletionReportsFalse() async throws {
        let auth = FakeAuthService()
        let session = SessionStore(auth: auth)
        session.start()
        try await auth.signInWithApple(idToken: "t", nonce: "n")
        await eventually { session.session != nil }
        await auth.setNextError(.offline)
        #expect(await session.deleteAccount() == false)
        #expect(session.session != nil)
    }

    @Test func endedFlightsShowNoAlertSwitch() {
        #expect(!DetailFacts.takesAlerts(PreviewData.canceled))
        #expect(DetailFacts.takesAlerts(PreviewData.enRoute))
        #expect(DetailFacts.takesAlerts(PreviewData.diverted))
    }

    private func eventually(_ cond: () -> Bool) async {
        for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Signed in from the start; deleting succeeds on the server but the local sign-out reports nothing (the
/// `try? signOut(scope: .local)` failure case).
private final class SilentDeleteAuth: AuthService {
    let session: AsyncStream<UserSession?>
    init() {
        let (stream, cont) = AsyncStream<UserSession?>.makeStream()
        cont.yield(UserSession(userId: UUID(), email: "a@b.c", plan: .free))
        session = stream
        // The continuation is dropped on purpose: no further event ever arrives.
    }
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async throws(APIError) {}
    func signInWithEmail(_ email: String) async throws(APIError) {}
    func signOut() async {}
    func deleteAccount() async throws(APIError) {}
}
