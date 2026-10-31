import SwiftUI

/// The Friends tab: the title with one Add Friend button (the shell's Settings gear sits beside it), requests
/// waiting for an answer as a compact banner, then friends in three groups (in the air, a flight coming up,
/// nothing coming up), each row with their next flight in its status colour. The user's friend code closes
/// the list as a card, with the tab's other actions in its menu. With no friend yet, a short invitation opens
/// the share sheet. A friend's row opens their page; a long press holds the sharing switches and Remove. Their
/// flights draw on the globe in the friends colour while this tab is open (the shell's `HomeModel.globe`).
///
/// The shell owns loading (`HomeModel.load()`); the view reloads on pull to refresh and the banner's retry.
public struct FriendsView: View {
    var store: FriendsStore
    var onOpenFriend: (UUID) -> Void
    var lookup: (String) -> Airport?
    var fixedNow: Date?
    var scrolls: Bool
    @State private var adding = false
    @State private var showingQR = false
    @State private var removing: Friend?

    /// - Parameters:
    ///   - onOpenFriend: opens a friend's page.
    ///   - now: a fixed clock for previews; nil follows the real time.
    public init(store: FriendsStore, onOpenFriend: @escaping (UUID) -> Void,
                lookup: @escaping (String) -> Airport? = { _ in nil }, now: Date? = nil) {
        self.init(store: store, onOpenFriend: onOpenFriend, lookup: lookup, now: now, scrolls: true)
    }

    init(store: FriendsStore, onOpenFriend: @escaping (UUID) -> Void, lookup: @escaping (String) -> Airport?,
         now: Date?, scrolls: Bool) {
        self.store = store; self.onOpenFriend = onOpenFriend; self.lookup = lookup
        self.fixedNow = now; self.scrolls = scrolls
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            VStack(alignment: .leading, spacing: 0) {
                // Same title and spacing as My Flights and Passport; the add button sits left of the
                // shell's Settings gear, which keeps the last 60 points.
                ScreenTitle("Friends")
                    .overlay(alignment: .trailing) {
                        RoundButton(systemImage: "person.badge.plus", label: "Add Friend") { adding = true }
                            .scaledPadding(.trailing, 48)
                    }
                    .scaledPadding(.horizontal, Theme.gutter)
                    .scaledPadding(.top, 22)
                    .scaledPadding(.bottom, 12)
                ScreenScroll(scrolls: scrolls, refresh: { await store.load() }) { content(now: now) }
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $adding) {
            AddFriendSheet(store: store) { adding = false }
                #if os(macOS)
                .frame(width: 420, height: 600)
                #endif
        }
        .sheet(isPresented: $showingQR) {
            FriendQRSheet(store: store) { showingQR = false }
                #if os(macOS)
                .frame(width: 400, height: 560)
                #endif
        }
        .confirmationDialog("Remove \(removing?.name ?? "this friend")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { friend in
            Button("Remove Friend", role: .destructive) { Task { await store.remove(friend.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You stop seeing each other's flights. To be friends again, one of you sends a new invitation.")
        }
    }

    // MARK: Content

    @ViewBuilder private func content(now: Date) -> some View {
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
            FriendRequestsBanner(store: store)
            if store.friends.isEmpty {
                if !store.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200).accessibilityLabel("Loading your friends")
                } else if store.error == nil {
                    FriendsEmptyState(store: store)
                }
            } else {
                ForEach(store.sections(), id: \.section) { group in
                    CapsHeader(group.section.title,
                               trailing: group.friends.count == 1 ? "1 friend" : "\(group.friends.count) friends")
                        .scaledPadding(.top, 6)
                        .scaledPadding(.bottom, 4)
                    ForEach(group.friends) { friend in
                        Button { onOpenFriend(friend.id) } label: {
                            FriendRow(friend: friend, next: store.upcomingFlight(of: friend.id), lookup: lookup, now: now)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(friend) }
                    }
                    Spacer().frame(height: 0).scaledPadding(.bottom, 18)
                }
            }
            if store.me != nil {
                FriendCodeCard(store: store, onShowQR: { showingQR = true })
                    .scaledPadding(.top, store.friends.isEmpty ? 28 : 6)
            }
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.bottom, 32)
    }

    /// A row's long press: what the user shares with this friend, alerts for their flights, Remove.
    @ViewBuilder private func menu(_ friend: Friend) -> some View {
        Toggle("Share My Flights", systemImage: "airplane", isOn: binding(friend, \.shareFlights))
        Toggle("Share My Passport Totals", systemImage: "globe.europe.africa.fill", isOn: binding(friend, \.sharePassport))
        Toggle("Alerts for \(friend.name)'s Flights", systemImage: "bell.badge", isOn: binding(friend, \.alerts))
        Divider()
        Button("Remove Friend", systemImage: "person.badge.minus", role: .destructive) { removing = friend }
    }

    private func binding(_ friend: Friend, _ key: WritableKeyPath<FriendSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.friend(friend.id)?.settings[keyPath: key] ?? false },
                set: { v in Task { await store.update(friend.id) { $0[keyPath: key] = v } } })
    }
}

/// Requests waiting on the tab, as one compact card: each incoming one with Accept and a quiet decline, each
/// one the user sent with Cancel. Nothing shows without a request.
struct FriendRequestsBanner: View {
    var store: FriendsStore

    var body: some View {
        let incoming = store.incoming, outgoing = store.outgoing
        if !incoming.isEmpty || !outgoing.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(incoming.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Hairline().scaledPadding(.leading, 46) }
                    HStack(spacing: 10) {
                        FriendAvatar(name: r.displayName, emoji: r.emoji, size: 34, id: r.id)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.displayName ?? "Someone")
                                .scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary).lineLimit(1)
                            Text("Wants to be friends").scaledFont(13).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button { Task { await store.respond(to: r, accept: false) } } label: {
                            Image(systemName: "xmark").scaledFont(13, weight: .bold).foregroundStyle(Theme.secondary)
                                .frame(width: 32, height: 32).background(Circle().fill(Theme.pill))
                        }
                        .accessibilityLabel("Decline")
                        Button { Task { await store.respond(to: r, accept: true) } } label: {
                            Text("Accept").scaledFont(14, weight: .semibold).foregroundStyle(.white)
                                .scaledPadding(.horizontal, 12).scaledPadding(.vertical, 7)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                    .buttonStyle(.plain)
                    .scaledPadding(.vertical, 10)
                }
                ForEach(Array(outgoing.enumerated()), id: \.element.id) { i, r in
                    if i > 0 || !incoming.isEmpty { Hairline().scaledPadding(.leading, 46) }
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill").scaledFont(14).foregroundStyle(Theme.secondary)
                            .frame(width: 34)
                        Text("Request sent, waiting for an answer").scaledFont(14).foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Button("Cancel") { Task { await store.cancel(r) } }
                            .scaledFont(14, weight: .semibold).foregroundStyle(Theme.primary).buttonStyle(.plain)
                    }
                    .scaledPadding(.vertical, 10)
                }
            }
            .scaledPadding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            .scaledPadding(.bottom, 18)
        }
    }
}

/// A friend in the list: their avatar and name, their next flight ("AF 84 · Paris → San Francisco"), then
/// where it stands ("departs in 3h") in its status colour after a dot of that colour.
struct FriendRow: View {
    var friend: Friend
    var next: Flight?
    var lookup: (String) -> Airport? = { _ in nil }
    var now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                FriendAvatar(name: friend.displayName, emoji: friend.emoji, size: 46, id: friend.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(friend.name).scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary).lineLimit(1)
                    if let next {
                        let when = FriendFacts.when(next, now: now)
                        Text(FriendFacts.route(next, lookup: lookup))
                            .scaledFont(15).foregroundStyle(Theme.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(when.color).frame(width: 7, height: 7)
                            Text(when.text).scaledFont(15, weight: .medium).foregroundStyle(when.color).lineLimit(1)
                        }
                    } else {
                        Text(friend.sharesFlights ? FriendFacts.since(friend.since) : "Not sharing flights with you")
                            .scaledFont(15).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .scaledPadding(.vertical, 12)
            .contentShape(Rectangle())
            Hairline().scaledPadding(.leading, 60)
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
                            Button { Pasteboard.copy(me.friendCode, sensitive: true) } label: {
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
