import Foundation
import SwiftData

public enum CacheKey: String, Sendable {
    case flights, past
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

    public func save(flights: [Flight]) { put(flights, as: .flights) }
    public func flights() -> [Flight] { get(.flights) ?? [] }
    public func save(past: [PastFlight]) { put(past, as: .past) }
    public func past() -> [PastFlight] { get(.past) ?? [] }
    public func savedAt(_ key: CacheKey) -> Date? { blob(key)?.savedAt }
    public func flightsSavedAt() -> Date? { savedAt(.flights) }
    public func pastSavedAt() -> Date? { savedAt(.past) }

    /// Drops every saved payload, so the next account on the device starts empty.
    public func clear() {
        let all = (try? modelContext.fetch(FetchDescriptor<CachedBlob>())) ?? []
        for b in all { modelContext.delete(b) }
        try? modelContext.save()
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
