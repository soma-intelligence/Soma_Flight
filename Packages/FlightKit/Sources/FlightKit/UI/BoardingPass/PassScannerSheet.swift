#if os(iOS)
import SwiftUI
import VisionKit

/// The camera scanner for a boarding pass barcode (PDF417, Aztec or QR), on paper or another screen.
/// Hands over the first code that reads as a boarding pass; others leave a line saying so and scanning
/// goes on. Devices without the live scanner (or with the camera refused) say what to do instead.
struct PassScannerSheet: View {
    var onPass: (BoardingPass) -> Void
    @State private var hint: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerView(onCode: handle)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text(hint ?? "Point the camera at the barcode on the boarding pass")
                                .scaledFont(15, weight: .medium)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .scaledPadding(.horizontal, 16)
                                .scaledPadding(.vertical, 10)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .scaledPadding(.bottom, 32)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                } else {
                    ContentUnavailableView {
                        Label("Camera Not Available", systemImage: "camera")
                    } description: {
                        Text(DataScannerViewController.isSupported
                             ? "Allow Soma Flight to use the camera in Settings, or choose a screenshot of the pass instead."
                             : "This device cannot scan barcodes with its camera. Choose a screenshot of the pass instead.")
                    }
                }
            }
            .navigationTitle("Scan Boarding Pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func handle(_ payload: String, _ format: PassBarcode.Format) -> Bool {
        do {
            onPass(try PassBarcodeReader.pass(from: [(payload, format)]))
            return true
        } catch {
            hint = BoardingPassFacts.notBoardingPass
            return false
        }
    }
}

/// VisionKit's live scanner, barcodes only.
private struct ScannerView: UIViewControllerRepresentable {
    /// True when the code was taken: scanning stops.
    var onCode: (String, PassBarcode.Format) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.pdf417, .aztec, .qr])],
            qualityLevel: .accurate, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning, !context.coordinator.done { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String, PassBarcode.Format) -> Bool
        var done = false
        /// Codes already refused, so one that is not a pass is not reported again every frame.
        private var refused: Set<String> = []

        init(onCode: @escaping (String, PassBarcode.Format) -> Bool) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            take(added, scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            take([item], scanner)
        }

        private func take(_ items: [RecognizedItem], _ scanner: DataScannerViewController) {
            guard !done else { return }
            for item in items {
                guard case .barcode(let code) = item, let payload = code.payloadStringValue,
                      !refused.contains(payload) else { continue }
                let format: PassBarcode.Format = switch code.observation.symbology {
                case .pdf417, .microPDF417: .pdf417
                case .aztec: .aztec
                default: .qr
                }
                if onCode(payload, format) {
                    done = true
                    scanner.stopScanning()
                    return
                }
                refused.insert(payload)
            }
        }
    }
}
#endif
