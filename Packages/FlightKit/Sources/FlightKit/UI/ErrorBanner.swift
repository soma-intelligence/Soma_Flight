import SwiftUI

/// Inline problem card (R6, R8): a flat white card with an amber warning symbol, the short copy and, when the
/// problem can be retried, a 44 pt "Retry" pill. Pink stays for the canceled state only (R7).
public struct ErrorBanner: View {
    var error: APIError
    var retry: (() -> Void)?

    public init(error: APIError, retry: (() -> Void)? = nil) {
        self.error = error; self.retry = retry
    }

    public var body: some View {
        RefinedCard(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.late)
                    .accessibilityHidden(true)
                Text(ui: error.message)
                    .scaledFont(15)
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let retry { RetryPill(action: retry) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The flight sheet's refresh failure while the last known flight stays on screen (R8): "Couldn't refresh",
/// how old the data is, and a Retry pill.
/// Penpot: Card/Inline error
struct RefreshErrorCard: View {
    var error: APIError
    /// When the flight on screen was last updated.
    var updatedAt: Date
    var now: Date
    var retry: () -> Void

    /// "Last updated 4 min ago", "Offline · last updated just now".
    static func subtitle(_ error: APIError, updatedAt: Date, now: Date) -> String {
        let age = HeroFacts.age(since: updatedAt, now: now)
        return error == .offline ? "Offline · last updated \(age)" : "Last updated \(age)"
    }

    var body: some View {
        RefinedCard(padding: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .scaledFont(18, weight: .semibold)
                    .foregroundStyle(Theme.late)
                    .scaledPadding(.leading, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ui: "Couldn't refresh")
                        .themeFont(.sectionTitle)
                        .foregroundStyle(Theme.primary)
                    Text(ui: Self.subtitle(error, updatedAt: updatedAt, now: now))
                        .themeFont(.sectionSubtitle)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(ui: error.message))
                RetryPill(action: retry)
            }
        }
    }
}

/// The 44 pt secondary pill of an inline error: an arrow and "Retry" in the accent colour.
struct RetryPill: View {
    var action: () -> Void
    @Environment(\.metricsScale) private var scale

    var body: some View {
        Button(action: action) {
            Label("Retry", systemImage: "arrow.clockwise")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.accent)
                .scaledPadding(.horizontal, 14)
                .frame(minHeight: Theme.metric(44, scale))
                .background(Capsule().fill(Theme.pill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
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

#Preview("Refresh error") {
    RefreshErrorCard(error: .providerUnavailable, updatedAt: .now.addingTimeInterval(-240), now: .now, retry: {})
        .padding()
        .background(Theme.background)
}
