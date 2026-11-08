import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FlightKit

/// Plan 19: photos added to a past flight, copied and kept on the device per account.
@Suite struct TravelJournalTests {
    /// A JPEG of `width` x `height` with a GPS block, like a phone photo.
    static func photo(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLongitude: 2.35]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func size(_ data: Data) -> (Int, Int, Bool) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int,
                p[kCGImagePropertyGPSDictionary] != nil)
    }

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "journal-tests-" + UUID().uuidString, directoryHint: .isDirectory)
    }

    @Test func downscalesToTheLongSideAndDropsTheMetadata() throws {
        let big = Self.photo(width: 4_032, height: 3_024)
        #expect(Self.size(big).2)
        let out = try JournalImage.jpeg(big, maxPixel: JournalImage.maxPixel)
        #expect(out.width == 2_048)
        #expect(out.height == 1_536)
        let read = Self.size(out.data)
        #expect(read.0 == 2_048 && read.1 == 1_536)
        #expect(!read.2, "the place the photo was taken must not be kept")
        // A small photo is never enlarged.
        let small = try JournalImage.jpeg(Self.photo(width: 800, height: 1_200), maxPixel: JournalImage.maxPixel)
        #expect(small.width == 800 && small.height == 1_200)
        #expect(throws: JournalImage.Failure.unreadable) { try JournalImage.jpeg(Data("not a photo".utf8), maxPixel: 10) }
    }

    @Test func addListAndDeleteOnDisk() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = TravelJournalShelf(directory: dir).journal(for: UUID())
        let flight = UUID(), other = UUID()
        let a = try await journal.add(Self.photo(width: 3_000, height: 2_000), to: flight)
        let b = try await journal.add(Self.photo(width: 600, height: 400), to: flight)
        _ = try await journal.add(Self.photo(width: 600, height: 400), to: other)
        #expect(await journal.photos(for: flight).map(\.id) == [a.id, b.id])
        #expect(a.width == 2_048 && a.height == 1_365)
        let thumb = try #require(await journal.thumbnail(a.id, of: flight))
        #expect(Self.size(thumb).0 == JournalImage.thumbnailPixel)
        #expect(await journal.image(a.id, of: flight) != nil)

        await journal.remove(a.id, from: flight)
        #expect(await journal.photos(for: flight).map(\.id) == [b.id])
        #expect(await journal.image(a.id, of: flight) == nil)
        await journal.remove(b.id, from: flight)
        #expect(await journal.photos(for: flight).isEmpty)
        #expect(await journal.photos(for: other).count == 1)
    }

    @Test func memoryJournalWorksTheSame() async throws {
        let shelf = TravelJournalShelf.inMemory()
        let me = UUID(), flight = UUID()
        let p = try await shelf.journal(for: me).add(Self.photo(width: 100, height: 50), to: flight)
        #expect(await shelf.journal(for: me).photos(for: flight) == [p])
        #expect(await shelf.journal(for: UUID()).photos(for: flight).isEmpty)
        shelf.keepOnly(nil)
        #expect(await shelf.journal(for: me).photos(for: flight).isEmpty)
    }

    @Test func signingOutWipesEveryAccountsPhotos() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = try await AppEnvironment.fake()
        env.journal = TravelJournalShelf(directory: dir)
        let user = UUID(), flight = UUID()
        try await env.adopt(user: user)
        _ = try await env.journal.journal(for: user).add(Self.photo(width: 200, height: 200), to: flight)
        #expect(await env.journal.journal(for: user).photos(for: flight).count == 1)
        // The same account again keeps them.
        try await env.adopt(user: user)
        #expect(await env.journal.journal(for: user).photos(for: flight).count == 1)
        // Signing out (or deleting the account) hands the device to nobody: the photos go.
        try await env.adopt(user: nil)
        #expect(await env.journal.journal(for: user).photos(for: flight).isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
        #expect(left.isEmpty)
    }

    @MainActor @Test func deletingTheFlightDeletesItsPhotos() async throws {
        let journal = TravelJournalShelf.inMemory().journal(for: nil)
        let history = FakeHistoryService()
        let store = PassportStore(history: history, journal: journal)
        await store.load()
        let flight = try #require(store.allFlights.first)
        let keep = try #require(store.allFlights.dropFirst().first)
        _ = try await journal.add(Self.photo(width: 64, height: 64), to: flight.id)
        _ = try await journal.add(Self.photo(width: 64, height: 64), to: keep.id)
        #expect(await store.delete(flight.id))
        #expect(await journal.photos(for: flight.id).isEmpty)
        #expect(await journal.photos(for: keep.id).count == 1)
    }

    @Test func copy() {
        #expect(TravelJournalFacts.count(1) == "1 photo")
        #expect(TravelJournalFacts.count(3) == "3 photos")
        #expect(!TravelJournalFacts.empty.contains("\u{2014}"))
    }
}
