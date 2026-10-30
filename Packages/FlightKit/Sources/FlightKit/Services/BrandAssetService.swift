import Foundation
import ImageIO

/// What a brand image shows. The raw values are the backend's (`brand-asset?kind=`).
public enum BrandAssetKind: String, Sendable, CaseIterable {
    case logo
    case logoDark = "logo_dark"
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

    /// True when the bytes are an image the platform decodes, in an accepted format.
    public var decodes: Bool { Self.decodes(data, format: format) }

    static func decodes(_ data: Data, format: String) -> Bool {
        guard rasterFormats.contains(format.lowercased()), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

/// Airline logos, tails and side views. Never throws: nil means "draw the app's own mark".
public protocol BrandAssetService: Sendable {
    /// - Parameters:
    ///   - icao: the airline's ICAO designator ("UAL").
    ///   - type: the aircraft ICAO type, for `.sideView` only (ignored for the other kinds).
    func asset(_ icao: String, _ kind: BrandAssetKind, type: String?) async -> BrandAsset?
}

public extension BrandAssetService {
    func asset(_ icao: String, _ kind: BrandAssetKind) async -> BrandAsset? {
        await asset(icao, kind, type: nil)
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

    /// The airlines whose logo ships with the package for the fakes (Resources/Fakes/Logos): the fake
    /// history's and boards' airlines, plus three wide or tall shapes. Copied from
    /// assets/logos/commons/png, all public domain; the full library never ships in the app.
    public static let bundledAirlines = ["AAL", "ACA", "AFR", "AMX", "ASA", "BAW", "DAL", "FFT", "JBU", "NKS",
                                         "SWA", "UAL", "DLH", "KLM", "UAE"]

    /// The version the bundled logos carry (the Commons fetch day).
    public static let bundledVersion = "commons-2026-10-29"

    /// The bundled logos as `.logo` assets.
    public static func bundled() -> FakeBrandAssetService {
        let seeded: [(icao: String, kind: BrandAssetKind, asset: BrandAsset)] = bundledAirlines.compactMap { icao in
            guard let url = Bundle.module.url(forResource: "logo-\(icao)", withExtension: "png", subdirectory: "Logos")
                    ?? Bundle.module.url(forResource: "logo-\(icao)", withExtension: "png"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (icao, .logo, BrandAsset(data: data, format: "png", version: bundledVersion))
        }
        return FakeBrandAssetService(seeded: seeded)
    }
}
