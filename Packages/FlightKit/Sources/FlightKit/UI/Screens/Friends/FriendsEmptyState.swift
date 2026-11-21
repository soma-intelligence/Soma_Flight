import SwiftUI

/// The Friends tab with no friend yet (R8, refined 2026-11-17): our two jets climbing together, one line, one
/// sentence, then the invite card showing the user's code (copy, QR, share), Invite a Friend, the tab's one
/// strong button, which opens the share sheet with the invitation link (made when it is tapped, reused until it
/// nears its end), and a quiet Add a Friend that opens the add sheet to type a friend's code.
struct FriendsEmptyState: View {
    var store: FriendsStore
    /// A collapsed home sheet: our two jets alone, as large as its few points allow and centred in them. The
    /// rest comes in as the sheet rises, with the code card's spring.
    var compact = false
    /// Opens the QR sheet from the code card.
    var onShowQR: () -> Void = {}
    /// Opens Add a Friend (type a friend's code); nil leaves the link out.
    var onAdd: (() -> Void)?
    @Environment(\.sheetContentRoom) private var room
    @Environment(\.metricsScale) private var scale

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
                details.transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: compact)
    }

    private var details: some View {
        VStack(spacing: 0) {
            EmptyStateIllustration(variant: .pair, size: 240)
                // Its full height even where the sheet is short: the rest is cut, never the jets squeezed.
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 16)
            Text(ui: FriendFacts.emptyTitle)
                .themeFont(.sheetTitle)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 18)
            Text(ui: FriendFacts.emptyText)
                .themeFont(.label)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 6)
                .scaledPadding(.horizontal, 30)
            if store.me != nil {
                FriendCodeRow(store: store, onShowQR: onShowQR, onAdd: onAdd)
                    .scaledPadding(.top, 28)
            }
            InviteShareButton(store: store) {
                Label("Invite a Friend", systemImage: "person.badge.plus")
                    .themeFont(.sectionTitle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.metric(50, scale))
                    .background(Capsule().fill(Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .scaledPadding(.top, 24)
            if let onAdd {
                Button(action: onAdd) {
                    Text("Add a Friend")
                        .themeFont(.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 200, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .scaledPadding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
    }
}
