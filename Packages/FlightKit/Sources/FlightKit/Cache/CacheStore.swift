import Foundation
import os
import Synchronization
import SwiftData

public enum CacheKey: String, Sendable {
    case flights, past
    /// The offline packs of flights about to leave or in the air (`OfflineFlightPack`).
    case offline
    /// The user id the saved payloads belong to; absent while nobody has signed in.
    case owner
}

/// One encoded JSON payload per key, replaced on every save.
@Model
final class CachedBlob {
    @Attribute(.unique) var key: String
    var data: Data
    var savedAt: Date

    init(key: String, data: Data, savedAt: Date) {
        self.key = key; self.data = data; self.savedAt = savedAt
    }
}

/// Last known state for offline launches: the followed list and the Passport history.
@ModelActor
public actor CacheStore: FlightListCache, PastFlightCache, OfflinePackCache {
    /// Bumped by every successful wipe. A `CacheScope` taken before a wipe can no longer write, so a load
    /// still in flight for the previous account cannot put its data back after the wipe. A failed wipe
    /// leaves it alone, so the account that stays signed in keeps a working cache.
    private nonisolated let generation = Mutex(0)

    public static func inMemory() throws -> CacheStore {
        try make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// On-disk store at `url`, by default `Application Support/SomaFlight/cache.store`. Its folder is made
    /// when missing and kept out of iCloud and device backups (a cache of personal data, rebuilt from the
    /// backend). The store earlier builds left at SwiftData's default location (`default.store` and its
    /// `-wal` and `-shm` files in `legacyDirectory`) is deleted rather than migrated, so a sign-out or an
    /// account deletion leaves no older copy of the account's flights behind.
    public static func onDisk(url: URL = defaultURL,
                              legacyDirectory: URL = .applicationSupportDirectory) throws -> CacheStore {
        removeLegacyStore(in: legacyDirectory)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try folder.setResourceValues(values) } catch {
            log.error("Excluding the cache from backups failed: \(String(describing: error), privacy: .public)")
        }
        return try make(configuration: ModelConfiguration("cache", url: url))
    }

    private static let log = Logger(subsystem: "me.somalabs.flight", category: "cache")

    /// Best effort: a file that cannot go is logged and tried again at the next launch.
    static func removeLegacyStore(in directory: URL) {
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let file = directory.appending(path: name, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: file.path()) else { continue }
            do { try FileManager.default.removeItem(at: file) } catch {
                log.error("Removing the old cache \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `Application Support/SomaFlight/cache.store` (inside the app's container on both platforms).
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "SomaFlight", directoryHint: .isDirectory)
            .appending(path: "cache.store", directoryHint: .notDirectory)
    }

    private static func make(configuration: ModelConfiguration) throws -> CacheStore {
        CacheStore(modelContainer: try ModelContainer(for: CachedBlob.self, configurations: configuration))
    }

    /// The cache as `owner`'s stores see it (nil: nobody signed in). It reads as empty and drops writes
    /// while the cache belongs to someone else, and stops writing after the next wipe.
    public nonisolated func scoped(for owner: UUID?) -> CacheScope {
        CacheScope(store: self, owner: owner, generation: generation.withLock { $0 })
    }

    public func save(flights: [Flight]) { put(flights, as: .flights) }
    public func flights() -> [Flight] { get(.flights) ?? [] }
    public func save(past: [PastFlight]) { put(past, as: .past) }
    public func past() -> [PastFlight] { get(.past) ?? [] }
    public func savedAt(_ key: CacheKey) -> Date? { blob(key)?.savedAt }

    /// Keeps `pack` in place of any earlier one for the same flight, and drops stale packs.
    public func save(pack: OfflineFlightPack) {
        let others = packs().filter { $0.flight.id != pack.flight.id }
        put(OfflineFlightPack.pruned([pack] + others, now: .now), as: .offline)
    }
    public func pack(for id: Flight.ID) -> OfflineFlightPack? { packs().first { $0.flight.id == id } }
    func packs() -> [OfflineFlightPack] { get(.offline) ?? [] }
    public func flightsSavedAt() -> Date? { savedAt(.flights) }
    public func pastSavedAt() -> Date? { savedAt(.past) }

    /// Drops every saved payload, so the next account on the device starts empty. On failure nothing
    /// is dropped and the error is thrown: the caller must not report the device as clean.
    public func clear() throws {
        try wipe(owner: nil)
    }

    /// The user the saved payloads belong to; nil when nobody has signed in since the last wipe, or
    /// when the record is unreadable (`isOwned(by:)` treats that as nobody's).
    public func owner() -> UUID? {
        ownerRecord().flatMap(UUID.init(uuidString:))
    }

    /// Whether the saved payloads belong to `user` (nil: nobody). The one comparison `claim(for:)` and
    /// the scoped readers use: an unreadable owner record belongs to no one, not even to nobody.
    public func isOwned(by user: UUID?) -> Bool {
        ownerRecord() == user?.uuidString
    }

    #if DEBUG
    /// Tests: writes a raw owner record, readable or not.
    func setOwnerRecord(_ raw: String) {
        if let b = blob(.owner) { modelContext.delete(b) }
        modelContext.insert(CachedBlob(key: CacheKey.owner.rawValue, data: Data(raw.utf8), savedAt: .now))
        try? modelContext.save()
    }
    #endif

    private func ownerRecord() -> String? {
        blob(.owner).map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// Hands the cache to `user`. When it belonged to someone else (or to nobody while `user` signs in)
    /// every payload is dropped first, in one save that is rolled back on failure.
    /// - Returns: true when the previous owner's data was dropped.
    @discardableResult
    public func claim(for user: UUID?) throws -> Bool {
        guard !isOwned(by: user) else { return false }
        try wipe(owner: user)
        return true
    }

    /// Deletes every blob and records `owner`, all in one save, then closes the scopes taken before.
    /// When that save fails it is rolled back and the whole store is erased as a last resort, so a
    /// broken store cannot keep the user from signing out; only if that fails too is the error thrown.
    private func wipe(owner: UUID?) throws {
        do {
            for b in try modelContext.fetch(FetchDescriptor<CachedBlob>()) { modelContext.delete(b) }
            recordOwner(owner)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            do {
                try modelContainer.erase()
                recordOwner(owner)
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        generation.withLock { $0 += 1 }
    }

    private func recordOwner(_ owner: UUID?) {
        if let owner {
            modelContext.insert(CachedBlob(key: CacheKey.owner.rawValue, data: Data(owner.uuidString.utf8), savedAt: .now))
        }
    }

    /// Scoped access: only while the cache is `owner`'s, and writes only while no wipe happened since
    /// `generation` was taken.
    func flights(owner: UUID?) -> [Flight] { isOwned(by: owner) ? flights() : [] }
    func past(owner: UUID?) -> [PastFlight] { isOwned(by: owner) ? past() : [] }
    func savedAt(_ key: CacheKey, owner: UUID?) -> Date? { isOwned(by: owner) ? savedAt(key) : nil }
    func pack(for id: Flight.ID, owner: UUID?) -> OfflineFlightPack? { isOwned(by: owner) ? pack(for: id) : nil }
    func save(pack: OfflineFlightPack, owner: UUID?, generation g: Int) {
        if g == generation.withLock({ $0 }), isOwned(by: owner) { save(pack: pack) }
    }
    func save(flights: [Flight], owner: UUID?, generation g: Int) {
        if g == generation.withLock({ $0 }), isOwned(by: owner) { save(flights: flights) }
    }
    func save(past: [PastFlight], owner: UUID?, generation g: Int) {
        if g == generation.withLock({ $0 }), isOwned(by: owner) { save(past: past) }
    }

    private func blob(_ key: CacheKey) -> CachedBlob? {
        let raw = key.rawValue
        var d = FetchDescriptor<CachedBlob>(predicate: #Predicate { $0.key == raw })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func put<T: Encodable>(_ value: T, as key: CacheKey) {
        guard let data = try? FlightJSON.encoder.encode(value) else { return }
        if let b = blob(key) {
            b.data = data; b.savedAt = .now
        } else {
            modelContext.insert(CachedBlob(key: key.rawValue, data: data, savedAt: .now))
        }
        try? modelContext.save()
    }

    /// A blob that no longer decodes (older app version) reads as empty.
    private func get<T: Decodable>(_ key: CacheKey) -> T? {
        guard let b = blob(key) else { return nil }
        return try? FlightJSON.decoder.decode(T.self, from: b.data)
    }
}

/// The cache as one account's stores see it: empty and read-only while it belongs to someone else,
/// and closed to writes once it is wiped.
public struct CacheScope: FlightListCache, PastFlightCache, OfflinePackCache {
    let store: CacheStore
    let owner: UUID?
    let generation: Int

    public func save(flights: [Flight]) async { await store.save(flights: flights, owner: owner, generation: generation) }
    public func flights() async -> [Flight] { await store.flights(owner: owner) }
    public func flightsSavedAt() async -> Date? { await store.savedAt(.flights, owner: owner) }
    public func save(past: [PastFlight]) async { await store.save(past: past, owner: owner, generation: generation) }
    public func past() async -> [PastFlight] { await store.past(owner: owner) }
    public func pastSavedAt() async -> Date? { await store.savedAt(.past, owner: owner) }
    public func save(pack: OfflineFlightPack) async { await store.save(pack: pack, owner: owner, generation: generation) }
    public func pack(for id: Flight.ID) async -> OfflineFlightPack? { await store.pack(for: id, owner: owner) }
}
