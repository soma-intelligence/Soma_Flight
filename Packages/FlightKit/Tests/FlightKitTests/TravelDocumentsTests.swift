import Foundation
import Security
import Testing
@testable import FlightKit

/// The travel documents vault: validation, masking, the flight sheet's loyalty match and passport rule,
/// the store's Face ID gate and two Keychain items, and the Keychain queries themselves.
@Suite @MainActor struct TravelDocumentsTests {
    static let ual = Airline(id: "UAL", iata: "UA", name: "United", alliance: .starAlliance, colorPrimary: "#000000")
    static let deu = Airline(id: "DLH", iata: "LH", name: "Lufthansa", alliance: .starAlliance, colorPrimary: "#000000")
    static let afr = Airline(id: "AFR", iata: "AF", name: "Air France", alliance: .skyteam, colorPrimary: "#000000")
    static let swa = Airline(id: "SWA", iata: "WN", name: "Southwest", colorPrimary: "#000000")
    static let lookup: (String) -> Airline? = { code in [ual, deu, afr, swa].first { $0.id == code } }

    static func store(check: FakeDeviceOwnerCheck = FakeDeviceOwnerCheck(),
                      secrets: MemorySecretStore = MemorySecretStore(),
                      defaults: UserDefaults? = nil) -> TravelDocumentsStore {
        TravelDocumentsStore(secrets: secrets, check: check, defaults: defaults)
    }

    // MARK: Rules

    @Test func numbersNormaliseAndValidatePerKind() {
        #expect(TravelDocumentRules.validated("ab 123-456", as: .loyalty) == "AB123456")
        #expect(TravelDocumentRules.validated("123", as: .loyalty) == nil)
        #expect(TravelDocumentRules.validated("12345678901234567890X", as: .loyalty) == nil)
        #expect(TravelDocumentRules.validated("12#45", as: .loyalty) == nil)
        #expect(TravelDocumentRules.validated("19ab12345", as: .passport) == "19AB12345")
        #expect(TravelDocumentRules.validated("1234", as: .passport) == nil)
        #expect(TravelDocumentRules.validated("TT1234567", as: .knownTraveler) == "TT1234567")
        #expect(TravelDocumentRules.validated("1234567", as: .knownTraveler) == nil)
        #expect(TravelDocumentRules.validated("1234567", as: .redress) == "1234567")
        #expect(TravelDocumentRules.validated("12345A7", as: .redress) == nil)
        #expect(TravelDocumentRules.validated("é1234567", as: .passport) == nil)
    }

    @Test func hiddenNumbersShowTheirLastFour() {
        #expect(TravelDocumentRules.masked("19AB12345") == "•••• 2345")
        #expect(TravelDocumentRules.masked("12345") == "••••••")
        #expect(!TravelDocumentKind.loyalty.isSensitive)
        #expect(TravelDocumentKind.passport.isSensitive && TravelDocumentKind.knownTraveler.isSensitive
                && TravelDocumentKind.redress.isSensitive)
    }

    @Test func theAirlinesOwnNumberComesFirstThenItsAlliance() {
        let united = LoyaltyNumber(airline: "UAL", number: "AB123456")
        let miles = LoyaltyNumber(airline: "DLH", number: "992000111")
        let blue = LoyaltyNumber(airline: "AFR", number: "1234567890")
        let all = [blue, miles, united]
        let onUnited = TravelDocumentRules.loyalty(for: Self.ual, in: all, lookup: Self.lookup)
        #expect(onUnited.own == united && onUnited.partners == [miles])
        let onAF = TravelDocumentRules.loyalty(for: Self.afr, in: all, lookup: Self.lookup)
        #expect(onAF.own == blue && onAF.partners.isEmpty)
        // No alliance: the airline's own number only.
        let onSW = TravelDocumentRules.loyalty(for: Self.swa, in: all, lookup: Self.lookup)
        #expect(onSW.own == nil && onSW.partners.isEmpty)
        #expect(TravelDocumentRules.loyalty(for: nil, in: all, lookup: Self.lookup).own == nil)
    }

    @Test func thePassportRuleSpeaksOnlyBeforeInternationalFlights() throws {
        let departure = try #require(TravelDocumentRules.day("2026-11-03"))
        func notice(_ expires: String?, international: Bool = true) -> TravelDocumentRules.PassportNotice? {
            TravelDocumentRules.passportNotice(expires: expires, departure: departure, international: international)
        }
        #expect(notice("2027-05-02") == .expiresSoon(try #require(TravelDocumentRules.day("2027-05-02"))))
        #expect(notice("2027-05-03") == nil)
        #expect(notice("2026-11-02") == .expired(try #require(TravelDocumentRules.day("2026-11-02"))))
        #expect(notice("2026-11-03") == .expiresSoon(departure))
        #expect(notice("2027-01-01", international: false) == nil)
        #expect(notice(nil) == nil)
        #expect(TravelDocumentRules.passportNotice(expires: "2027-01-01", departure: nil, international: true) == nil)
    }

    @Test func thePassportWordsNameTheDay() throws {
        let d = try #require(TravelDocumentRules.day("2027-03-12"))
        let soon = TravelDocumentRules.passportText(.expiresSoon(d))
        #expect(soon.title == "Passport expires soon")
        #expect(soon.text.hasPrefix("Your passport expires on 12 Mar 2027, within six months of this flight."))
        #expect(TravelDocumentRules.passportText(.expired(d)).title == "Passport expired")
        #expect(TravelDocumentRules.dayString(d) == "2027-03-12")
    }

    @Test func theCardAndSettingsWordsNameTheProgramme() {
        let n = LoyaltyNumber(airline: "AFR", number: "1234567890", programme: "Flying Blue")
        #expect(TravelDocumentsCardFacts.ownTitle(n, airline: Self.afr) == "Your Flying Blue number")
        let bare = LoyaltyNumber(airline: "DLH", number: "992000111")
        #expect(TravelDocumentsCardFacts.ownTitle(bare, airline: Self.deu) == "Your Lufthansa number")
        #expect(TravelDocumentsCardFacts.partnerTitle(bare, airline: Self.deu) == "Lufthansa, Star Alliance partner")
        #expect(TravelDocumentsCopy.loyaltyTitle(n, airline: Self.afr) == "Air France · Flying Blue")
        #expect(TravelDocumentsCopy.loyaltyTitle(bare, airline: nil) == "DLH")
        let p = TravelProfile(passportCountry: "FR", passportExpires: "2027-03-12")
        #expect(TravelDocumentsCopy.passportSubtitle(p, country: nil) == "FR · expires 12 Mar 2027")
        #expect(TravelDocumentsCopy.passportSubtitle(TravelProfile(), country: nil) == nil)
    }

    // MARK: Store

    @Test func loyaltyNumbersSaveEditAndDeleteWithoutFaceID() {
        let check = FakeDeviceOwnerCheck()
        let s = Self.store(check: check)
        #expect(s.saveLoyalty(airline: "ual", number: "ab 123 456", programme: "  "))
        let n = s.profile.loyalty[0]
        #expect(n.airline == "UAL" && n.number == "AB123456" && n.programme == nil)
        #expect(s.display(.loyalty, loyalty: n) == "AB123456")
        #expect(!s.saveLoyalty(airline: "UAL", number: "12", programme: nil))
        #expect(s.saveLoyalty(id: n.id, airline: "UAL", number: "AB999999", programme: "MP"))
        #expect(s.profile.loyalty.count == 1 && s.profile.loyalty[0].number == "AB999999")
        s.deleteLoyalty(n.id)
        #expect(s.profile.loyalty.isEmpty)
        #expect(check.asked == 0)
    }

    @Test func hiddenNumbersShowOnlyAfterTheCheck() async {
        let check = FakeDeviceOwnerCheck()
        let secrets = MemorySecretStore()
        let s = Self.store(check: check, secrets: secrets)
        #expect(await s.saveHidden(.knownTraveler, "tt1234567"))
        #expect(await s.saveHidden(.redress, "1234567"))
        // A relaunch: the kinds are known, the numbers are not read.
        let again = Self.store(check: check, secrets: secrets)
        #expect(again.identityKinds == [.knownTraveler, .redress])
        #expect(!again.isRevealed)
        #expect(again.display(.knownTraveler) == "••••••")
        #expect(again.display(.passport) == nil)
        check.answer(false)
        #expect(await again.reveal() == false)
        #expect(await again.copyValue(.redress) == nil)
        check.answer(true)
        #expect(await again.copyValue(.redress) == "1234567")
        #expect(again.display(.knownTraveler) == "TT1234567")
        again.hide()
        #expect(again.display(.knownTraveler) == "••••••")
    }

    @Test func savingOneHiddenNumberKeepsTheOthers() async {
        let check = FakeDeviceOwnerCheck()
        let secrets = MemorySecretStore()
        #expect(await Self.store(check: check, secrets: secrets).saveHidden(.knownTraveler, "TT1234567"))
        let s = Self.store(check: check, secrets: secrets)
        let expires = TravelDocumentRules.day("2027-03-12")
        #expect(await s.savePassport(number: "19AB12345", country: "fr", expires: expires))
        #expect(s.profile.passportCountry == "FR" && s.profile.passportExpires == "2027-03-12")
        #expect(s.identity == TravelIdentity(passportNumber: "19AB12345", knownTraveler: "TT1234567"))
        // An empty number removes only that one.
        #expect(await s.saveHidden(.knownTraveler, ""))
        #expect(s.identityKinds == [.passport])
        #expect(!(await s.saveHidden(.redress, "ABC")))
    }

    @Test func theProfileNeverHoldsAHiddenNumber() async throws {
        let secrets = MemorySecretStore()
        let s = Self.store(secrets: secrets)
        #expect(await s.savePassport(number: "19AB12345", country: "FR", expires: nil))
        let profile = try #require(try secrets.read(TravelDocumentsStore.profileAccount))
        #expect(!String(decoding: profile, as: UTF8.self).contains("19AB12345"))
        let identity = try #require(try secrets.read(TravelDocumentsStore.identityAccount))
        #expect(String(decoding: identity, as: UTF8.self).contains("19AB12345"))
    }

    @Test func iCloudSyncIsOffByDefaultAndRewritesBothItems() async throws {
        let defaults = try #require(UserDefaults(suiteName: "travel-docs-\(UUID().uuidString)"))
        let secrets = MemorySecretStore()
        let s = Self.store(secrets: secrets, defaults: defaults)
        #expect(!s.syncsWithICloud)
        _ = s.saveLoyalty(airline: "UAL", number: "AB123456", programme: nil)
        #expect(await s.saveHidden(.redress, "1234567"))
        #expect(secrets.isSynchronizable(TravelDocumentsStore.profileAccount) == false)
        #expect(secrets.isSynchronizable(TravelDocumentsStore.identityAccount) == false)
        await s.setSync(true)
        #expect(s.syncsWithICloud && defaults.bool(forKey: TravelDocumentsStore.syncKey))
        #expect(secrets.isSynchronizable(TravelDocumentsStore.profileAccount) == true)
        #expect(secrets.isSynchronizable(TravelDocumentsStore.identityAccount) == true)
        await s.setSync(false)
        #expect(secrets.isSynchronizable(TravelDocumentsStore.identityAccount) == false)
    }

    @Test func turningSyncOnNeedsTheCheckWhenHiddenNumbersExist() async {
        let check = FakeDeviceOwnerCheck()
        let secrets = MemorySecretStore()
        #expect(await Self.store(check: check, secrets: secrets).saveHidden(.redress, "1234567"))
        let s = Self.store(check: check, secrets: secrets)
        check.answer(false)
        await s.setSync(true)
        #expect(!s.syncsWithICloud)
        #expect(secrets.isSynchronizable(TravelDocumentsStore.identityAccount) == false)
    }

    @Test func deleteAllRemovesBothItems() async {
        let secrets = MemorySecretStore()
        let s = Self.store(secrets: secrets)
        _ = s.saveLoyalty(airline: "UAL", number: "AB123456", programme: nil)
        #expect(await s.saveHidden(.redress, "1234567"))
        s.deleteAll()
        #expect(secrets.accounts.isEmpty)
        #expect(s.profile.isEmpty && s.identityKinds.isEmpty && !s.isRevealed)
    }

    @Test func aLockedKeychainSaysSoAndChangesNothing() {
        let secrets = MemorySecretStore()
        let s = Self.store(secrets: secrets)
        secrets.fail(true)
        #expect(!s.saveLoyalty(airline: "UAL", number: "AB123456", programme: nil))
        #expect(s.profile.loyalty.isEmpty)
        #expect(s.failure == TravelDocumentsStore.failureText)
    }

    @Test func theFlightSheetSeesLoyaltyAndThePassportRule() async throws {
        let s = TravelDocumentsStore.preview()
        let reference = ReferenceData(airlines: [Self.ual, Self.deu, Self.afr], types: [], countries: [])
        let m = s.loyalty(for: Self.afr, reference: reference)
        #expect(m.own?.number == "1234567890")
        let departure = try #require(TravelDocumentRules.day("2026-11-03"))
        #expect(s.passportNotice(departure: departure, international: true)?.title == "Passport expires soon")
        #expect(s.passportNotice(departure: departure, international: false) == nil)
        #expect(!s.isRevealed)
    }

    // MARK: Keychain queries

    @Test func keychainItemsStayOnTheDeviceUnlessSyncIsOn() {
        let k = KeychainSecretStore(service: "test")
        let local = k.addQuery(Data([1]), account: "a", synchronizable: false)
        #expect(local[kSecAttrSynchronizable as String] as? Bool == false)
        #expect((local[kSecAttrAccessible as String] as! CFString) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(local[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let synced = k.addQuery(Data([1]), account: "a", synchronizable: true)
        #expect(synced[kSecAttrSynchronizable as String] as? Bool == true)
        #expect((synced[kSecAttrAccessible as String] as! CFString) == kSecAttrAccessibleWhenUnlocked)
        // Reads and deletes find the item either way.
        let find = k.findQuery("a")
        #expect((find[kSecAttrSynchronizable as String] as! CFString) == kSecAttrSynchronizableAny)
        #expect(find[kSecAttrService as String] as? String == "test")
        #expect(KeychainSecretStore.defaultService == "me.soma.flight.travel-documents")
    }
}
