import SwiftUI

/// The calm banner the home shows with no connection: grey, not the red of an error, since nothing is
/// wrong with the saved data. "No connection: showing your saved flights."
public struct OfflineBanner: View {
    var text: String
    var retry: (() -> Void)?
    @Environment(\.metricsScale) private var scale

    public init(_ text: String = OfflineBanner.homeText, retry: (() -> Void)? = nil) {
        self.text = text; self.retry = retry
    }

    public static let homeText = "No connection: showing your saved flights"
    /// The home offline with nothing saved on this device (E8): no promise of saved flights.
    public static let emptyText = "No connection. Your flights show here once you're back online."

    /// The home's copy for what is on screen: `homeText` with saved flights, `emptyText` without.
    public static func text(hasContent: Bool) -> String { hasContent ? homeText : emptyText }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wifi.slash")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            Text(ui: text)
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
                    .minTapTarget()
            }
        }
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 12)
        // The card radius, so it stacks with an `ErrorBanner` without two corner shapes (D8).
        .background(RoundedRectangle(cornerRadius: Theme.metric(Theme.Radius.card, scale), style: .continuous)
            .fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.metric(Theme.Radius.card, scale), style: .continuous)
            .strokeBorder(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

public extension OfflineBanner {
    /// The home's offline state while saved flights show (R8): the small glass pill "Offline · positions
    /// estimated" under the header, in place of the banner. A tap tries again, as the banner's button did.
    /// Penpot: Status pill
    struct Pill: View {
        var retry: (() -> Void)?
        /// When the list on show was saved; the pill then says how old it is (E2).
        var fetchedAt: Date?
        var now: Date?

        /// - Parameters:
        ///   - fetchedAt: when the saved list was last confirmed; nil keeps "positions estimated".
        ///   - now: a fixed clock (previews, tests); nil follows the real time.
        public init(retry: (() -> Void)? = nil, fetchedAt: Date? = nil, now: Date? = nil) {
            self.retry = retry; self.fetchedAt = fetchedAt; self.now = now
        }

        public static let text = "Offline \u{00B7} positions estimated"

        /// "Offline · last updated 4 min. ago" in the user's language, or `text` with no save time.
        public static func text(fetchedAt: Date?, now: Date) -> String {
            guard let fetchedAt else { return UIText.localized(text) }
            let age = Format.ago(fetchedAt, now: now)
            return String(localized: "Offline \u{00B7} last updated \(age)", bundle: .main)
        }

        public var body: some View {
            if let retry {
                Button(action: retry) { pill }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                    .accessibilityHint(Text(ui: "Tries to connect again"))
            } else {
                pill
            }
        }

        @ViewBuilder private var pill: some View {
            if fetchedAt == nil {
                StatusPill(Self.text, systemImage: "wifi.slash")
            } else if let now {
                agedPill(now)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { agedPill($0.date) }
            }
        }

        /// The pill with the list's age. It wraps at large text sizes rather than cut the age off (A12).
        private func agedPill(_ now: Date) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .accessibilityHidden(true)
                Text(verbatim: Self.text(fetchedAt: fetchedAt, now: now))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scaledFont(13, weight: .semibold)
            .foregroundStyle(Theme.secondary)
            .scaledPadding(.horizontal, 14)
            .scaledPadding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview {
    VStack(spacing: 10) {
        OfflineBanner(retry: {})
        OfflineBanner()
        OfflineBanner(OfflineBanner.text(hasContent: false), retry: {})
        OfflineBanner.Pill(retry: {})
        OfflineBanner.Pill(retry: {}, fetchedAt: .now.addingTimeInterval(-25 * 60))
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
