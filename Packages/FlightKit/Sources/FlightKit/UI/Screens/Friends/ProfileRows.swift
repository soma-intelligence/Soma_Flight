import SwiftUI

/// Settings > Profile: the name and the optional emoji friends see, saved when a field is submitted or left.
/// Only friends ever see them.
struct ProfileRows: View {
    var store: FriendsStore
    @State private var name = ""
    @State private var emoji = ""
    @State private var loaded = false
    @State private var saved = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, emoji }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                FriendAvatar(name: name.isEmpty ? nil : name, emoji: FriendsStore.cleanEmoji(emoji), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Your name", text: $name)
                        .scaledFont(17)
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Text("Shown to friends only").scaledFont(13).foregroundStyle(Theme.secondary)
                }
                TextField("🙂", text: $emoji)
                    .scaledFont(24)
                    .multilineTextAlignment(.center)
                    .frame(width: 48)
                    .focused($focus, equals: .emoji)
                    .onSubmit(save)
                    .onChange(of: emoji) { _, new in
                        // One emoji at most; anything else is dropped as it is typed.
                        let clean = FriendsStore.cleanEmoji(new) ?? ""
                        if clean != new { emoji = clean }
                    }
                    .accessibilityLabel("Emoji")
            }
            .scaledPadding(.horizontal, 16)
            .frame(minHeight: 72)
            if saved {
                Text("Saved").scaledFont(13).foregroundStyle(Theme.onTime)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaledPadding(.leading, 74).scaledPadding(.bottom, 8)
            }
        }
        .onChange(of: focus) { old, new in if old != nil, new == nil { save() } }
        .task {
            if store.me == nil { await store.load() }
            guard !loaded, let me = store.me else { return }
            name = me.displayName ?? ""
            emoji = me.emoji ?? ""
            loaded = true
        }
    }

    private func save() {
        let n = FriendsStore.clean(name, max: 40), e = FriendsStore.cleanEmoji(emoji)
        guard n != store.me?.displayName || e != store.me?.emoji else { return }
        Task {
            saved = await store.saveProfile(displayName: n, emoji: e)
            if saved {
                try? await Task.sleep(for: .seconds(2))
                saved = false
            }
        }
    }
}
