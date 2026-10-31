import Compression
import Foundation

/// Just enough of a zip reader for a Wallet pass file: a `.pkpass` is a zip archive holding `pass.json`,
/// its images, a manifest and a signature. Reads the central directory and inflates stored or deflated
/// entries; no zip64, no encryption, no spanning (a pass file never needs them).
struct ZipArchive: Sendable {
    enum ReadError: Error, Equatable, Sendable {
        case notZip
        case damaged
        case unsupported
        /// An entry larger than `maxEntrySize`: no pass carries one.
        case tooLarge
    }

    /// One file of the archive, by its path inside it ("pass.json", "en.lproj/pass.strings").
    struct Entry: Sendable {
        var path: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    /// No entry of a boarding pass comes close: images stay under a few hundred kilobytes.
    static let maxEntrySize = 8 * 1024 * 1024

    let data: Data
    let entries: [Entry]

    init(_ data: Data) throws(ReadError) {
        self.data = data
        entries = try Self.centralDirectory(Array(data))
    }

    /// The entry at `path`, inflated; nil when the archive has none.
    func file(_ path: String) throws(ReadError) -> Data? {
        guard let entry = entries.first(where: { $0.path == path }) else { return nil }
        return try contents(entry)
    }

    /// The paths of every entry.
    var paths: [String] { entries.map(\.path) }

    private func contents(_ e: Entry) throws(ReadError) -> Data {
        guard e.size <= Self.maxEntrySize, e.compressedSize <= Self.maxEntrySize else { throw .tooLarge }
        let bytes = [UInt8](data)
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4b50 else { throw .damaged }
        let start = h + 30 + Int(Self.u16(bytes, h + 26)) + Int(Self.u16(bytes, h + 28))
        guard start + e.compressedSize <= bytes.count else { throw .damaged }
        let raw = Array(bytes[start..<start + e.compressedSize])
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            if e.size == 0 { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip stores.
            let written = raw.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw .damaged }
            return Data(out)
        default:
            throw .unsupported
        }
    }

    private static func centralDirectory(_ b: [UInt8]) throws(ReadError) -> [Entry] {
        guard b.count >= 22 else { throw .notZip }
        // The end of central directory record sits in the last 22 bytes plus at most a 64 KB comment.
        let lowest = max(0, b.count - 22 - 65_535)
        var eocd: Int?
        var i = b.count - 22
        while i >= lowest {
            if u32(b, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let end = eocd else { throw .notZip }
        let count = Int(u16(b, end + 10))
        let offset = Int(u32(b, end + 16))
        guard offset != 0xFFFF_FFFF else { throw .unsupported }
        var entries: [Entry] = []
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4b50 else { throw .damaged }
            let flags = u16(b, p + 8)
            guard flags & 0x1 == 0 else { throw .unsupported } // encrypted
            let nameLength = Int(u16(b, p + 28))
            let extraLength = Int(u16(b, p + 30))
            let commentLength = Int(u16(b, p + 32))
            guard p + 46 + nameLength <= b.count else { throw .damaged }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(path: name, method: u16(b, p + 10), compressedSize: Int(u32(b, p + 20)),
                                 size: Int(u32(b, p + 24)), localHeaderOffset: Int(u32(b, p + 42))))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
