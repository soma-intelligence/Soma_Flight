import Foundation
import Security
import Synchronization
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Where the travel documents vault keeps its two items. The app's is the Keychain; tests and the fakes
/// keep them in memory.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    /// Replaces the item, wherever it was (synced or not), with one that syncs through iCloud Keychain
    /// only when `synchronizable` is true.
    func write(_ data: Data, account: String, synchronizable: Bool) throws
    func delete(_ account: String) throws
}

public struct SecretStoreError: Error, Equatable, Sendable {
    public var status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// The Keychain, as generic passwords under one service, in the data protection keychain on both iOS and
/// macOS. An item that stays on the device is readable only while it is unlocked and never leaves it (not
/// in a backup either); one the traveller chose to sync is readable while unlocked and goes through
/// iCloud Keychain, end to end encrypted. Nothing reaches Soma Flight's servers either way.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "me.soma.flight.travel-documents"
    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) { self.service = service }

    /// The query that finds the item whether it syncs or not.
    func findQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The attributes of a new item.
    func addQuery(_ data: Data, account: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecValueData as String: data,
         kSecAttrSynchronizable as String: synchronizable,
         kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleWhenUnlocked
             : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read(_ account: String) throws -> Data? {
        var q = findQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        return out as? Data
    }

    public func write(_ data: Data, account: String, synchronizable: Bool) throws {
        try delete(account)
        let status = SecItemAdd(addQuery(data, account: account, synchronizable: synchronizable) as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(findQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }
}

/// Items in memory, for tests and the fakes. Remembers whether each one was written to sync.
public final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: (data: Data, synchronizable: Bool)]>([:])
    /// Set to make every call fail, as a locked or broken Keychain would.
    private let failing = Mutex<Bool>(false)

    public init() {}

    public func read(_ account: String) throws -> Data? {
        if failing.withLock({ $0 }) { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        return items.withLock { $0[account]?.data }
    }

    public func write(_ data: Data, account: String, synchronizable: Bool) throws {
        if failing.withLock({ $0 }) { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        items.withLock { $0[account] = (data, synchronizable) }
    }

    public func delete(_ account: String) throws {
        if failing.withLock({ $0 }) { throw SecretStoreError(status: errSecInteractionNotAllowed) }
        _ = items.withLock { $0.removeValue(forKey: account) }
    }

    /// Whether the item was last written to sync; nil when there is none.
    public func isSynchronizable(_ account: String) -> Bool? { items.withLock { $0[account]?.synchronizable } }
    public var accounts: Set<String> { items.withLock { Set($0.keys) } }
    public func fail(_ on: Bool) { failing.withLock { $0 = on } }
}

/// Asks the person holding the device to prove it is theirs (Face ID, Touch ID or the passcode) before a
/// hidden number shows or is copied.
public protocol DeviceOwnerCheck: Sendable {
    func confirm(reason: String) async -> Bool
}

/// LocalAuthentication's device owner check: biometrics, falling back to the passcode or the Mac's
/// password. Fails closed on a device with neither.
public struct LocalDeviceOwnerCheck: DeviceOwnerCheck {
    public init() {}

    public func confirm(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        #else
        return false
        #endif
    }
}

/// A check that answers as told, for tests and previews; counts the times it was asked.
public final class FakeDeviceOwnerCheck: DeviceOwnerCheck {
    private let state: Mutex<(answer: Bool, asked: Int)>

    public init(answer: Bool = true) { state = Mutex((answer, 0)) }

    public func confirm(reason: String) async -> Bool {
        state.withLock { $0.asked += 1; return $0.answer }
    }

    public var asked: Int { state.withLock { $0.asked } }
    public func answer(_ a: Bool) { state.withLock { $0.answer = a } }
}
