import Foundation
import os
import Supabase
import Synchronization

/// What `brand-asset` answers (docs/api-contract.md): the version, the stored format, and a signed path
/// into our bucket (plus the 192 px rendition of a rasterised vector, when there is one). The backend
/// answers paths relative to the project (`/storage/v1/object/sign/...`); `resolved(against:)` joins them to
/// the project URL the app was configured with, so the downloader's same-host rule holds by construction.
public struct BrandAssetMeta: Decodable, Sendable, Equatable {
    public var version: String
    public var format: String
    public var width: Int?
    public var url: URL
    public var smallUrl: URL?

    public init(version: String, format: String, width: Int? = nil, url: URL, smallUrl: URL? = nil) {
        self.version = version; self.format = format; self.width = width; self.url = url; self.smallUrl = smallUrl
    }

    /// The URLs joined to `project`. An absolute URL stays as it is (and the downloader then checks its host).
    public func resolved(against project: URL) -> BrandAssetMeta {
        var copy = self
        copy.url = Self.join(url, project)
        copy.smallUrl = smallUrl.map { Self.join($0, project) }
        return copy
    }

    static func join(_ url: URL, _ project: URL) -> URL {
        guard url.scheme == nil else { return url }
        return URL(string: url.relativeString, relativeTo: project)?.absoluteURL ?? url
    }
}

/// The two network calls the brand cache makes. `meta` throws `.notFound` when there is no asset.
public protocol BrandAssetTransport: Sendable {
    func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta
    func download(_ url: URL) async throws(APIError) -> Data
}

/// Fetches signed storage URLs from the project's own host only: the first URL and every redirect must
/// keep its scheme and host, and the body is cut off past `maxBytes` while it streams.
struct BrandDownloader: Sendable {
    let projectURL: URL
    let session: URLSession
    let maxBytes: Int
    /// Larger answers are refused: the backend stores logos at 384 px and side views at a few thousand.
    static let defaultMaxBytes = 8 << 20
    static let timeout: TimeInterval = 10

    /// - Parameter configuration: the tests pass one with a stub protocol.
    init(projectURL: URL, configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = defaultMaxBytes) {
        let config = configuration
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout * 3
        config.urlCache = nil
        self.projectURL = projectURL
        self.maxBytes = maxBytes
        self.session = URLSession(configuration: config, delegate: Guard(projectURL: projectURL), delegateQueue: nil)
    }

    /// True for a URL on the project's scheme and host (https, or http to the local stack in Debug).
    static func allows(_ url: URL?, project: URL) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return false }
        return scheme == project.scheme?.lowercased() && host == project.host()?.lowercased()
            && url.port == project.port
    }

    /// Refuses a redirect that leaves the project's host: the redirect answer itself comes back instead.
    final class Guard: NSObject, URLSessionTaskDelegate, Sendable {
        let projectURL: URL
        init(projectURL: URL) { self.projectURL = projectURL }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            BrandDownloader.allows(request.url, project: projectURL) ? request : nil
        }
    }

    func download(_ url: URL) async throws(APIError) -> Data {
        guard Self.allows(url, project: projectURL) else { throw .providerUnavailable }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw APIError.providerUnavailable }
            if http.statusCode == 404 { throw APIError.notFound }
            guard http.statusCode == 200, http.expectedContentLength <= Int64(maxBytes) else {
                throw APIError.providerUnavailable
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw APIError.providerUnavailable }
            }
            return data
        } catch {
            throw SupabaseBackend.map(error)
        }
    }
}

/// `brand-asset` through the shared client, files through `BrandDownloader`.
struct SupabaseBrandAssetTransport: BrandAssetTransport {
    let backend: SupabaseBackend
    let downloader: BrandDownloader

    init(backend: SupabaseBackend) {
        self.backend = backend
        downloader = BrandDownloader(projectURL: backend.projectURL)
    }

    func meta(airline: String, kind: BrandAssetKind, type: String?) async throws(APIError) -> BrandAssetMeta {
        var query = [URLQueryItem(name: "airline", value: airline), URLQueryItem(name: "kind", value: kind.rawValue)]
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        let project = backend.projectURL
        return try await backend.call("brand-asset", method: .get, query: query) { data in
            try JSONDecoder().decode(BrandAssetMeta.self, from: data).resolved(against: project)
        }
    }

    func download(_ url: URL) async throws(APIError) -> Data { try await downloader.download(url) }
}

/// Brand images from `brand-asset`, kept on disk by version.
///
/// - Files: `<cacheDir>/<ICAO>/<kind>[-<TYPE>]-<version>.<ext>`, plus `index.json` (version, file, size, last
///   check and last use per key, and the misses). Files the index does not name are swept once per run.
/// - A cached file is returned at once. Past `revalidateAfter` (7 days) the backend is asked again in the
///   background (one request per key): the same version only touches the entry, a new one is downloaded,
///   replaces the file and the old file goes; the caller sees it on its next ask.
/// - Every network call gives up after `requestLimit` (10 s).
/// - A 404 is remembered for `missLifetime` (24 h). A failure (offline, timeout, server) is not a miss: it
///   keeps the cached file, answers `.unavailable` when there is none, and is retried at most once per
///   `retryInterval` (1 minute) per key.
/// - A file that does not read as an image is deleted and treated as a miss.
/// - The files stay under `maxBytes` (64 MB): the least recently used go first.
public actor SupabaseBrandAssetService: BrandAssetService {
    public static let revalidateAfter: TimeInterval = 7 * 24 * 3600
    public static let missLifetime: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 60
    public static let requestLimit: Duration = .seconds(10)
    public static let defaultMaxBytes = 64 << 20

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
        var bytes: Int?
        var usedAt: Date?
    }

    struct Index: Codable, Equatable {
        var entries: [String: Entry] = [:]
        var misses: [String: Date] = [:]
    }

    private let dir: URL
    private let transport: any BrandAssetTransport
    private let clock: @Sendable () -> Date
    private let maxBytes: Int
    private let limit: Duration
    private var index: Index?
    private var failedAt: [String: Date] = [:]
    /// Files already read as images this run.
    private var verified: Set<String> = []
    /// Assets that could not be written to disk, kept for this run so they are not downloaded again.
    private var unwritten: [String: BrandAsset] = [:]
    /// One request per key at a time: a list of twenty United flights asks once.
    private var running: [String: Task<BrandLookup, Never>] = [:]
    private var revalidating: [String: Task<Void, Never>] = [:]

    static let log = Logger(subsystem: "me.somalabs.flight", category: "brand")

    /// The app's cache over `brand-asset`.
    public init(backend: SupabaseBackend, cacheDir: URL = SupabaseBrandAssetService.defaultDirectory,
                transport: (any BrandAssetTransport)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(transport: transport ?? SupabaseBrandAssetTransport(backend: backend), cacheDir: cacheDir, clock: clock)
    }

    /// Any transport (tests).
    init(transport: any BrandAssetTransport, cacheDir: URL, clock: @escaping @Sendable () -> Date = { Date() },
         maxBytes: Int = SupabaseBrandAssetService.defaultMaxBytes, limit: Duration = SupabaseBrandAssetService.requestLimit) {
        self.dir = cacheDir
        self.transport = transport
        self.clock = clock
        self.maxBytes = maxBytes
        self.limit = limit
    }

    // MARK: BrandAssetService

    public func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        await lookup(icao, kind, type: type).asset
    }

    public func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup {
        guard let key = Self.key(icao, kind, type) else { return .missing }
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

    private func resolve(key: String, airline: String, kind: BrandAssetKind, type: String?) async -> BrandLookup {
        var idx = loadIndex()
        let now = clock()
        if let kept = unwritten[key] { return .found(kept) }

        if let entry = idx.entries[key] {
            if let cached = readFile(entry) {
                idx.entries[key]?.usedAt = now
                index = idx
                if now.timeIntervalSince(entry.checkedAt) >= Self.revalidateAfter {
                    startRevalidation(key: key, entry: entry, airline: airline, kind: kind, type: type)
                }
                return .found(cached)
            }
            // Gone or broken: drop it and fetch as if never cached.
            removeFile(entry.file)
            idx.entries[key] = nil
            index = idx
            save()
        }

        if let missed = idx.misses[key], now.timeIntervalSince(missed) < Self.missLifetime { return .missing }
        guard canTry(key, now) else { return .unavailable }
        switch await fetchMeta(airline: airline, kind: kind, type: type) {
        case .success(let meta):
            return await store(key: key, meta: meta, kind: kind, replacing: nil)
        case .failure(.notFound):
            remember(miss: key)
            return .missing
        case .failure(let error):
            noteFailure(key, error)
            return .unavailable
        }
    }

    private func startRevalidation(key: String, entry: Entry, airline: String, kind: BrandAssetKind, type: String?) {
        guard revalidating[key] == nil, canTry(key, clock()) else { return }
        revalidating[key] = Task {
            await self.revalidate(key: key, entry: entry, airline: airline, kind: kind, type: type)
            self.revalidationDone(key)
        }
    }

    private func revalidationDone(_ key: String) { revalidating[key] = nil }

    private func revalidate(key: String, entry: Entry, airline: String, kind: BrandAssetKind, type: String?) async {
        switch await fetchMeta(airline: airline, kind: kind, type: type) {
        case .success(let meta) where meta.version == entry.version:
            var idx = loadIndex()
            idx.entries[key]?.checkedAt = clock()
            index = idx
            save()
        case .success(let meta):
            _ = await store(key: key, meta: meta, kind: kind, replacing: entry)
        case .failure(.notFound):
            // The backend dropped it: so does the device.
            removeFile(entry.file)
            var idx = loadIndex()
            idx.entries[key] = nil
            index = idx
            remember(miss: key)
        case .failure(let error):
            noteFailure(key, error)
        }
    }

    /// Downloads the meta's file, checks it reads as an image, writes it and its entry, deletes the file it
    /// replaces and trims the cache. A file that does not read is a miss; a failed download keeps what
    /// was there.
    private func store(key: String, meta: BrandAssetMeta, kind: BrandAssetKind, replacing old: Entry?) async -> BrandLookup {
        let format = meta.format.lowercased()
        // Square marks are drawn at most a few dozen points wide: the 192 px rendition is enough when there is one.
        let small = kind == .logo || kind == .logoDark || kind == .tail
        let source = small ? (meta.smallUrl ?? meta.url) : meta.url
        let data: Data
        switch await fetch(source) {
        case .success(let d): data = d
        case .failure(let error):
            noteFailure(key, error)
            return .unavailable
        }
        let asset = BrandAsset(data: data, format: format, version: meta.version)
        guard asset.decodes else {
            Self.log.error("brand \(key, privacy: .public) v\(meta.version, privacy: .public) is not a usable image")
            if let old { removeFile(old.file) }
            var idx = loadIndex()
            idx.entries[key] = nil
            index = idx
            remember(miss: key)
            return .missing
        }
        let file = Self.fileName(key: key, version: meta.version, format: format)
        let url = dir.appending(path: file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Kept in memory for this run: no download loop, and the next run tries the disk again.
            Self.log.error("brand \(key, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            unwritten[key] = asset
            return .found(asset)
        }
        if let old, old.file != file { removeFile(old.file) }
        let now = clock()
        var idx = loadIndex()
        idx.entries[key] = Entry(version: meta.version, format: format, file: file, checkedAt: now, bytes: data.count,
                                 usedAt: now)
        idx.misses[key] = nil
        index = idx
        verified.insert(file)
        failedAt[key] = nil
        evict(keeping: key)
        save()
        return .found(asset)
    }

    /// "UAL/logo-<version>.png". The version keeps letters, digits, dot, dash and underscore only.
    static func fileName(key: String, version: String, format: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let safe = String(version.prefix(64).map { allowed.contains($0) ? $0 : "_" })
        let ext = format.filter { $0.isLetter }
        return "\(key)-\(safe).\(ext.isEmpty ? "img" : ext)"
    }

    // MARK: Network, time-limited

    private func fetchMeta(airline: String, kind: BrandAssetKind, type: String?) async -> Result<BrandAssetMeta, APIError> {
        let transport = transport
        return await Self.limited(limit) { () async throws(APIError) -> BrandAssetMeta in
            try await transport.meta(airline: airline, kind: kind, type: type)
        }
    }

    private func fetch(_ url: URL) async -> Result<Data, APIError> {
        let transport = transport
        return await Self.limited(limit) { () async throws(APIError) -> Data in try await transport.download(url) }
    }

    /// The operation's result, or `.offline` once `limit` has passed.
    static func limited<T: Sendable>(_ limit: Duration,
                                     _ operation: @escaping @Sendable () async throws(APIError) -> T) async -> Result<T, APIError> {
        let box = Mutex<Result<T, APIError>?>(nil)
        await waitingAtMost(limit) {
            let r: Result<T, APIError>
            do throws(APIError) { r = .success(try await operation()) } catch { r = .failure(error) }
            box.withLock { $0 = r }
        }
        return box.withLock { $0 } ?? .failure(.offline)
    }

    private func noteFailure(_ key: String, _ error: APIError) {
        failedAt[key] = clock()
        Self.log.error("brand \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: Disk

    private func readFile(_ entry: Entry) -> BrandAsset? {
        guard let data = try? Data(contentsOf: dir.appending(path: entry.file)) else { return nil }
        let asset = BrandAsset(data: data, format: entry.format, version: entry.version)
        if verified.contains(entry.file) { return asset }
        guard asset.decodes else {
            Self.log.error("brand file \(entry.file, privacy: .public) is not a usable image, dropped")
            return nil
        }
        verified.insert(entry.file)
        return asset
    }

    private func removeFile(_ file: String) {
        verified.remove(file)
        try? FileManager.default.removeItem(at: dir.appending(path: file))
    }

    /// Deletes the least recently used files until the total is under `maxBytes`; `key` (just stored) stays.
    private func evict(keeping key: String) {
        var idx = loadIndex()
        var total = idx.entries.values.reduce(0) { $0 + ($1.bytes ?? 0) }
        guard total > maxBytes else { return }
        let oldest = idx.entries.filter { $0.key != key }.sorted {
            ($0.value.usedAt ?? $0.value.checkedAt) < ($1.value.usedAt ?? $1.value.checkedAt)
        }
        for (k, e) in oldest where total > maxBytes {
            removeFile(e.file)
            idx.entries[k] = nil
            total -= e.bytes ?? 0
        }
        index = idx
    }

    /// Deletes files under the cache directory that no entry names (old versions, interrupted writes).
    private func sweep(_ idx: Index) {
        let named = Set(idx.entries.values.map(\.file))
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let base = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            let rel = String(path.dropFirst(base.count))
            if rel != "index.json", !named.contains(rel) { try? FileManager.default.removeItem(at: url) }
        }
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
        let loaded = (try? Data(contentsOf: indexURL)).flatMap { try? Self.decoder.decode(Index.self, from: $0) }
            ?? Index()
        index = loaded
        sweep(loaded)
        return loaded
    }

    private func save() {
        guard let index else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            Self.log.error("brand index not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: Tests

    /// The index as saved (tests).
    func savedIndex() -> Index { loadIndex() }

    /// Waits for the background revalidations under way (tests).
    func settle() async {
        while let task = revalidating.values.first { await task.value }
    }
}
