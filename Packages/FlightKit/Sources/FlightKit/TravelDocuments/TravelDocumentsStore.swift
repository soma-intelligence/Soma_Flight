import Foundation
import Observation
import SwiftUI

/// Settings > Travel Documents and the flight sheet's loyalty row: the traveller's loyalty numbers,
/// passport, Known Traveler and Redress numbers, kept in two Keychain items on this device and nowhere
/// else (no server, no iCloud unless the traveller turns iCloud Keychain sync on, off by default).
///
/// `profile` (loyalty numbers, the passport's country and expiry) reads freely. `identity` (passport,
/// Known Traveler and Redress numbers) is read into memory only by `reveal()`, after Face ID or the
/// passcode, and dropped again by `hide()` or when the app leaves the foreground. Until then the screen
/// knows only which of them exist (`identityKinds`, kept in the profile item without the numbers).
@MainActor @Observable
public final class TravelDocumentsStore {
    public static let profileAccount = "profile"
    public static let identityAccount = "identity"
    /// The iCloud Keychain switch, in the app's defaults. Off by default.
    public static let syncKey = "travel.icloudSync"

    public private(set) var profile = TravelProfile()
    /// The hidden numbers, nil until revealed.
    public private(set) var identity: TravelIdentity?
    /// Which hidden numbers exist, so the screen can show "••••••" rows before Face ID.
    public private(set) var identityKinds: Set<TravelDocumentKind> = []
    public private(set) var syncsWithICloud: Bool
    /// The last Keychain or check failure, for the screen.
    public private(set) var failure: String?

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let check: any DeviceOwnerCheck
    @ObservationIgnored private let defaults: UserDefaults?

    public var isRevealed: Bool { identity != nil }

    public init(secrets: any SecretStore, check: any DeviceOwnerCheck, defaults: UserDefaults? = .standard) {
        self.secrets = secrets; self.check = check; self.defaults = defaults
        syncsWithICloud = defaults?.bool(forKey: Self.syncKey) ?? false
        load()
    }

    /// The vault a launch uses: the Keychain, or memory with demo values under `-useFakes`.
    public static func forLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> TravelDocumentsStore {
        guard arguments.contains("-useFakes") else {
            return TravelDocumentsStore(secrets: KeychainSecretStore(), check: LocalDeviceOwnerCheck())
        }
        return preview(check: LocalDeviceOwnerCheck())
    }

    /// Demo values in memory: an Air France and a United number, a passport expiring early 2027.
    public static func preview(check: any DeviceOwnerCheck = FakeDeviceOwnerCheck()) -> TravelDocumentsStore {
        let mem = MemorySecretStore()
        let store = TravelDocumentsStore(secrets: mem, check: check, defaults: nil)
        _ = store.saveLoyalty(airline: "AFR", number: "1234567890", programme: "Flying Blue")
        _ = store.saveLoyalty(airline: "UAL", number: "AB123456", programme: nil)
        store.write(profile: TravelProfile(loyalty: store.profile.loyalty, passportCountry: "FR",
                                           passportExpires: "2027-03-12"),
                    identity: TravelIdentity(passportNumber: "19AB12345", knownTraveler: "TT1234567", redress: nil))
        store.hide()
        return store
    }

    // MARK: Reading

    /// Reads the profile and which hidden numbers exist. Never reads the numbers themselves.
    public func load() {
        do {
            if let data = try secrets.read(Self.profileAccount) {
                let kept = try JSONDecoder().decode(Kept.self, from: data)
                profile = kept.profile
                identityKinds = Set(kept.identityKinds.compactMap(TravelDocumentKind.init(rawValue:)))
            } else {
                profile = TravelProfile(); identityKinds = []
            }
            failure = nil
        } catch {
            failure = Self.failureText
        }
    }

    /// Asks for Face ID or the passcode, then reads the hidden numbers. True when they show.
    @discardableResult
    public func reveal() async -> Bool {
        if identity != nil { return true }
        guard await check.confirm(reason: "Show your travel document numbers") else { return false }
        do {
            identity = try secrets.read(Self.identityAccount).map { try JSONDecoder().decode(TravelIdentity.self, from: $0) }
                ?? TravelIdentity()
            failure = nil
            return true
        } catch {
            failure = Self.failureText
            return false
        }
    }

    /// Forgets the hidden numbers until the next `reveal()`.
    public func hide() { identity = nil }

    /// What a row shows: the number when revealed (or a loyalty number), else its mask; nil when there is none.
    public func display(_ kind: TravelDocumentKind, loyalty: LoyaltyNumber? = nil) -> String? {
        if kind == .loyalty { return loyalty?.number }
        guard identityKinds.contains(kind) else { return nil }
        guard let identity else { return "••••••" }
        return value(kind, in: identity).map { $0 }
    }

    /// The number to copy: a loyalty number at once, a hidden one after `reveal()`.
    public func copyValue(_ kind: TravelDocumentKind, loyalty: LoyaltyNumber? = nil) async -> String? {
        if kind == .loyalty { return loyalty?.number }
        guard identityKinds.contains(kind), await reveal(), let identity else { return nil }
        return value(kind, in: identity)
    }

    // MARK: Writing

    /// Adds or replaces (same id) a loyalty number. Returns false, and changes nothing, when invalid.
    @discardableResult
    public func saveLoyalty(id: UUID = UUID(), airline: String, number: String, programme: String?) -> Bool {
        guard let n = TravelDocumentRules.validated(number, as: .loyalty), !airline.isEmpty else { return false }
        let name = programme?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = LoyaltyNumber(id: id, airline: airline, number: n, programme: name?.isEmpty == false ? name : nil)
        var p = profile
        if let i = p.loyalty.firstIndex(where: { $0.id == id }) { p.loyalty[i] = entry } else { p.loyalty.append(entry) }
        return writeProfile(p)
    }

    public func deleteLoyalty(_ id: UUID) {
        var p = profile
        p.loyalty.removeAll { $0.id == id }
        writeProfile(p)
    }

    /// Saves the passport's country and expiry (free to read) and, when given, its number (hidden). A nil
    /// number keeps the one kept; an empty one removes it. False when the number is invalid.
    @discardableResult
    public func savePassport(number: String?, country: String?, expires: Date?) async -> Bool {
        var p = profile
        p.passportCountry = country.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        p.passportExpires = expires.map { TravelDocumentRules.dayString($0) }
        guard let number else { return writeProfile(p) }
        return await saveHidden(.passport, number, profile: p)
    }

    /// Saves (or with an empty string removes) a Known Traveler or Redress number. Reveals first, so the
    /// other hidden numbers are kept. False when invalid or the check failed.
    @discardableResult
    public func saveHidden(_ kind: TravelDocumentKind, _ raw: String) async -> Bool {
        await saveHidden(kind, raw, profile: profile)
    }

    private func saveHidden(_ kind: TravelDocumentKind, _ raw: String, profile p: TravelProfile) async -> Bool {
        guard kind.isSensitive else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String?
        if trimmed.isEmpty { value = nil } else {
            guard let v = TravelDocumentRules.validated(trimmed, as: kind) else { return false }
            value = v
        }
        // Writing replaces the whole item: the numbers already kept must be read first.
        if !identityKinds.isEmpty, !(await reveal()) { return false }
        var id = identity ?? TravelIdentity()
        switch kind {
        case .passport: id.passportNumber = value
        case .knownTraveler: id.knownTraveler = value
        case .redress: id.redress = value
        case .loyalty: return false
        }
        return write(profile: p, identity: id)
    }

    /// Turns iCloud Keychain sync on or off, rewriting both items with the new setting.
    public func setSync(_ on: Bool) async {
        guard on != syncsWithICloud else { return }
        if !identityKinds.isEmpty, !(await reveal()) { return }
        syncsWithICloud = on
        defaults?.set(on, forKey: Self.syncKey)
        write(profile: profile, identity: identity ?? TravelIdentity())
    }

    /// Removes every travel document from this device (and from iCloud Keychain when they synced).
    public func deleteAll() {
        do {
            try secrets.delete(Self.profileAccount)
            try secrets.delete(Self.identityAccount)
            profile = TravelProfile(); identity = nil; identityKinds = []; failure = nil
        } catch {
            failure = Self.failureText
        }
    }

    // MARK: Flight sheet

    /// The loyalty numbers that fit a flight on `airline` (`TravelDocumentRules.loyalty`).
    public func loyalty(for airline: Airline?, reference: ReferenceData) -> (own: LoyaltyNumber?, partners: [LoyaltyNumber]) {
        TravelDocumentRules.loyalty(for: airline, in: profile.loyalty, lookup: { reference.airline($0) })
    }

    /// The passport row's words for a flight, nil when there is nothing to say.
    public func passportNotice(departure: Date?, international: Bool) -> (title: String, text: String)? {
        TravelDocumentRules.passportNotice(expires: profile.passportExpires, departure: departure,
                                           international: international).map(TravelDocumentRules.passportText)
    }

    // MARK: Private

    private struct Kept: Codable {
        var profile: TravelProfile
        var identityKinds: [String]
    }

    static let failureText = "Couldn't reach the Keychain. Unlock the device and try again."

    private func value(_ kind: TravelDocumentKind, in id: TravelIdentity) -> String? {
        switch kind {
        case .passport: id.passportNumber
        case .knownTraveler: id.knownTraveler
        case .redress: id.redress
        case .loyalty: nil
        }
    }

    private static func kinds(_ id: TravelIdentity) -> Set<TravelDocumentKind> {
        var out = Set<TravelDocumentKind>()
        if id.passportNumber != nil { out.insert(.passport) }
        if id.knownTraveler != nil { out.insert(.knownTraveler) }
        if id.redress != nil { out.insert(.redress) }
        return out
    }

    @discardableResult
    private func writeProfile(_ p: TravelProfile) -> Bool {
        do {
            let kept = Kept(profile: p, identityKinds: identityKinds.map(\.rawValue).sorted())
            try secrets.write(try JSONEncoder().encode(kept), account: Self.profileAccount, synchronizable: syncsWithICloud)
            profile = p; failure = nil
            return true
        } catch {
            failure = Self.failureText
            return false
        }
    }

    @discardableResult
    fileprivate func write(profile p: TravelProfile, identity id: TravelIdentity) -> Bool {
        do {
            if id.isEmpty {
                try secrets.delete(Self.identityAccount)
            } else {
                try secrets.write(try JSONEncoder().encode(id), account: Self.identityAccount,
                                  synchronizable: syncsWithICloud)
            }
            let kinds = Self.kinds(id)
            let kept = Kept(profile: p, identityKinds: kinds.map(\.rawValue).sorted())
            try secrets.write(try JSONEncoder().encode(kept), account: Self.profileAccount, synchronizable: syncsWithICloud)
            profile = p; identity = id; identityKinds = kinds; failure = nil
            return true
        } catch {
            failure = Self.failureText
            return false
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The travel documents vault Settings and the flight sheet read; nil hides their rows.
    @Entry public var travelDocuments: TravelDocumentsStore? = nil
}
