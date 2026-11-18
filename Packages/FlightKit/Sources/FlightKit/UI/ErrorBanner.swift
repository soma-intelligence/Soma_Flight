import SwiftUI

/// What the pill of an inline error does: try the same request again, or open sign-in (E3).
public enum ErrorBannerAction {
    /// "Retry" with an arrow: the request that failed, again.
    case retry(() -> Void)
    /// "Sign In": a session that expired cannot be retried, the user signs in again.
    case signIn(() -> Void)

    /// The action an error calls for: Sign In for `.unauthorized` when `signIn` is given, else Retry when
    /// `retry` is given, else none.
    public static func pick(for error: APIError, retry: (() -> Void)?, signIn: (() -> Void)?) -> ErrorBannerAction? {
        if error == .unauthorized, let signIn { return .signIn(signIn) }
        return retry.map(ErrorBannerAction.retry)
    }
}

/// Inline problem card (R6, R8): a flat white card with an amber warning symbol, the short copy and, when the
/// problem can be acted on, a 44 pt pill: "Retry", or "Sign In" for an expired session (E3). Pink stays for
/// the canceled state only (R7).
///
/// - `hasContent`: whether the screen still shows data under the banner. False drops the "Showing the last
///   update" promise from the copy (E8). Pass false on a search, an airport with no cache, an empty list.
public struct ErrorBanner: View {
    var error: APIError
    var hasContent: Bool
    var action: ErrorBannerAction?

    /// - Parameters:
    ///   - hasContent: the screen still shows the last data (true by default, the copy says so).
    ///   - retry: runs the failed request again.
    ///   - signIn: opens sign-in; shown instead of Retry when `error` is `.unauthorized`.
    public init(error: APIError, hasContent: Bool = true, retry: (() -> Void)? = nil, signIn: (() -> Void)? = nil) {
        self.error = error; self.hasContent = hasContent
        action = ErrorBannerAction.pick(for: error, retry: retry, signIn: signIn)
    }

    public var body: some View {
        RefinedCard(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.late)
                    .accessibilityHidden(true)
                Text(ui: error.message(hasContent: hasContent))
                    .scaledFont(15)
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let action { ErrorActionPill(action) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The flight sheet's refresh failure while the last known flight stays on screen (R8): "Couldn't refresh",
/// how old the data is, and a Retry pill (Sign In for an expired session).
/// Penpot: Card/Inline error
struct RefreshErrorCard: View {
    var error: APIError
    /// When the flight on screen was last updated.
    var updatedAt: Date
    var now: Date
    var retry: () -> Void
    var signIn: (() -> Void)? = nil

    /// "Last updated 4 min. ago", "Offline · last updated just now", in the user's language.
    static func subtitle(_ error: APIError, updatedAt: Date, now: Date) -> String {
        let age = Format.ago(updatedAt, now: now)
        return error == .offline ? String(localized: "Offline \u{00B7} last updated \(age)", bundle: .main)
            : String(localized: "Last updated \(age)", bundle: .main)
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
                if let action = ErrorBannerAction.pick(for: error, retry: retry, signIn: signIn) {
                    ErrorActionPill(action)
                }
            }
        }
    }
}

/// The 44 pt secondary pill of an inline error: "Retry" with an arrow, or "Sign In" with a person, in the
/// accent text colour. Both titles are catalog keys (A2).
public struct ErrorActionPill: View {
    var action: ErrorBannerAction
    @Environment(\.metricsScale) private var scale

    public init(_ action: ErrorBannerAction) { self.action = action }

    private var title: LocalizedStringKey {
        if case .signIn = action { return "Sign In" }
        return "Retry"
    }

    private var systemImage: String {
        if case .signIn = action { return "person.crop.circle" }
        return "arrow.clockwise"
    }

    private func run() {
        switch action {
        case .retry(let f), .signIn(let f): f()
        }
    }

    public var body: some View {
        Button(action: run) {
            Label(title, systemImage: systemImage)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.accentText)
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
            ErrorBanner(error: .unauthorized, retry: {}, signIn: {})
            ErrorBanner(error: .providerUnavailable, hasContent: false, retry: {})
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
