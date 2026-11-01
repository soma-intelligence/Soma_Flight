import Foundation
import ImageIO

/// What a brand image shows. The raw values are the backend's (`brand-asset?kind=`). Square slots (rows,
/// tails) ask for `.logo`, the symbol when the airline has one; `.wordmark` is the airline's name set wide.
public enum BrandAssetKind: String, Sendable, CaseIterable {
    case logo
    case logoDark = "logo_dark"
    case wordmark
    case tail
    case sideView = "side_view"
}

/// One brand image as stored on the device: the file's bytes, its format ("png", "webp") and the
/// backend's version for it.
public struct BrandAsset: Sendable, Hashable {
    public var data: Data
    public var format: String
    public var version: String

    public init(data: Data, format: String, version: String) {
        self.data = data; self.format = format; self.version = version
    }

    /// Formats the app accepts: rasters only. The backend never serves SVG (it rasterises at sync),
    /// and a vector that turns up anyway is refused rather than drawn.
    public static let rasterFormats: Set<String> = ["png", "webp", "jpeg", "jpg"]
    /// Larger images are refused before any decode.
    public static let maxPixelSide = 8192

    /// True when the bytes are a complete image the platform reads, in an accepted format, no larger than
    /// `maxPixelSide` on either side. Checks the header, then reads a 32 px thumbnail (never the full image).
    public var decodes: Bool { Self.decodes(data, format: format) }

    /// The file's own end marker is there: PNG's IEND chunk, JPEG's EOI, the RIFF length of a WebP.
    /// ImageIO draws a cut file's first rows without complaint, so this is what catches a short write.
    static func isWhole(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data.suffix(8) == Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        }
        if bytes.starts(with: [0xFF, 0xD8]) { return data.suffix(2) == Data([0xFF, 0xD9]) }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            return size + 8 == data.count
        }
        return false
    }

    static func decodes(_ data: Data, format: String) -> Bool {
        guard rasterFormats.contains(format.lowercased()), !data.isEmpty, isWhole(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        guard w > 0, h > 0, w <= maxPixelSide, h <= maxPixelSide else { return false }
        // A small thumbnail proves the pixel data reads to the end without holding the full image.
        let probe: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 32,
                                      kCGImageSourceShouldCache: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, probe as CFDictionary) != nil
    }
}

/// What a lookup found: the asset, a known absence (draw the app's own mark), or no answer this time
/// (offline, timed out: ask again later).
public enum BrandLookup: Sendable, Equatable {
    case found(BrandAsset)
    case missing
    case unavailable

    public var asset: BrandAsset? { if case .found(let a) = self { a } else { nil } }
}

/// Airline logos, tails and side views. Never throws: nil means "draw the app's own mark".
public protocol BrandAssetService: Sendable {
    /// - Parameters:
    ///   - icao: the airline's ICAO designator ("UAL").
    ///   - type: the aircraft ICAO type, for `.sideView` only (ignored for the other kinds).
    func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset?
    /// `asset`, telling a known absence from a failed request.
    func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup
}

public extension BrandAssetService {
    func asset(_ icao: String, _ kind: BrandAssetKind) async -> BrandAsset? {
        await asset(icao, kind, type: nil)
    }

    func lookup(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandLookup {
        await asset(icao, kind, type: type).map { .found($0) } ?? .missing
    }
}

/// Answers from a fixed set: nothing by default, seeded assets in tests, and `bundled()` for the
/// `-useFakes` runs: a few Commons logos (public domain) of the airlines in the fake history.
public struct FakeBrandAssetService: BrandAssetService {
    private let assets: [String: BrandAsset]

    public init() { assets = [:] }

    /// - Parameter seeded: (ICAO, kind, asset); a side view's key also takes its type.
    public init(seeded: [(icao: String, kind: BrandAssetKind, asset: BrandAsset)], type: String? = nil) {
        var all: [String: BrandAsset] = [:]
        for s in seeded { all[Self.key(s.icao, s.kind, s.kind == .sideView ? type : nil)] = s.asset }
        assets = all
    }

    public func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset? {
        assets[Self.key(icao, kind, kind == .sideView ? type : nil)]
    }

    static func key(_ icao: String, _ kind: BrandAssetKind, _ type: String?) -> String {
        let base = "\(icao.uppercased())/\(kind.rawValue)"
        return type.map { "\(base)-\($0.uppercased())" } ?? base
    }

    /// The airlines whose marks ship with the package for the fakes (Resources/Fakes/Logos): the fake
    /// history's and boards' airlines, plus three wide or tall shapes. Copied from assets/logos/commons
    /// (all public domain except the KLM crown, CC BY-SA 3.0, credited in Acknowledgements). The full
    /// library ships too, behind `BundledLogos`, which answers when this set has no mark.
    public static let bundledAirlines = ["AAL", "ACA", "AFR", "AMX", "ASA", "BAW", "DAL", "FFT", "JBU", "NKS",
                                         "SWA", "UAL", "DLH", "KLM", "UAE"]

    /// The bundled airlines whose `.logo` is a cropped or Commons symbol (192 px render); the others
    /// ship their wordmark as `.logo`, as the backend serves it when an airline has no symbol.
    public static let bundledSymbols: Set<String> = ["AAL", "ACA", "AFR", "DAL", "SWA", "DLH", "KLM"]

    /// The version the bundled marks carry (the symbol pass day). As on the backend, a `.logo` that is
    /// the wordmark file carries the wordmark's version and a symbol its own (`bundledSymbolVersion`).
    public static let bundledVersion = "commons-2026-10-29-symbols"
    public static let bundledSymbolVersion = "commons-2026-10-29-symbol"

    /// The bundled marks: `.logo` (symbol when the airline has one, else its wordmark) and `.wordmark`.
    public static func bundled() -> FakeBrandAssetService {
        func load(_ name: String) -> Data? {
            (Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Logos")
                ?? Bundle.module.url(forResource: name, withExtension: "png"))
                .flatMap { try? Data(contentsOf: $0) }
        }
        var seeded: [(icao: String, kind: BrandAssetKind, asset: BrandAsset)] = []
        for icao in bundledAirlines {
            guard let logo = load("logo-\(icao)") else { continue }
            let logoVersion = bundledSymbols.contains(icao) ? bundledSymbolVersion : bundledVersion
            seeded.append((icao, .logo, BrandAsset(data: logo, format: "png", version: logoVersion)))
            // Without a separate wordmark file the logo is the wordmark.
            let word = load("wordmark-\(icao)") ?? logo
            seeded.append((icao, .wordmark, BrandAsset(data: word, format: "png", version: bundledVersion)))
        }
        return FakeBrandAssetService(seeded: seeded)
    }
}
