import SwiftUI

/// The Friends tab with no friend yet: a small drawing, one line, one sentence and Invite a Friend, which
/// opens the share sheet with the invitation link (made when it is tapped, reused until it nears its end).
struct FriendsEmptyState: View {
    var store: FriendsStore

    var body: some View {
        VStack(spacing: 0) {
            FriendsIllustration()
                .scaledPadding(.top, 24)
            Text(FriendFacts.emptyTitle)
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 22)
            Text(FriendFacts.emptyText)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 6)
            InviteShareButton(store: store) {
                Label("Invite a Friend", systemImage: "paperplane.fill")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaledPadding(.horizontal, 26)
                    .scaledPadding(.vertical, 14)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .scaledPadding(.top, 24)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .scaledPadding(.horizontal, 24)
        .scaledPadding(.bottom, 8)
    }
}

/// Two friends, one on each side, joined by a dashed flight arc (the globe's friend route) with a small
/// plane at its top: drawn in SwiftUI, in the accent and friends colours.
struct FriendsIllustration: View {
    @Environment(\.metricsScale) private var scale

    var body: some View {
        let w = Theme.metric(232, scale), h = Theme.metric(112, scale), r = Theme.metric(30, scale)
        let left = CGPoint(x: r + 2, y: h - r - 2), right = CGPoint(x: w - r - 2, y: h - r - 2)
        // The arc leaves each circle near its top and peaks over the middle.
        let start = CGPoint(x: left.x + r * 0.7, y: left.y - r * 0.8)
        let end = CGPoint(x: right.x - r * 0.7, y: right.y - r * 0.8)
        let control = CGPoint(x: w / 2, y: -h * 0.18)
        // A quadratic curve's middle point, where its tangent is level: the plane flies left to right there.
        let top = CGPoint(x: (start.x + 2 * control.x + end.x) / 4, y: (start.y + 2 * control.y + end.y) / 4)
        ZStack {
            Path { p in
                p.move(to: start)
                p.addQuadCurve(to: end, control: control)
            }
            .stroke(Theme.friend.opacity(0.85),
                    style: StrokeStyle(lineWidth: Theme.metric(2.5, scale), lineCap: .round, dash: [6, 6]))
            Image(systemName: "airplane")
                .font(.system(size: Theme.metric(17, scale), weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(Theme.metric(7, scale))
                .background(Circle().fill(Theme.background))
                .position(top)
            avatar(Theme.accent, at: left, radius: r)
            avatar(Theme.friend, at: right, radius: r)
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }

    private func avatar(_ tone: Color, at point: CGPoint, radius r: CGFloat) -> some View {
        ZStack {
            Circle().fill(tone.opacity(0.18))
            Circle().strokeBorder(tone.opacity(0.45), lineWidth: Theme.metric(1.5, scale))
            Image(systemName: "person.fill")
                .font(.system(size: r * 0.9, weight: .medium))
                .foregroundStyle(tone)
        }
        .frame(width: r * 2, height: r * 2)
        .position(point)
    }
}
