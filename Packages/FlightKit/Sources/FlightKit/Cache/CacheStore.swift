import Foundation
import Synchronization
import SwiftData

public enum CacheKey: String, Sendable {
    case flights, past
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
public actor CacheStore: FlightListCache, PastFlightCache {
    /// Bumped by every wipe. A `CacheScope` taken before a wipe can no longer write, so a load still
    /// in flight for the previous account cannot put its data back after the wipe.
    private nonisolated let generation = Mutex(0)

    public static func inMemory() throws -> CacheStore {
        try make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// On-disk store; `url` nil uses the default location.
    public static func onDisk(url: URL? = nil) throws -> CacheStore {
        try make(configuration: url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration())
    }

    private static func make(configuration: ModelConfiguration) throws -> CacheStore {
        CacheStore(modelContainer: try ModelContainer(for: CachedBlob.self, configurations: configuration))
    }

    /// A writer tied to the current generation, for the stores of the account signed in now.
    public nonisolated func scoped() -> CacheScope { CacheScope(store: self, generation: generation.withLock { $0 }) }

    public func save(flights: [Flight]) { put(flights, as: .flights) }
    public func flights() -> [Flight] { get(.flights) ?? [] }
    public func save(past: [PastFlight]) { put(past, as: .past) }
    public func past() -> [PastFlight] { get(.past) ?? [] }
    public func savedAt(_ key: CacheKey) -> Date? { blob(key)?.savedAt }
    public func flightsSavedAt() -> Date? { savedAt(.flights) }
    public func pastSavedAt() -> Date? { savedAt(.past) }

    /// Drops every saved payload, so the next account on the device starts empty. On failure nothing
    /// is dropped and the error is thrown: the caller must not report the device as clean.
    public func clear() throws {
        generation.withLock { $0 += 1 }
        try wipe(owner: nil)
    }

    /// The user the saved payloads belong to; nil when nobody has signed in since the last wipe.
    public func owner() -> UUID? {
        blob(.owner).flatMap { String(data: $0.data, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
    }

    /// Hands the cache to `user`. When it belonged to someone else (or to nobody while `user` signs in)
    /// every payload is dropped first, in one save that is rolled back on failure.
    /// - Returns: true when the previous owner's data was dropped.
    @discardableResult
    public func claim(for user: UUID?) throws -> Bool {
        let current = blob(.owner).flatMap { String(data: $0.data, encoding: .utf8) }
        guard current != user?.uuidString else { return false }
        generation.withLock { $0 += 1 }
        try wipe(owner: user)
        return true
    }

    /// Deletes every blob and records `owner`, all in one save.
    private func wipe(owner: UUID?) throws {
        do {
            for b in try modelContext.fetch(FetchDescriptor<CachedBlob>()) { modelContext.delete(b) }
            if let owner {
                modelContext.insert(CachedBlob(key: CacheKey.owner.rawValue, data: Data(owner.uuidString.utf8), savedAt: .now))
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Writes only while no wipe happened since `generation` was taken.
    func save(flights: [Flight], generation g: Int) { if g == generation.withLock({ $0 }) { save(flights: flights) } }
    func save(past: [PastFlight], generation g: Int) { if g == generation.withLock({ $0 }) { save(past: past) } }

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

/// The cache as one account's stores see it: reads pass through, writes stop once the cache is wiped.
public struct CacheScope: FlightListCache, PastFlightCache {
    let store: CacheStore
    let generation: Int

    public func save(flights: [Flight]) async { await store.save(flights: flights, generation: generation) }
    public func flights() async -> [Flight] { await store.flights() }
    public func flightsSavedAt() async -> Date? { await store.flightsSavedAt() }
    public func save(past: [PastFlight]) async { await store.save(past: past, generation: generation) }
    public func past() async -> [PastFlight] { await store.past() }
    public func pastSavedAt() async -> Date? { await store.pastSavedAt() }
}
