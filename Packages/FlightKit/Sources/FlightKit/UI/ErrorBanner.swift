import SwiftUI

/// Inline problem banner, styled like the airport issues card: maroon fill, red beacon, short copy.
public struct ErrorBanner: View {
    var error: APIError
    var retry: (() -> Void)?

    public init(error: APIError, retry: (() -> Void)? = nil) {
        self.error = error; self.retry = retry
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(Theme.veryLate.opacity(0.22)).frame(width: 20, height: 20)
                Circle().fill(Theme.veryLate).frame(width: 9, height: 9)
            }
            Text(ui: error.message)
                .scaledFont(15)
                .foregroundStyle(Theme.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Try again", action: retry)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .buttonStyle(.plain)
                    .scaledPadding(.horizontal, 12)
                    .scaledPadding(.vertical, 6)
                    .background(Capsule().fill(Theme.primary.opacity(0.12)))
            }
        }
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.issues))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.issuesRim, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 10) {
            ErrorBanner(error: .providerUnavailable, retry: {})
            ErrorBanner(error: .notFound)
            ErrorBanner(error: .rateLimited)
            ErrorBanner(error: .planLimit)
            ErrorBanner(error: .unauthorized, retry: {})
            ErrorBanner(error: .offline, retry: {})
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
