import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A drawn stand-in for a profile photo (screenshot runs and previews): a soft two-tone gradient with a
/// head-and-shoulders shape, so no real face is ever bundled. `hue` picks the colour.
public enum FakeProfilePhoto {
    public static func jpeg(hue: Double, side: Int = 512) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let s = CGFloat(side)
        let top = color(hue: hue, saturation: 0.55, brightness: 0.85)
        let bottom = color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        }
        let figure = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82)
        ctx.setFillColor(figure)
        // Shoulders (CoreGraphics' origin is the bottom left) and head.
        ctx.fillEllipse(in: CGRect(x: s * 0.16, y: -s * 0.30, width: s * 0.68, height: s * 0.62))
        ctx.fillEllipse(in: CGRect(x: s * 0.33, y: s * 0.38, width: s * 0.34, height: s * 0.36))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        // HSB to RGB without a UI framework.
        let h = hue * 6, i = floor(h), f = h - i
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f), t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch Int(i) % 6 {
        case 0: (r, g, b) = (brightness, t, p)
        case 1: (r, g, b) = (q, brightness, p)
        case 2: (r, g, b) = (p, brightness, t)
        case 3: (r, g, b) = (p, q, brightness)
        case 4: (r, g, b) = (t, p, brightness)
        default: (r, g, b) = (brightness, p, q)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
