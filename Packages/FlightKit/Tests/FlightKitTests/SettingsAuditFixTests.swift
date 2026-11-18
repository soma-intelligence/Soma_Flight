import Foundation
import Testing
@testable import FlightKit

// The settings, profile and travel documents side of the 2026-11-18 premium checklist audit
// (docs/audits/2026-11-18-premium-checklist-audit.md): E.164 numbers for Text Me Too (I12) and the travel
// documents editor's invalid versus failed saves (I3), sync line (E13) and change tracking (I2).

// MARK: - E.164 (I12)

@Suite("Phone numbers in E.164")
struct PhoneNumberTests {
    @Test("A number with its country code keeps it, separators dropped")
    func international() {
        #expect(PhoneNumber.e164("+1 (415) 555-0100", region: "FR") == "+14155550100")
        #expect(PhoneNumber.e164("+33 6 12 34 56 78", region: "US") == "+33612345678")
        #expect(PhoneNumber.e164(" +44 20 7946 0958 ", region: nil) == "+442079460958")
    }

    @Test("An international prefix reads as the plus")
    func internationalPrefix() {
        #expect(PhoneNumber.e164("0033 6 12 34 56 78", region: "FR") == "+33612345678")
        #expect(PhoneNumber.e164("011 33 6 12 34 56 78", region: "US") == "+33612345678")
    }

    @Test("A national number takes the region's code and drops its trunk 0")
    func national() {
        #expect(PhoneNumber.e164("06 12 34 56 78", region: "FR") == "+33612345678")
        #expect(PhoneNumber.e164("07700 900123", region: "GB") == "+447700900123")
        #expect(PhoneNumber.e164("030 1234567", region: "de") == "+49301234567")
    }

    @Test("North America takes ten digits, or eleven with the leading 1")
    func northAmerica() {
        #expect(PhoneNumber.e164("(415) 555-0100", region: "US") == "+14155550100")
        #expect(PhoneNumber.e164("1 415 555 0100", region: "CA") == "+14155550100")
        #expect(PhoneNumber.e164("555 0100", region: "US") == nil)
    }

    @Test("Italy keeps its leading 0 after the country code")
    func italy() {
        #expect(PhoneNumber.e164("06 1234 5678", region: "IT") == "+390612345678")
    }

    @Test("Letters, a stray plus, too few or too many digits and an unknown region do not read")
    func invalid() {
        #expect(PhoneNumber.e164("", region: "US") == nil)
        #expect(PhoneNumber.e164("1-800-FLOWERS", region: "US") == nil)
        #expect(PhoneNumber.e164("+1 415 +555 0100", region: "US") == nil)
        #expect(PhoneNumber.e164("+1 234", region: "US") == nil)
        #expect(PhoneNumber.e164("+1234567890123456", region: "US") == nil)
        #expect(PhoneNumber.e164("06 12 34 56 78", region: nil) == nil)
        #expect(PhoneNumber.e164("06 12 34 56 78", region: "ZZ") == nil)
    }

    @Test("The store sends the E.164 form and flags a number that does not read")
    @MainActor func storeSendsE164() async {
        let store = TextAlertsStore(service: FakeTextAlertsService(TextAlertsStatus(available: true)), region: "FR")
        store.phoneDraft = "06 12 34 56 78"
        #expect(store.normalizedPhone == "+33612345678")
        store.phoneDraft = "12"
        await store.sendCode()
        #expect(store.phoneInvalid)
        store.phoneEdited()
        #expect(!store.phoneInvalid)
    }
}

// MARK: - Travel documents (I2, I3, E13)

@Suite("Travel documents editor")
@MainActor struct TravelDocumentEditorTests {
    @Test("A number that does not read is invalid and never reaches the store")
    func invalidNumber() async {
        let store = TravelDocumentsStore.preview()
        let model = TravelDocumentEditorModel(subject: .knownTraveler)
        await model.prefill(from: store)
        model.number = "12"
        #expect(await model.save(to: store, airlineID: nil) == .invalid)
        #expect(model.error == .invalid)
    }

    @Test("A valid number the device refuses to write is a failure, not invalid")
    func failedSave() async {
        // Face ID refused: the kept numbers cannot be read, so the write cannot keep them and stops.
        let store = TravelDocumentsStore.preview(check: FakeDeviceOwnerCheck(answer: false))
        let model = TravelDocumentEditorModel(subject: .knownTraveler)
        await model.prefill(from: store)
        model.number = "KT123456"
        #expect(await model.save(to: store, airlineID: nil) == .failed)
        #expect(model.error == .failed)
    }

    @Test("Typing clears the error")
    func typingClearsError() async {
        let store = TravelDocumentsStore.preview()
        let model = TravelDocumentEditorModel(subject: .redress)
        await model.prefill(from: store)
        model.number = "ABC"
        _ = await model.save(to: store, airlineID: nil)
        #expect(model.error == .invalid)
        model.number = "ABC1"
        #expect(model.error == nil)
    }

    @Test("Emptying a kept number asks first, then removes it")
    func removeAsks() async {
        let store = TravelDocumentsStore.preview()
        let model = TravelDocumentEditorModel(subject: .knownTraveler)
        await model.prefill(from: store)
        #expect(model.number == "TT1234567")
        model.number = ""
        #expect(await model.save(to: store, airlineID: nil) == .confirmRemove)
        #expect(store.identityKinds.contains(.knownTraveler))
        #expect(await model.save(to: store, airlineID: nil, confirmedRemove: true) == .saved)
        #expect(!store.identityKinds.contains(.knownTraveler))
    }

    @Test("A loyalty number without a known airline is invalid")
    func loyaltyNeedsAirline() async {
        let store = TravelDocumentsStore.preview()
        let model = TravelDocumentEditorModel(subject: .loyalty(nil))
        await model.prefill(from: store)
        model.number = "12345678"
        #expect(await model.save(to: store, airlineID: nil) == .invalid)
        #expect(await model.save(to: store, airlineID: "BAW") == .saved)
    }

    @Test("The stored form shows before saving, and the editor knows when it changed")
    func previewAndDirty() async {
        let store = TravelDocumentsStore.preview()
        let model = TravelDocumentEditorModel(subject: .loyalty(nil))
        await model.prefill(from: store)
        #expect(!model.isDirty)
        model.number = "ab 123-456"
        #expect(model.normalizedPreview == "AB123456")
        #expect(model.isDirty)
        model.number = "AB123456"
        #expect(model.normalizedPreview == nil)
    }

    @Test("The sync line promises every device only once synced")
    func syncLine() {
        #expect(TravelDocumentsCopy.syncLine(.synced) == TravelDocumentsCopy.syncOn)
        #expect(TravelDocumentsCopy.syncLine(.pending) == "Not synced yet")
        #expect(TravelDocumentsCopy.syncLine(.failed).hasPrefix("Not synced yet"))
        #expect(TravelDocumentsCopy.syncLine(.off) == TravelDocumentsCopy.syncOff)
    }
}
