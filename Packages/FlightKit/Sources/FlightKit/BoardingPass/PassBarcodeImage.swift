import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Draws a boarding pass barcode with Core Image's generators, sharp at any size: each module is a
/// whole number of pixels and the view scales it without smoothing.
public enum PassBarcodeImage {
    // CIContext is thread safe; one is enough for the app.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The barcode as black modules on white, `scale` pixels per module; nil when the generator refuses
    /// the message (a QR code over its capacity, Code 128 outside ASCII).
    public static func make(_ barcode: PassBarcode, scale: CGFloat = 4) -> CGImage? {
        let data = messageData(barcode)
        let output: CIImage?
        switch barcode.format {
        case .pdf417:
            let f = CIFilter.pdf417BarcodeGenerator()
            f.message = data
            // Taller rows than the default read better from a phone held under a gate scanner.
            f.preferredAspectRatio = 3
            f.compactionMode = 2
            output = f.outputImage
        case .aztec:
            let f = CIFilter.aztecCodeGenerator()
            f.message = data
            f.correctionLevel = 23
            output = f.outputImage
        case .qr:
            let f = CIFilter.qrCodeGenerator()
            f.message = data
            f.correctionLevel = "M"
            output = f.outputImage
        case .code128:
            let f = CIFilter.code128BarcodeGenerator()
            f.message = data
            f.quietSpace = 0
            output = f.outputImage
        }
        guard let image = output else { return nil }
        let scaled = image.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale.rounded(), y: scale.rounded()))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// The message's bytes in the pass's own encoding (Wallet's default is ISO 8859-1, which BCBP
    /// strings fit).
    static func messageData(_ barcode: PassBarcode) -> Data {
        let encoding: String.Encoding = switch barcode.encoding?.lowercased() {
        case "utf-8", "utf8": .utf8
        default: .isoLatin1
        }
        return barcode.message.data(using: encoding) ?? Data(barcode.message.utf8)
    }
}

/// Finds a boarding pass barcode in a photo or screenshot with Vision.
public enum PassBarcodeReader {
    public enum ReadError: Error, Equatable, Sendable {
        /// No PDF417, Aztec or QR code in the picture.
        case noBarcode
        /// Codes, but none holds a boarding pass.
        case notBoardingPass
    }

    /// The boarding pass in an image file's bytes (PNG, JPEG, HEIC).
    public static func read(imageData: Data, near: Date = .now) async throws -> BoardingPass {
        let codes = try await barcodes(in: imageData)
        return try pass(from: codes, near: near)
    }

    /// The first code that reads as BCBP, as a scanned pass. Pure: the scanner and the photo path share it.
    public static func pass(from codes: [(payload: String, format: PassBarcode.Format)], near: Date = .now) throws(ReadError) -> BoardingPass {
        guard !codes.isEmpty else { throw .noBarcode }
        for code in codes {
            if let bcbp = try? BCBP.parse(code.payload) {
                return BoardingPass(bcbp: bcbp, barcode: PassBarcode(message: code.payload, format: code.format), near: near)
            }
        }
        throw .notBoardingPass
    }

    static func barcodes(in imageData: Data) async throws -> [(payload: String, format: PassBarcode.Format)] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.pdf417, .aztec, .qr]
        let found = try await request.perform(on: imageData)
        return found.compactMap { o in
            guard let payload = o.payloadString, !payload.isEmpty else { return nil }
            let format: PassBarcode.Format = switch o.symbology {
            case .pdf417, .microPDF417: .pdf417
            case .aztec: .aztec
            default: .qr
            }
            return (payload, format)
        }
    }
}
