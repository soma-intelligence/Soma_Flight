import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// One photo the traveller added to a past flight: a downscaled copy (2048 px on the long side at most)
/// and a thumbnail, both JPEG, made on the device from the picked image.
public struct JournalPhoto: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var addedAt: Date
    /// Pixel size of the stored copy.
    public var width: Int
    public var height: Int
}

/// The travel journal of one account on this device: photos per past flight.
///
/// The photos come from the system photo picker (no photo library permission), are copied in, downscaled
/// and stripped of their metadata (place, camera), and never leave the device: no server, no sync, no
/// backup. Deleting the flight deletes its photos; signing out or deleting the account deletes them all.
public protocol TravelJournal: Sendable {
    /// The flight's photos, oldest first.
    func photos(for flight: PastFlight.ID) async -> [JournalPhoto]
    /// Copies `image` (any format ImageIO reads: HEIC, JPEG, PNG) in as the flight's newest photo.
    func add(_ image: Data, to flight: PastFlight.ID) async throws -> JournalPhoto
    /// The stored copy's JPEG bytes.
    func image(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) async -> Data?
    /// The thumbnail's JPEG bytes.
    func thumbnail(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) async -> Data?
    func remove(_ photo: JournalPhoto.ID, from flight: PastFlight.ID) async
    /// Every photo of the flight: the flight left the history.
    func removeAll(for flight: PastFlight.ID) async
}

/// Every account's journal on this device: one folder per account under Application Support, or memory.
public struct TravelJournalShelf: Sendable {
    private enum Kind: Sendable {
        case disk(URL)
        case memory(MemoryJournals)
    }

    private let kind: Kind

    /// Application Support/TravelJournal.
    public static func onDisk() -> TravelJournalShelf {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return TravelJournalShelf(directory: base.appending(path: "TravelJournal", directoryHint: .isDirectory))
    }

    /// A shelf in `directory` (tests use a temporary one).
    public init(directory: URL) { kind = .disk(directory) }

    /// Kept in memory only (the fakes, previews).
    public static func inMemory() -> TravelJournalShelf { TravelJournalShelf(kind: .memory(MemoryJournals())) }

    private init(kind: Kind) { self.kind = kind }

    static func key(_ owner: UUID?) -> String { owner?.uuidString.lowercased() ?? "signed-out" }

    /// The journal of `owner`, the account signed in now (nil: nobody).
    public func journal(for owner: UUID?) -> any TravelJournal {
        switch kind {
        case .disk(let root):
            FileTravelJournal(directory: root.appending(path: Self.key(owner), directoryHint: .isDirectory))
        case .memory(let journals):
            MemoryTravelJournal(owner: Self.key(owner), journals: journals)
        }
    }

    /// Deletes every account's photos but `owner`'s: the device changed hands (sign out, account deleted,
    /// another account signed in).
    public func keepOnly(_ owner: UUID?) {
        let key = Self.key(owner)
        switch kind {
        case .disk(let root):
            let fm = FileManager.default
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where folder.lastPathComponent != key {
                try? fm.removeItem(at: folder)
            }
        case .memory(let journals):
            journals.keepOnly(key)
        }
    }
}

/// Downscaling and re-encoding, with ImageIO: no UIKit, so it runs on every platform and in tests.
public enum JournalImage {
    /// The stored copy's long side, at most.
    public static let maxPixel = 2_048
    /// The thumbnail's long side, at most.
    public static let thumbnailPixel = 480
    static let quality = 0.82

    public enum Failure: Error, Equatable { case unreadable, unwritable }

    /// `data` as a JPEG whose long side is `maxPixel` at most (never enlarged), turned upright, with no
    /// metadata kept (no GPS, no camera details).
    public static func jpeg(_ data: Data, maxPixel: Int) throws(Failure) -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw .unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel, max(w, h) > 0 ? max(w, h) : maxPixel)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .unreadable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw .unwritable }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw .unwritable }
        return (out as Data, image.width, image.height)
    }
}

/// One account's journal as files: `<flight>/photos.json` (the order), `<photo>.jpg` and `<photo>.thumb.jpg`.
public actor FileTravelJournal: TravelJournal {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func folder(_ flight: PastFlight.ID) -> URL {
        directory.appending(path: flight.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func file(_ photo: JournalPhoto.ID, _ flight: PastFlight.ID, thumb: Bool) -> URL {
        folder(flight).appending(path: photo.uuidString.lowercased() + (thumb ? ".thumb.jpg" : ".jpg"))
    }

    private func index(_ flight: PastFlight.ID) -> URL { folder(flight).appending(path: "photos.json") }

    public func photos(for flight: PastFlight.ID) -> [JournalPhoto] {
        guard let data = try? Data(contentsOf: index(flight)) else { return [] }
        return (try? JSONDecoder().decode([JournalPhoto].self, from: data)) ?? []
    }

    public func add(_ image: Data, to flight: PastFlight.ID) throws -> JournalPhoto {
        let full = try JournalImage.jpeg(image, maxPixel: JournalImage.maxPixel)
        let thumb = try JournalImage.jpeg(full.data, maxPixel: JournalImage.thumbnailPixel)
        try prepare(flight)
        let photo = JournalPhoto(id: UUID(), addedAt: .now, width: full.width, height: full.height)
        try full.data.write(to: file(photo.id, flight, thumb: false), options: Self.writing)
        try thumb.data.write(to: file(photo.id, flight, thumb: true), options: Self.writing)
        try save(photos(for: flight) + [photo], flight)
        return photo
    }

    public func image(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) -> Data? {
        try? Data(contentsOf: file(photo, flight, thumb: false))
    }

    public func thumbnail(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) -> Data? {
        try? Data(contentsOf: file(photo, flight, thumb: true))
    }

    public func remove(_ photo: JournalPhoto.ID, from flight: PastFlight.ID) {
        let kept = photos(for: flight).filter { $0.id != photo }
        try? FileManager.default.removeItem(at: file(photo, flight, thumb: false))
        try? FileManager.default.removeItem(at: file(photo, flight, thumb: true))
        if kept.isEmpty { removeAll(for: flight) } else { try? save(kept, flight) }
    }

    public func removeAll(for flight: PastFlight.ID) {
        try? FileManager.default.removeItem(at: folder(flight))
    }

    /// Readable once the phone has been unlocked after a restart, like the boarding passes.
    private static var writing: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    /// Makes the flight's folder, and keeps the whole journal out of device and iCloud backups: the copies
    /// stay on this device only (the originals are still in the traveller's photo library).
    private func prepare(_ flight: PastFlight.ID) throws {
        try FileManager.default.createDirectory(at: folder(flight), withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory.deletingLastPathComponent()
        try? root.setResourceValues(values)
    }

    private func save(_ photos: [JournalPhoto], _ flight: PastFlight.ID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(photos).write(to: index(flight), options: Self.writing)
    }
}

/// The in-memory shelf's contents, every account's, behind a lock.
final class MemoryJournals: Sendable {
    struct Stored: Sendable { var photo: JournalPhoto; var image: Data; var thumbnail: Data }
    private let held = Mutex<[String: [PastFlight.ID: [Stored]]]>([:])

    func photos(_ owner: String, _ flight: PastFlight.ID) -> [Stored] { held.withLock { $0[owner]?[flight] ?? [] } }
    func append(_ owner: String, _ flight: PastFlight.ID, _ s: Stored) {
        held.withLock { $0[owner, default: [:]][flight, default: []].append(s) }
    }
    func remove(_ owner: String, _ flight: PastFlight.ID, _ photo: JournalPhoto.ID?) {
        held.withLock { all in
            if let photo { all[owner]?[flight]?.removeAll { $0.photo.id == photo } } else { all[owner]?[flight] = nil }
        }
    }
    func keepOnly(_ owner: String) { held.withLock { $0 = $0.filter { $0.key == owner } } }
}

struct MemoryTravelJournal: TravelJournal {
    let owner: String
    let journals: MemoryJournals

    func photos(for flight: PastFlight.ID) async -> [JournalPhoto] { journals.photos(owner, flight).map(\.photo) }

    func add(_ image: Data, to flight: PastFlight.ID) async throws -> JournalPhoto {
        let full = try JournalImage.jpeg(image, maxPixel: JournalImage.maxPixel)
        let thumb = try JournalImage.jpeg(full.data, maxPixel: JournalImage.thumbnailPixel)
        let photo = JournalPhoto(id: UUID(), addedAt: .now, width: full.width, height: full.height)
        journals.append(owner, flight, .init(photo: photo, image: full.data, thumbnail: thumb.data))
        return photo
    }

    func image(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) async -> Data? {
        journals.photos(owner, flight).first { $0.photo.id == photo }?.image
    }

    func thumbnail(_ photo: JournalPhoto.ID, of flight: PastFlight.ID) async -> Data? {
        journals.photos(owner, flight).first { $0.photo.id == photo }?.thumbnail
    }

    func remove(_ photo: JournalPhoto.ID, from flight: PastFlight.ID) async { journals.remove(owner, flight, photo) }
    func removeAll(for flight: PastFlight.ID) async { journals.remove(owner, flight, nil) }
}
