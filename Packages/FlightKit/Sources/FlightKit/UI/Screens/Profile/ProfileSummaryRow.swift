import SwiftUI

/// Settings > Profile: the photo and the name friends see, opening the profile editor (the onboarding
/// screen in edit mode).
struct ProfileSummaryRow: View {
    var store: ProfileStore
    @State private var editing = false

    var body: some View {
        let name = store.displayName
        Button { editing = true } label: {
            HStack(spacing: 14) {
                UserAvatar(photo: store.photo, name: name, id: store.owner, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Add your name and photo" : name)
                        .scaledFont(17, weight: name.isEmpty ? .regular : .semibold)
                        .foregroundStyle(name.isEmpty ? Theme.accent : Theme.primary)
                        .lineLimit(1)
                    Text("Only friends you accept see this").scaledFont(13).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.isEmpty ? "Add your name and photo" : "Profile, \(name)")
        .accessibilityHint("Edit your name and photo")
        .sheet(isPresented: $editing) {
            ProfileOnboardingView(store: store, mode: .edit) { editing = false }
                .presentationBackground(Theme.background)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 560)
                #endif
        }
    }
}
