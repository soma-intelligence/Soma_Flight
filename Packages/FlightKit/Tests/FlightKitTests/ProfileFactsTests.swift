import Foundation
import Testing
@testable import FlightKit

/// The texts the Profil computes (Settings > account row): the short account ID, the sync line of the
/// followed flights, the sign-in method and the Travel Documents lock. Pure: the clock and the locale
/// are pinned, the labels are the catalog's English keys (the test bundle has no French table).
@Suite struct ProfileFactsTests {
    private let en = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Account ID

    @Test func shortIDKeepsFourAndFourOfTheLowercasedUUID() {
        let id = UUID(uuidString: "5A1E0000-0000-4000-8000-0000000000C1")!
        #expect(ProfileFacts.shortID(id) == "5a1e\u{2026}00c1")
    }

    @Test func shortIDOfAShortStringIsUnchanged() {
        #expect(ProfileFacts.shortID("abc123") == "abc123")
        #expect(ProfileFacts.shortID("abcdef123456") == "abcdef123456")
    }

    @Test func shortIDOfNothingIsNil() {
        #expect(ProfileFacts.shortID(nil as UUID?) == nil)
        #expect(ProfileFacts.shortID(nil as String?) == nil)
        #expect(ProfileFacts.shortID("") == nil)
    }

    @Test func fullIDIsTheLowercasedUUID() {
        let id = UUID(uuidString: "5A1E0000-0000-4000-8000-0000000000C1")!
        #expect(ProfileFacts.fullID(id) == "5a1e0000-0000-4000-8000-0000000000c1")
    }

    // MARK: Sync line

    @Test func liveListSaysLive() {
        let state = ProfileFacts.SyncState(live: true, offline: false, loaded: true, failed: false,
                                           confirmedAt: now.addingTimeInterval(-600))
        #expect(ProfileFacts.syncLine(state, now: now, locale: en) == "Live")
    }

    @Test func confirmedListSaysUpToDateWithTheRelativeTime() {
        let state = ProfileFacts.SyncState(live: false, offline: false, loaded: true, failed: false,
                                           confirmedAt: now.addingTimeInterval(-180))
        let line = ProfileFacts.syncLine(state, now: now, locale: en)
        #expect(line.hasPrefix("Up to date \u{00B7} "))
        #expect(line.contains("3 min"))
    }

    @Test func offlineKeepsTheTimeOfTheSavedCopy() {
        let state = ProfileFacts.SyncState(live: false, offline: true, loaded: true, failed: true,
                                           confirmedAt: now.addingTimeInterval(-7_200))
        let line = ProfileFacts.syncLine(state, now: now, locale: en)
        #expect(line.hasPrefix("Offline \u{00B7} "))
        #expect(line.contains("2 hr"))
    }

    @Test func offlineWithoutACopyIsTheLabelOnly() {
        let state = ProfileFacts.SyncState(live: false, offline: true, loaded: true, failed: true, confirmedAt: nil)
        #expect(ProfileFacts.syncLine(state, now: now, locale: en) == "Offline")
    }

    @Test func aFailedLoadSaysSo() {
        let state = ProfileFacts.SyncState(live: false, offline: false, loaded: true, failed: true, confirmedAt: nil)
        #expect(ProfileFacts.syncLine(state, now: now, locale: en) == "Couldn't sync")
    }

    @Test func beforeTheFirstLoadItSyncs() {
        let state = ProfileFacts.SyncState(live: false, offline: false, loaded: false, failed: false, confirmedAt: nil)
        #expect(ProfileFacts.syncLine(state, now: now, locale: en) == "Syncing\u{2026}")
    }

    /// A clock a little behind the server never says "in 5 sec".
    @Test func aConfirmationInTheFutureReadsAsNow() {
        let state = ProfileFacts.SyncState(live: false, offline: false, loaded: true, failed: false,
                                           confirmedAt: now.addingTimeInterval(5))
        let line = ProfileFacts.syncLine(state, now: now, locale: en)
        #expect(!line.contains("in "))
        #expect(line.hasPrefix("Up to date \u{00B7} "))
    }

    // MARK: Sign-in method

    @Test func signInMethodFollowsTheProvider() {
        #expect(ProfileFacts.signInMethod(provider: .apple, usesApple: true) == "Sign in with Apple")
        #expect(ProfileFacts.signInMethod(provider: .google, usesApple: false) == "Google")
        #expect(ProfileFacts.signInMethod(provider: .email, usesApple: false) == "Email sign-in link")
    }

    /// Without the provider's word, Apple is still known from the session; anything else is left out.
    @Test func signInMethodWithoutAProvider() {
        #expect(ProfileFacts.signInMethod(provider: nil, usesApple: true) == "Sign in with Apple")
        #expect(ProfileFacts.signInMethod(provider: .other, usesApple: true) == "Sign in with Apple")
        #expect(ProfileFacts.signInMethod(provider: nil, usesApple: false) == nil)
        #expect(ProfileFacts.signInMethod(provider: .other, usesApple: false) == nil)
    }

    // MARK: Travel Documents

    @Test func documentsLockNamesTheBiometry() {
        #expect(ProfileFacts.documentsLock(biometry: "Face ID") == "Shown after Face ID")
    }

    @Test func documentsLockWithoutBiometryNamesThePasscode() {
        #expect(ProfileFacts.documentsLock(biometry: nil) == "Shown after your passcode")
    }

    /// The Mac asks for the account password, not a passcode.
    @Test func documentsLockOnTheMacNamesThePassword() {
        #expect(ProfileFacts.documentsLock(biometry: nil, onMac: true) == "Shown after your password")
        #expect(ProfileFacts.documentsLock(biometry: "Touch ID", onMac: true) == "Shown after Touch ID")
    }

    @Test func documentsSyncUsesTheTravelDocumentsWords() {
        #expect(ProfileFacts.documentsSync(true) == TravelDocumentsCopy.syncOn)
        #expect(ProfileFacts.documentsSync(false) == TravelDocumentsCopy.syncOff)
    }

    // MARK: Catalog

    /// Every Profil string has its French line in the app's catalog.
    @Test func theCatalogHasTheFrenchLines() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Shared/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = json["strings"] as! [String: Any]
        for key in ProfileFacts.catalogKeys {
            let entry = strings[key] as? [String: Any]
            let fr = ((entry?["localizations"] as? [String: Any])?["fr"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect((fr?["value"] as? String)?.isEmpty == false, "no French line for \(key)")
        }
    }
}
