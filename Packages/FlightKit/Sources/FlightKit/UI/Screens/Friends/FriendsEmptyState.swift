import SwiftUI

/// The Friends tab with no friend yet, under the code row: our two jets climbing together, one line, one sentence and Invite
/// a Friend, the tab's one strong button, which opens the share sheet with the invitation link (made when it
/// is tapped, reused until it nears its end).
struct FriendsEmptyState: View {
    var store: FriendsStore
    /// A collapsed home sheet: the jets alone, as large as its few points allow and centred in them. The line, the
    /// sentence and Invite a Friend come in as the sheet rises, with the code row's spring.
    var compact = false
    @Environment(\.sheetContentRoom) private var room

    /// The jets picture's height over its width (900 x 483).
    private static let aspect: CGFloat = 483 / 900
    /// What a collapsed sheet shows under the title on a 6.3 inch iPhone, when the shell gives no room.
    private static let collapsedRoom: CGFloat = 130

    /// Collapsed, the jets as wide as the room's height allows (8 pt kept for their float), up to their
    /// full width.
    private var compactSize: CGFloat {
        min(240, ((room ?? Self.collapsedRoom) - 8) / Self.aspect).rounded(.down)
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                // Centred in what shows between the title and the tab pill.
                EmptyStateIllustration(variant: .pair, size: compactSize, verticalPadding: 0)
                    .frame(height: room ?? Self.collapsedRoom)
            } else {
                EmptyStateIllustration(variant: .pair, size: 240)
                    // Its full height even where the sheet is short: the rest is cut, never the jets squeezed.
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                details.transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .scaledPadding(.horizontal, 32)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: compact)
    }

    @ViewBuilder private var details: some View {
        VStack(spacing: 0) {
            Text(ui: FriendFacts.emptyTitle)
                .scaledFont(19, weight: .semibold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 18)
            Text(ui: FriendFacts.emptyText)
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
    }
}
