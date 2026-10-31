import SwiftUI

/// The calm banner the home shows with no connection: grey, not the red of an error, since nothing is
/// wrong with the saved data. "No connection: showing your saved flights."
public struct OfflineBanner: View {
    var text: String
    var retry: (() -> Void)?

    public init(_ text: String = OfflineBanner.homeText, retry: (() -> Void)? = nil) {
        self.text = text; self.retry = retry
    }

    public static let homeText = "No connection: showing your saved flights"

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wifi.slash")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(text)
                .scaledFont(15)
                .foregroundStyle(Theme.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Try again", action: retry)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .buttonStyle(.plain)
                    .scaledPadding(.horizontal, 12)
                    .scaledPadding(.vertical, 6)
                    .background(Capsule().fill(Theme.primary.opacity(0.1)))
            }
        }
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 10) {
        OfflineBanner(retry: {})
        OfflineBanner()
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
