import SwiftUI

/// The Friends tab with no friend yet, under the code row: our two jets climbing together, one line, one sentence and Invite
/// a Friend, the tab's one strong button, which opens the share sheet with the invitation link (made when it
/// is tapped, reused until it nears its end).
struct FriendsEmptyState: View {
    var store: FriendsStore
    /// A collapsed home sheet: the jets come smaller so the whole pair fits its few points (they grow
    /// back as the sheet rises, with the code row's spring).
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            EmptyStateIllustration(variant: .pair, size: compact ? 176 : 240)
                // Its full height even where the sheet is short: the rest is cut, never the jets squeezed.
                .fixedSize(horizontal: false, vertical: true)
            Text(FriendFacts.emptyTitle)
                .scaledFont(19, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 18)
            Text(FriendFacts.emptyText)
                .scaledFont(14)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 4)
            InviteShareButton(store: store) {
                Label("Invite a Friend", systemImage: "paperplane.fill")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaledPadding(.horizontal, 20)
                    .scaledPadding(.vertical, 11)
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .scaledPadding(.top, 18)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .scaledPadding(.horizontal, 32)
    }
}
