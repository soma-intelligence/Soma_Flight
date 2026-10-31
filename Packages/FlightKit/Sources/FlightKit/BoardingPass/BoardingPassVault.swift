import Foundation
import Synchronization

/// Where one account's boarding passes live on this device, one per followed flight.
///
/// A boarding pass is personal data: the passenger's name, the booking reference and a barcode that
/// boards them. It stays on the device, in the app's own container with file protection, and is never
/// sent to the server; that is also why it works offline at the gate.
public protocol BoardingPassVault: Sendable {
    /// The pass attached to the flight, nil when there is none.
    func pass(for flight: Flight.ID) async -> BoardingPass?
    /// The Wallet pass file the pass came from, kept to add it to Apple Wallet; nil for a scanned one.
    func walletFile(for flight: Flight.ID) async -> Data?
    /// Stores `pass` under its `flightId`, replacing the flight's earlier pass and file.
    func save(_ pass: BoardingPass, walletFile: Data?) async throws
    func remove(for flight: Flight.ID) async
}

/// Every account's vault on this device: one folder per account under Application Support, or memory.
public struct BoardingPassShelf: Sendable {
    private enum Kind: Sendable {
        case disk(URL)
        case memory(MemoryPasses)
    }

    private let kind: Kind

    /// Application Support/BoardingPasses.
    public static func onDisk() -> BoardingPassShelf {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return BoardingPassShelf(directory: base.appending(path: "BoardingPasses", directoryHint: .isDirectory))
    }

    /// A shelf in `directory` (tests use a temporary one).
    public init(directory: URL) { kind = .disk(directory) }

    /// Kept in memory only. `seed` passes show for every account (the fakes' AF 84 pass).
    public static func inMemory(seed: [BoardingPass] = []) -> BoardingPassShelf {
        BoardingPassShelf(kind: .memory(MemoryPasses(seed: seed)))
    }

    private init(kind: Kind) { self.kind = kind }

    /// The vault of `owner`, the account signed in now (nil: nobody).
    public func vault(for owner: UUID?) -> any BoardingPassVault {
        let key = owner?.uuidString.lowercased() ?? "signed-out"
        switch kind {
        case .disk(let root): return FileBoardingPassVault(directory: root.appending(path: key, directoryHint: .isDirectory))
        case .memory(let passes): return MemoryBoardingPassVault(owner: key, passes: passes)
        }
    }

    /// Deletes every account's passes but `owner`'s: the device changed hands.
    public func keepOnly(_ owner: UUID?) {
        let key = owner?.uuidString.lowercased() ?? "signed-out"
        switch kind {
        case .disk(let root):
            let fm = FileManager.default
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where folder.lastPathComponent != key {
                try? fm.removeItem(at: folder)
            }
        case .memory(let passes):
            passes.keepOnly(key)
        }
    }
}

/// One account's passes as files: `<flight id>.json` and, for a Wallet pass, `<flight id>.pkpass`.
public actor FileBoardingPassVault: BoardingPassVault {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(_ id: Flight.ID, _ ext: String) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).\(ext)")
    }

    public func pass(for flight: Flight.ID) -> BoardingPass? {
        guard let data = try? Data(contentsOf: url(flight, "json")) else { return nil }
        return try? JSONDecoder().decode(BoardingPass.self, from: data)
    }

    public func walletFile(for flight: Flight.ID) -> Data? {
        try? Data(contentsOf: url(flight, "pkpass"))
    }

    public func save(_ pass: BoardingPass, walletFile: Data?) throws {
        guard let id = pass.flightId else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable once the phone has been unlocked after a restart: the pass must open at the gate even
        // when the phone locked again on the way.
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pass).write(to: url(id, "json"), options: options)
        if let walletFile {
            try walletFile.write(to: url(id, "pkpass"), options: options)
        } else {
            try? FileManager.default.removeItem(at: url(id, "pkpass"))
        }
    }

    public func remove(for flight: Flight.ID) {
        try? FileManager.default.removeItem(at: url(flight, "json"))
        try? FileManager.default.removeItem(at: url(flight, "pkpass"))
    }
}

/// The in-memory shelf's contents, every account's, behind a lock.
final class MemoryPasses: Sendable {
    private struct Held: Sendable { var pass: BoardingPass; var file: Data? }
    private let held = Mutex<[String: [Flight.ID: Held]]>([:])
    /// Seed passes, by flight, shown to any account until it changes or removes them.
    private let seed: [Flight.ID: BoardingPass]
    private let removedSeeds = Mutex<Set<String>>([])

    init(seed: [BoardingPass]) {
        self.seed = Dictionary(seed.compactMap { p in p.flightId.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
    }

    func pass(_ owner: String, _ id: Flight.ID) -> BoardingPass? {
        if let p = held.withLock({ $0[owner]?[id]?.pass }) { return p }
        return removedSeeds.withLock { $0.contains("\(owner)/\(id)") } ? nil : seed[id]
    }

    func file(_ owner: String, _ id: Flight.ID) -> Data? { held.withLock { $0[owner]?[id]?.file } }

    func save(_ owner: String, _ pass: BoardingPass, _ file: Data?) {
        guard let id = pass.flightId else { return }
        held.withLock { $0[owner, default: [:]][id] = Held(pass: pass, file: file) }
    }

    func remove(_ owner: String, _ id: Flight.ID) {
        held.withLock { _ = $0[owner]?.removeValue(forKey: id) }
        removedSeeds.withLock { _ = $0.insert("\(owner)/\(id)") }
    }

    func keepOnly(_ owner: String) {
        held.withLock { $0 = $0.filter { $0.key == owner } }
    }
}

struct MemoryBoardingPassVault: BoardingPassVault {
    let owner: String
    let passes: MemoryPasses

    func pass(for flight: Flight.ID) async -> BoardingPass? { passes.pass(owner, flight) }
    func walletFile(for flight: Flight.ID) async -> Data? { passes.file(owner, flight) }
    func save(_ pass: BoardingPass, walletFile: Data?) async throws {
        guard pass.flightId != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        passes.save(owner, pass, walletFile)
    }
    func remove(for flight: Flight.ID) async { passes.remove(owner, flight) }
}
