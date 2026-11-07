import SwiftUI

/// One friend: their flights (each opens read only in the flight sheet), their Passport totals when they
/// share them, what the user shares with them, alerts for their flights, and Remove Friend.
public struct FriendPageView: View {
    var store: FriendsStore
    var friendID: UUID
    var lookup: (String) -> Airport?
    var onOpenFlight: (FriendFlight) -> Void
    var onClose: () -> Void
    var fixedNow: Date?
    @State private var confirmingRemove = false
    @Environment(\.reference) private var reference
    @Environment(\.units) private var units

    public init(store: FriendsStore, friendID: UUID, lookup: @escaping (String) -> Airport?,
                onOpenFlight: @escaping (FriendFlight) -> Void, onClose: @escaping () -> Void, now: Date? = nil) {
        self.store = store; self.friendID = friendID; self.lookup = lookup
        self.onOpenFlight = onOpenFlight; self.onClose = onClose; self.fixedNow = now
    }

    public var body: some View {
        ClockView(fixed: fixedNow) { now in
            Group {
                if let friend = store.friend(friendID) {
                    ScrollView { page(friend, now: now) }
                } else {
                    VStack {
                        HStack { Spacer(); RoundButton(systemImage: "xmark", label: "Close", action: onClose) }
                        Spacer()
                        Text("No longer friends").scaledFont(17, weight: .semibold).foregroundStyle(Theme.secondary)
                        Spacer()
                    }
                    .scaledPadding(.all, 16)
                }
            }
        }
        .background(Theme.background)
        .task(id: friendID) { await store.loadPassport(of: friendID) }
        .confirmationDialog("Remove \(store.friend(friendID)?.name ?? "this friend")?", isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove Friend", role: .destructive) {
                Task {
                    await store.remove(friendID)
                    if store.friend(friendID) == nil { onClose() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You stop seeing each other's flights. To be friends again, one of you sends a new invitation.")
        }
    }

    private func page(_ friend: Friend, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                FriendAvatar(name: friend.displayName, emoji: friend.emoji, size: 60, id: friend.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ui: friend.name).scaledFont(28, weight: .bold).foregroundStyle(Theme.primary).lineLimit(2)
                    Text(FriendFacts.since(friend.since)).scaledFont(15).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                RoundButton(systemImage: "xmark", label: "Close", action: onClose)
            }
            .scaledPadding(.top, 16)

            if let error = store.error { ErrorBanner(error: error) }

            flights(friend, now: now)

            if friend.sharesPassport, let p = store.passports[friend.id] { passport(friend, p) }

            DetailCard {
                CardTitle("You share", subtitle: store.me?.sharingPaused == true
                          ? "Paused for every friend (the menu by your friend code)" : "Only with \(friend.name)")
                    .scaledPadding(.bottom, 4)
                FriendToggleRow(icon: "airplane", title: "My Upcoming Flights",
                                subtitle: "Route, times, status, gate and belt. Never your seat, booking code or notes.",
                                isOn: binding(friend, \.shareFlights))
                FriendToggleRow(icon: "globe.europe.africa.fill", title: "My Passport Totals",
                                subtitle: "Flights, distance and places counted, no flight list.",
                                isOn: binding(friend, \.sharePassport), last: true)
            }

            DetailCard {
                CardTitle("Alerts").scaledPadding(.bottom, 4)
                FriendToggleRow(icon: "bell.badge.fill", title: "\(friend.name)'s Flights",
                                subtitle: "Take-off, landing and delays of 30 minutes or more. Your Delays and Take-off and Landing settings still apply.",
                                isOn: binding(friend, \.alerts), last: true)
            }

            Button(role: .destructive) { confirmingRemove = true } label: {
                Label("Remove Friend", systemImage: "person.badge.minus")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.veryLate)
                    .frame(maxWidth: .infinity)
                    .scaledPadding(.vertical, 14)
                    .background(Capsule().fill(Theme.veryLate.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.bottom, 32)
    }

    @ViewBuilder private func flights(_ friend: Friend, now: Date) -> some View {
        let list = store.flights(of: friend.id)
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader("Their Flights", trailing: list.isEmpty ? nil : list.count == 1 ? "1 flight" : "\(list.count) flights")
                .scaledPadding(.bottom, 8)
            if list.isEmpty {
                Text(friend.sharesFlights ? "Nothing coming up." : "\(friend.name) is not sharing flights with you right now.")
                    .scaledFont(15).foregroundStyle(Theme.secondary)
                    .scaledPadding(.vertical, 8)
            } else {
                ForEach(list) { ff in
                    Button { onOpenFlight(ff) } label: {
                        MyFlightRow(flight: ff.flight, origin: lookup(ff.flight.originIcao),
                                    destination: lookup(ff.flight.destinationIcao), airline: airline(ff.flight), now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func passport(_ friend: Friend, _ p: FriendPassport) -> some View {
        let distance = units.distance == .km ? p.distanceKm : Int((Double(p.distanceKm) / 1.609344).rounded())
        let cells: [(String, String)] = [
            ("\(p.flights)", "flights"),
            ("\(distance.formatted())", units.distance == .km ? "km" : "mi"),
            ("\(p.airMinutes / 60)", "hours"),
            ("\(p.airports)", "airports"),
            ("\(p.countries)", "countries"),
            ("\(p.airlines)", "airlines"),
        ]
        return DetailCard {
            CardTitle("Passport", subtitle: "\(friend.name)'s totals").scaledPadding(.bottom, 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 14) {
                ForEach(cells, id: \.1) { value, label in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ui: value).scaledFont(22, weight: .semibold).foregroundStyle(Theme.primary)
                        Text(ui: label).scaledFont(13).foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func binding(_ friend: Friend, _ key: WritableKeyPath<FriendSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.friend(friend.id)?.settings[keyPath: key] ?? false },
                set: { v in Task { await store.update(friend.id) { $0[keyPath: key] = v } } })
    }

    private func airline(_ f: Flight) -> Airline? {
        f.operator.flatMap { reference.airline($0) } ?? reference.airline(ident: f.ident)
    }
}

#if DEBUG
struct FriendPagePreview: View {
    @State private var store: FriendsStore?

    var body: some View {
        Group {
            if let store {
                FriendPageView(store: store, friendID: FakeFriendsService.maya, lookup: PreviewData.airport,
                               onOpenFlight: { _ in }, onClose: {}, now: PreviewData.now)
            } else { ProgressView() }
        }
        .task {
            let s = FriendsStore(service: FakeFriendsService(now: PreviewData.now))
            await s.load()
            store = s
        }
    }
}

#Preview("Friend page") { FriendPagePreview().preferredColorScheme(.dark) }
#endif
