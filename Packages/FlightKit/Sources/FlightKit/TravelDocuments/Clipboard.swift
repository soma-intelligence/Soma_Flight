import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

/// Copies a travel document number. A hidden number (passport, Known Traveler, Redress) stays on this
/// device only (no Universal Clipboard) and leaves the iPhone's clipboard after `sensitiveLifetime`.
@MainActor
enum Clipboard {
    static let sensitiveLifetime: TimeInterval = 120

    static func copy(_ text: String, sensitive: Bool) {
        #if os(iOS)
        if sensitive {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                          options: [.localOnly: true,
                                                    .expirationDate: Date.now.addingTimeInterval(sensitiveLifetime)])
        } else {
            UIPasteboard.general.string = text
        }
        #elseif os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if sensitive {
            // The Mac's clipboard has no expiry: clear it later if it still holds this number.
            let count = board.changeCount
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(sensitiveLifetime))
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
        }
        #endif
    }
}
