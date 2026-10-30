import Foundation
import os
import Supabase

/// What `brand-asset` answers (docs/api-contract.md): the version, the stored format, and a signed URL
/// into our bucket (plus the 192 px rendition of a rasterised vector, when there is one).
public struct BrandAssetMeta: Decodable, Sendable, Equatable {
    public var version: String
    public var format: String
    public var width: Int?
    public var url: URL
    public var smallUrl: URL?

    public init(version: String, format: String, width: Int? = nil, url: URL, smallUrl: URL? = nil) {
        self.version = version; self.format = format; self.width = width; self.url = url; self.smallUrl = smallUrl
    }
}

/// The two network calls the brand cache makes. `meta` throws `.notFound` when there is no asset.
public protocol BrandAssetTransport: Sendable {
    func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta
    func download(_ url: URL) async throws(APIError) -> Data
}

/// `brand-asset` through the shared client, and the signed URL fetched only from the backend's own host.
struct SupabaseBrandAssetTransport: BrandAssetTransport {
    let backend: SupabaseBackend
    /// Larger answers are refused: the backend stores logos at 384 px and side views at a few thousand.
    static let maxBytes = 8 << 20

    func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta {
        var query = [URLQueryItem(name: "airline", value: airline), URLQueryItem(name: "kind", value: kind.rawValue)]
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        return try await backend.call("brand-asset", method: .get, query: query) { data in
            try JSONDecoder().decode(BrandAssetMeta.self, from: data)
        }
    }

    func download(_ url: URL) async throws(APIError) -> Data {
        // Only our project's storage: a signed URL pointing anywhere else is not followed.
        guard url.scheme == backend.projectURL.scheme,
              url.host()?.lowercased() == backend.projectURL.host()?.lowercased() else {
            throw .providerUnavailable
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw APIError.providerUnavailable }
            if http.statusCode == 404 { throw APIError.notFound }
            guard http.statusCode == 200, data.count <= Self.maxBytes else { throw APIError.providerUnavailable }
            return data
        } catch {
            throw SupabaseBackend.map(error)
        }
    }
}

/// Brand images from `brand-asset`, kept on disk by version.
///
/// - Files: `<cacheDir>/<ICAO>/<kind>[-<TYPE>]-<version>.<ext>`, plus `index.json` (version, file and
///   last check per key, and the misses).
/// - A cached file is used at once. Past `revalidateAfter` (7 days) the backend is asked again: the same
///   version only touches the entry, a new one is downloaded, replaces the file and the old file goes.
/// - A 404 is remembered for `missLifetime` (24 h). A network failure keeps the cached file and is retried
///   at most once per `retryInterval` (1 minute) per key.
/// - A file that does not decode is deleted and treated as a miss.
public actor SupabaseBrandAssetService: BrandAssetService {
    public static let revalidateAfter: TimeInterval = 7 * 24 * 3600
    public static let missLifetime: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 60

    /// `Caches/SomaFlight/Brand`.
    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "SomaFlight/Brand", directoryHint: .isDirectory)
    }

    struct Entry: Codable, Equatable {
        var version: String
        var format: String
        /// Relative to the cache directory.
        var file: String
        var checkedAt: Date
    }

    struct Index: Codable, Equatable {
        var entries: [String: Entry] = [:]
        var misses: [String: Date] = [:]
    }

    private let dir: URL
    private let transport: any BrandAssetTransport
    private let clock: @Sendable () -> Date
    private var index: Index?
    private var failedAt: [String: Date] = [:]
    /// Files already decoded once this run.
    private var verified: Set<String> = []
    /// One request per key at a time: a list of twenty United flights asks once.
    private var running: [String: Task<BrandAsset?, Never>] = [:]

    static let log = Logger(subsystem: "me.somalabs.flight", category: "brand")

    /// - Parameters:
    ///   - transport: the network; nil is `brand-asset` over `backend`.
    ///   - clock: now, injected by the tests.
    public init(backend: SupabaseBackend?, cacheDir: URL = SupabaseBrandAssetService.defaultDirectory,
                transport: (any BrandAssetTransport)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        precondition(backend != nil || transport != nil, "a backend or a transport")
        self.dir = cacheDir
        self.transport = transport ?? SupabaseBrandAssetTransport(backend: backend!)
        self.clock = clock
    }

    // MARK: BrandAssetService

    public func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        guard let key = Self.key(icao, kind, type) else { return nil }
        if let task = running[key] { return await task.value }
        let airline = icao.uppercased()
        let aircraft = kind == .sideView ? type?.uppercased() : nil
        let task = Task { await self.resolve(key: key, airline: airline, kind: kind, type: aircraft) }
        running[key] = task
        let result = await task.value
        running[key] = nil
        return result
    }

    /// "UAL/logo", "UAL/side_view-B38M"; nil for a code the backend would refuse.
    static func key(_ icao: String, _ kind: BrandAssetKind, _ type: String?) -> String? {
        let airline = icao.uppercased()
        guard airline.count == 3, airline.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        guard kind == .sideView else { return "\(airline)/\(kind.rawValue)" }
        guard let t = type?.uppercased(), (2...4).contains(t.count),
              t.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "\(airline)/\(kind.rawValue)-\(t)"
    }

    // MARK: Resolution

    private func resolve(key: String, airline: String, kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        var idx = loadIndex()
        let now = clock()

        if let entry = idx.entries[key] {
            if let cached = readFile(entry) {
                guard now.timeIntervalSince(entry.checkedAt) >= Self.revalidateAfter else { return cached }
                return await revalidate(key: key, entry: entry, cached: cached, airline: airline, kind: kind, type: type)
            }
            // Gone or corrupt: drop it and fetch as if never cached.
            removeFile(entry.file)
            idx.entries[key] = nil
            index = idx
            save()
        }

        if let missed = idx.misses[key], now.timeIntervalSince(missed) < Self.missLifetime { return nil }
        guard canTry(key, now) else { return nil }
        do throws(APIError) {
            let meta = try await transport.meta(airline: airline, kind: kind, type: type)
            return try await store(key: key, meta: meta, kind: kind, replacing: nil)
        } catch .notFound {
            remember(miss: key)
            return nil
        } catch {
            failedAt[key] = clock()
            Self.log.error("brand \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func revalidate(key: String, entry: Entry, cached: BrandAsset, airline: String, kind: BrandAssetKind,
                            type: String?) async -> BrandAsset? {
        guard canTry(key, clock()) else { return cached }
        do throws(APIError) {
            let meta = try await transport.meta(airline: airline, kind: kind, type: type)
            if meta.version == entry.version {
                var idx = loadIndex()
                idx.entries[key]?.checkedAt = clock()
                index = idx
                save()
                return cached
            }
            return try await store(key: key, meta: meta, kind: kind, replacing: entry)
        } catch .notFound {
            // The backend dropped it: so does the device.
            removeFile(entry.file)
            var idx = loadIndex()
            idx.entries[key] = nil
            index = idx
            remember(miss: key)
            return nil
        } catch {
            failedAt[key] = clock()
            return cached
        }
    }

    /// Downloads the meta's file, checks it decodes, writes it and its entry, and deletes the file it
    /// replaces. A file that does not decode is a miss.
    private func store(key: String, meta: BrandAssetMeta, kind: BrandAssetKind,
                       replacing old: Entry?) async throws(APIError) -> BrandAsset? {
        let format = meta.format.lowercased()
        // Logos are drawn at most a few dozen points wide: the 192 px rendition is enough when there is one.
        let source = kind == .logo || kind == .logoDark ? (meta.smallUrl ?? meta.url) : meta.url
        let data = try await transport.download(source)
        let asset = BrandAsset(data: data, format: format, version: meta.version)
        guard asset.decodes else {
            Self.log.error("brand \(key, privacy: .public) v\(meta.version, privacy: .public) does not decode")
            if let old {
                removeFile(old.file)
                var idx = loadIndex()
                idx.entries[key] = nil
                index = idx
            }
            remember(miss: key)
            return nil
        }
        let file = Self.fileName(key: key, version: meta.version, format: format)
        let url = dir.appending(path: file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("brand \(key, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            return asset
        }
        if let old, old.file != file { removeFile(old.file) }
        var idx = loadIndex()
        idx.entries[key] = Entry(version: meta.version, format: format, file: file, checkedAt: clock())
        idx.misses[key] = nil
        index = idx
        verified.insert(file)
        save()
        return asset
    }

    /// "UAL/logo-<version>.png". The version keeps letters, digits, dot, dash and underscore only.
    static func fileName(key: String, version: String, format: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(version.prefix(64).map { allowed.contains($0) ? $0 : "_" })
        let ext = format.filter { $0.isLetter }
        return "\(key)-\(safe).\(ext.isEmpty ? "img" : ext)"
    }

    // MARK: Disk

    private func readFile(_ entry: Entry) -> BrandAsset? {
        guard let data = try? Data(contentsOf: dir.appending(path: entry.file)) else { return nil }
        let asset = BrandAsset(data: data, format: entry.format, version: entry.version)
        if verified.contains(entry.file) { return asset }
        guard asset.decodes else {
            Self.log.error("brand file \(entry.file, privacy: .public) does not decode, dropped")
            return nil
        }
        verified.insert(entry.file)
        return asset
    }

    private func removeFile(_ file: String) {
        verified.remove(file)
        try? FileManager.default.removeItem(at: dir.appending(path: file))
    }

    private func remember(miss key: String) {
        var idx = loadIndex()
        idx.misses[key] = clock()
        index = idx
        save()
    }

    private func canTry(_ key: String, _ now: Date) -> Bool {
        guard let last = failedAt[key] else { return true }
        return now.timeIntervalSince(last) >= Self.retryInterval
    }

    private var indexURL: URL { dir.appending(path: "index.json") }

    private func loadIndex() -> Index {
        if let index { return index }
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? Self.coder.decoder.decode(Index.self, from: $0) }
            ?? Index()
        index = loaded
        return loaded
    }

    private func save() {
        guard let index else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.coder.encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            Self.log.error("brand index not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .secondsSince1970
        d.dateDecodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return (e, d)
    }()

    // MARK: Tests

    /// The index as saved (tests).
    func savedIndex() -> Index { loadIndex() }
}
