import SwiftUI

/// The Friends tab: the title with Add Friend and a menu (pause sharing, a new code), filters (all friends,
/// flying soon) and a chip per friend, requests waiting for an answer, then one row per friend with their
/// next flight in its status colour. A friend's row opens their page; their flights draw on the globe in the
/// friends colour while this tab is open (the shell's `HomeModel.globe`).
///
/// The shell owns loading (`HomeModel.load()`); the view reloads on pull to refresh and the banner's retry.
public struct FriendsView: View {
    var store: FriendsStore
    var onOpenFriend: (UUID) -> Void
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    @State private var adding = false

    /// - Parameters:
    ///   - onOpenFriend: opens a friend's page.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: FriendsStore, onOpenFriend: @escaping (UUID) -> Void,
                lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil) {
        self.store = store; self.onOpenFriend = onOpenFriend; self.lookup = lookup; self.fixedNow = now
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                header
                    .scaledPadding(.leading, Theme.gutter)
                    .scaledPadding(.top, 19)
                    .scaledPadding(.bottom, 8)
                if !store.friends.isEmpty { chips }
                ScreenScroll(scrolls: true, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $adding) {
            AddFriendSheet(store: store) { adding = false }
                #if os(macOS)
                .frame(width: 420, height: 600)
                #endif
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Friends")
                .scaledFont(32, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Menu {
                if let me = store.me {
                    Toggle("Pause All Sharing", systemImage: "pause.circle",
                           isOn: Binding(get: { me.sharingPaused }, set: { v in Task { await store.setPaused(v) } }))
                    Button("New Friend Code", systemImage: "arrow.triangle.2.circlepath") { Task { await store.resetCode() } }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.load() } }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(18, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(RoundButton.fill))
                    .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("More")
            RoundButton(systemImage: "person.badge.plus", label: "Add Friend") { adding = true }
        }
        // The shell's Settings gear sits in the last 60 points.
        .scaledPadding(.trailing, 68)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(FriendsStore.Filter.allCases, id: \.self) { f in
                    FriendChip(title: f.title, selected: store.filter == f, action: { store.filter = f }) { EmptyView() }
                }
                ForEach(store.friends) { friend in
                    FriendChip(title: friend.name.split(separator: " ").first.map(String.init) ?? friend.name,
                               selected: false, action: { onOpenFriend(friend.id) }) {
                        FriendAvatar(name: friend.displayName, emoji: friend.emoji, size: 22)
                    }
                }
            }
            .scaledPadding(.horizontal, 14)
        }
        .scaledPadding(.bottom, 8)
    }

    // MARK: Content

    @ViewBuilder private func content(now: Date) -> some View {
        let visible = store.visibleFriends(now: now)
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.error {
                ErrorBanner(error: error, retry: { Task { await store.load() } })
                    .scaledPadding(.bottom, 12)
            }
            if store.me?.sharingPaused == true {
                Label("Sharing is paused for every friend", systemImage: "pause.circle.fill")
                    .scaledFont(14, weight: .medium)
                    .foregroundStyle(Theme.late)
                    .scaledPadding(.bottom, 12)
            }
            requests
            if store.friends.isEmpty {
                if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200).accessibilityLabel("Loading your friends")
                } else if store.error == nil {
                    emptyState(FriendFacts.emptyTitle, FriendFacts.emptyText, button: true)
                }
            } else if visible.isEmpty {
                emptyState(FriendFacts.quietTitle, FriendFacts.quietText, button: false)
            } else {
                CapsHeader(store.filter == .soon ? "Flying Soon" : "Friends",
                           trailing: visible.count == 1 ? "1 friend" : "\(visible.count) friends")
                    .scaledPadding(.top, 6)
                    .scaledPadding(.bottom, 6)
                ForEach(visible) { friend in
                    Button { onOpenFriend(friend.id) } label: {
                        FriendRow(friend: friend, next: store.nextFlight(of: friend.id), now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let me = store.me {
                Text("Your friend code: \(me.spacedCode)")
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .scaledPadding(.top, 22)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.bottom, 24)
    }

    @ViewBuilder private var requests: some View {
        let incoming = store.incoming, outgoing = store.outgoing
        if !incoming.isEmpty || !outgoing.isEmpty {
            CapsHeader("Requests").scaledPadding(.bottom, 6)
            ForEach(incoming) { r in
                HStack(spacing: 12) {
                    FriendAvatar(name: r.displayName, emoji: r.emoji, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.displayName ?? "Someone").scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                        Text("Used your friend code").scaledFont(14).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Decline") { Task { await store.respond(to: r, accept: false) } }
                        .scaledFont(15, weight: .semibold).foregroundStyle(Theme.secondary)
                    Button("Accept") { Task { await store.respond(to: r, accept: true) } }
                        .scaledFont(15, weight: .semibold).foregroundStyle(.white)
                        .scaledPadding(.horizontal, 12).scaledPadding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .scaledPadding(.vertical, 8)
            }
            ForEach(outgoing) { r in
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill").scaledFont(16).foregroundStyle(Theme.secondary).frame(width: 40)
                    Text("Request sent, waiting for an answer").scaledFont(15).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") { Task { await store.cancel(r) } }
                        .scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary).buttonStyle(.plain)
                }
                .scaledPadding(.vertical, 8)
            }
            Spacer().frame(height: 0).scaledPadding(.bottom, 14)
        }
    }

    private func emptyState(_ title: String, _ text: String, button: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title).scaledFont(17, weight: .semibold).foregroundStyle(Theme.secondary)
            Text(text).scaledFont(15).foregroundStyle(Theme.secondary.opacity(0.8))
            if button {
                Button { adding = true } label: {
                    Label("Add a Friend", systemImage: "person.badge.plus")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .scaledPadding(.horizontal, 16)
                        .scaledPadding(.vertical, 9)
                        .background(Capsule().fill(Theme.pill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .scaledPadding(.top, 10)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 220)
        .scaledPadding(.horizontal, 12)
    }
}

/// A friend in the list: their avatar and name, then their next flight and its status in its colour.
struct FriendRow: View {
    var friend: Friend
    var next: Flight?
    var now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FriendAvatar(name: friend.displayName, emoji: friend.emoji, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(friend.name).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary).lineLimit(1)
                    if let next {
                        let status = FriendFacts.status(next, now: now)
                        Text(FriendFacts.summary(next)).scaledFont(15).foregroundStyle(Theme.primary.opacity(0.85))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(status.color).frame(width: 7, height: 7)
                            Text(status.text).scaledFont(14, weight: .medium).foregroundStyle(status.color)
                        }
                    } else {
                        Text(friend.sharesFlights ? "No upcoming flights" : "Not sharing flights")
                            .scaledFont(15).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .scaledPadding(.vertical, 12)
            .contentShape(Rectangle())
            Hairline().scaledPadding(.leading, 56)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Add a friend

/// Invite with a single-use link (the share sheet), show the user's code, or type a friend's code.
struct AddFriendSheet: View {
    var store: FriendsStore
    var onClose: () -> Void
    @State private var code = ""
    @State private var result: String?
    @State private var resultIsError = false
    @State private var sending = false
    @State private var making = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Add a Friend").scaledFont(28, weight: .bold).foregroundStyle(Theme.primary)
                    Spacer()
                    RoundButton(systemImage: "xmark", label: "Close", action: onClose)
                }
                Text("Friends see each other's upcoming flights. Soma Flight never reads your contacts or looks anyone up by phone or email.")
                    .scaledFont(15).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

                DetailCard {
                    CardTitle("Invite with a link", subtitle: "Each link works once, for 7 days")
                        .scaledPadding(.bottom, 14)
                    if let invite = store.invite {
                        ShareLink(item: invite.url, subject: Text("Soma Flight"),
                                  message: Text("Be my friend on Soma Flight so we can see each other's flights.")) {
                            Label("Share Invite Link", systemImage: "square.and.arrow.up")
                                .scaledFont(16, weight: .semibold).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).scaledPadding(.vertical, 12)
                                .background(Capsule().fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                        Button("Make Another Link") { make() }
                            .scaledFont(14, weight: .medium).foregroundStyle(Theme.secondary)
                            .buttonStyle(.plain).scaledPadding(.top, 10)
                    } else {
                        Button { make() } label: {
                            Group {
                                if making { ProgressView() } else {
                                    Label("Create Invite Link", systemImage: "link")
                                }
                            }
                            .scaledFont(16, weight: .semibold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).scaledPadding(.vertical, 12)
                            .background(Capsule().fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(making)
                    }
                }

                DetailCard {
                    CardTitle("Your friend code", subtitle: "Read it out or send it; you accept each request")
                        .scaledPadding(.bottom, 12)
                    HStack {
                        Text(store.me?.spacedCode ?? "········")
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                        Spacer()
                        if let me = store.me {
                            Button { Pasteboard.copy(me.friendCode) } label: {
                                Image(systemName: "doc.on.doc").scaledFont(17, weight: .medium)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy Friend Code")
                        }
                    }
                }

                DetailCard {
                    CardTitle("Add by code", subtitle: "Your friend sees your request and answers it")
                        .scaledPadding(.bottom, 12)
                    HStack(spacing: 10) {
                        TextField("8 letters and digits", text: $code)
                            .font(.system(size: 20, weight: .medium, design: .monospaced))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .onSubmit(send)
                        Button("Send", action: send)
                            .scaledFont(16, weight: .semibold)
                            .disabled(FriendLink.code(code) == nil || sending)
                    }
                    if let result {
                        Text(result).scaledFont(14)
                            .foregroundStyle(resultIsError ? Theme.veryLate : Theme.onTime)
                            .scaledPadding(.top, 8)
                    }
                }
                if let error = store.error { ErrorBanner(error: error) }
            }
            .scaledPadding(.horizontal, 20)
            .scaledPadding(.vertical, 20)
        }
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationCornerRadius(Theme.sheetRadius)
        .task { if store.me == nil { await store.load() } }
    }

    private func make() {
        making = true
        Task { _ = await store.makeInvite(); making = false }
    }

    private func send() {
        guard FriendLink.code(code) != nil, !sending else { return }
        sending = true
        Task {
            do {
                switch try await store.request(code: code) {
                case .sent: result = "Request sent."
                case .accepted: result = "You are now friends."
                case .friends: result = "You are already friends."
                }
                resultIsError = false
                code = ""
            } catch {
                let e = error as? APIError ?? .providerUnavailable
                result = e == .notFound ? "No one has this code." : e.message
                resultIsError = true
            }
            sending = false
        }
    }
}

#if DEBUG
// MARK: - Previews

struct FriendsPreview: View {
    var empty = false
    @State private var store: FriendsStore?

    var body: some View {
        Group {
            if let store { FriendsView(store: store, onOpenFriend: { _ in }, lookup: PreviewData.airport, now: PreviewData.now) }
            else { ProgressView() }
        }
        .task {
            let s = FriendsStore(service: empty ? UnavailableFriendsService() : FakeFriendsService(now: PreviewData.now))
            await s.load()
            store = s
        }
    }
}

#Preview("Friends, dark") { FriendsPreview().preferredColorScheme(.dark) }
#Preview("Friends, light") { FriendsPreview().preferredColorScheme(.light) }
#Preview("No friends") { FriendsPreview(empty: true).preferredColorScheme(.dark) }
#Preview("Invitation") {
    FriendInviteSheet(invite: PendingFriendInvite(token: FakeFriendsService.junToken,
                                                  preview: FriendInvitePreview(state: .open, displayName: "Jun", emoji: "🌊")),
                      onAnswer: { _ in nil }, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
