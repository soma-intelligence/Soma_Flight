import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns any picture the user picks (HEIC, JPEG, PNG, a Google photo) into the profile photo the app
/// uploads: a centred square, `side` pixels, upright, re-encoded as JPEG with no metadata at all (no EXIF,
/// GPS, camera or date), so nothing but the pixels leaves the device.
public enum AvatarImage {
    public static let side = 512
    public static let quality = 0.82

    /// The JPEG to upload, or nil when `data` is not a picture.
    public static func jpeg(from data: Data, side: Int = side) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Decode at about the size needed, with the EXIF orientation applied (the thumbnail API does both).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 3,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let square = squared(decoded, side: side) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Only the compression is set: no property dictionary means no metadata is written.
        CGImageDestinationAddImage(dest, square, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The centred square of `image`, drawn into a fresh sRGB bitmap of `side` x `side` (opaque: JPEG has no
    /// alpha, so transparent pixels become black rather than undefined).
    static func squared(_ image: CGImage, side: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let crop = min(w, h)
        let rect = CGRect(x: (w - crop) / 2, y: (h - crop) / 2, width: crop, height: crop)
        guard let cropped = image.cropping(to: rect),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
