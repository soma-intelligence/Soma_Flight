import SwiftUI

/// "Updated 2 min ago" capsule. Turns amber once the data is older than `ttl`.
public struct StaleBadge: View {
    var fetchedAt: Date
    var ttl: Duration
    var now: Date

    public init(fetchedAt: Date, ttl: Duration, now: Date = .now) {
        self.fetchedAt = fetchedAt; self.ttl = ttl; self.now = now
    }

    var isStale: Bool { now.timeIntervalSince(fetchedAt) > Double(ttl.components.seconds) }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isStale ? "exclamationmark.arrow.trianglehead.counterclockwise" : "clock")
                .scaledFont(11, weight: .semibold)
            Text(isStale ? "Last update \(Format.ago(fetchedAt, now: now))" : "Updated \(Format.ago(fetchedAt, now: now))")
                .scaledFont(12, weight: .medium)
        }
        .foregroundStyle(isStale ? Theme.late : Theme.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(isStale ? Theme.late.opacity(0.14) : Theme.card))
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: isStale ? 0 : 0.5))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 12) {
        StaleBadge(fetchedAt: .now.addingTimeInterval(-120), ttl: .seconds(600))
        StaleBadge(fetchedAt: .now.addingTimeInterval(-3 * 3600), ttl: .seconds(600))
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
