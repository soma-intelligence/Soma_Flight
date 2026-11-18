import SwiftUI

/// How fresh the data on screen is (E9, D4): "Updated 4 min. ago", then "Last update 3 hr. ago" in the late
/// text colour once the data is older than `ttl`. The relative time is `Date.AnchoredRelativeFormatStyle` in
/// the app's language ("Mis à jour il y a 4 min"), and it ticks on its own every 30 s unless `now` is given.
///
/// - Styles: `.line` (default) is a plain caption under a section or at the foot of a sheet; `.badge` is
///   the capsule for a header.
/// - `source`: names where the data comes from ("FlightAware"), appended after a middle dot.
/// - `hidesWhileFresh`: shows nothing until the TTL has passed, for screens where a fresh stamp is noise.
/// - VoiceOver reads it as one element.
/// Penpot: Freshness line
public struct StaleBadge: View {
    public enum Style: Sendable { case line, badge }

    var fetchedAt: Date
    var ttl: Duration
    var now: Date?
    var style: Style
    var source: String?
    var hidesWhileFresh: Bool

    /// - Parameters:
    ///   - now: a fixed clock (tests, previews); nil follows the real time.
    public init(fetchedAt: Date, ttl: Duration, now: Date? = nil, style: Style = .line, source: String? = nil,
                hidesWhileFresh: Bool = false) {
        self.fetchedAt = fetchedAt; self.ttl = ttl; self.now = now; self.style = style
        self.source = source; self.hidesWhileFresh = hidesWhileFresh
    }

    /// Older than `ttl` at `now`.
    static func isStale(fetchedAt: Date, ttl: Duration, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > Double(ttl.components.seconds)
    }

    /// The words: "Updated 4 min. ago · FlightAware", "Last update 3 hr. ago".
    static func text(fetchedAt: Date, ttl: Duration, now: Date, source: String?) -> String {
        let line = Format.updated(fetchedAt, now: now, stale: isStale(fetchedAt: fetchedAt, ttl: ttl, now: now))
        guard let source, !source.isEmpty else { return line }
        return line + FlightStatusSummary.separator + UIText.localized(source)
    }

    public var body: some View {
        if let now {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(context.date)
            }
        }
    }

    @ViewBuilder private func content(_ now: Date) -> some View {
        let stale = Self.isStale(fetchedAt: fetchedAt, ttl: ttl, now: now)
        if !(hidesWhileFresh && !stale) {
            let label = HStack(spacing: 5) {
                Image(systemName: stale ? "exclamationmark.arrow.trianglehead.counterclockwise" : "clock")
                    .scaledFont(11, weight: .semibold)
                    .accessibilityHidden(true)
                Text(verbatim: Self.text(fetchedAt: fetchedAt, ttl: ttl, now: now, source: source))
                    .scaledFont(12, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(stale ? Theme.lateText : Theme.secondary)
            .accessibilityElement(children: .combine)

            switch style {
            case .line:
                label
            case .badge:
                label
                    .scaledPadding(.horizontal, 9)
                    .scaledPadding(.vertical, 4)
                    .background(Capsule().fill(stale ? Theme.late.opacity(0.14) : Theme.card))
                    .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: stale ? 0 : 0.5))
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        StaleBadge(fetchedAt: .now.addingTimeInterval(-120), ttl: .seconds(600))
        StaleBadge(fetchedAt: .now.addingTimeInterval(-3 * 3600), ttl: .seconds(600), source: "FlightAware")
        StaleBadge(fetchedAt: .now.addingTimeInterval(-120), ttl: .seconds(600), style: .badge)
        StaleBadge(fetchedAt: .now.addingTimeInterval(-3 * 3600), ttl: .seconds(600), style: .badge)
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
