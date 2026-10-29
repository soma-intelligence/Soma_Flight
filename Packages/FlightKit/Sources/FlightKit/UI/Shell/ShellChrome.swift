import SwiftUI

// MARK: - Pushed screens

/// Flight detail with its own store, loaded on appear, and the circular X that pops it.
public struct FlightScreen: View {
    @State private var store: FlightDetailStore
    var onAirport: (String) -> Void
    var onClose: () -> Void

    public init(env: AppEnvironment, id: Flight.ID, owner: UUID?, onAirport: @escaping (String) -> Void,
                onClose: @escaping () -> Void) {
        _store = State(initialValue: env.makeFlightDetailStore(id: id, owner: owner))
        self.onAirport = onAirport; self.onClose = onClose
    }

    public var body: some View {
        FlightDetailView(store: store, onAirport: onAirport)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .task { await store.load() }
    }
}

/// Airport sheet with its own store; far-end city names come from the shared airport list.
public struct AirportScreen: View {
    @State private var store: AirportStore
    var lookup: (String) -> Airport?
    var onClose: () -> Void

    public init(env: AppEnvironment, code: String, onClose: @escaping () -> Void) {
        _store = State(initialValue: env.makeAirportStore(code: code))
        self.lookup = env.lookup; self.onClose = onClose
    }

    public var body: some View {
        AirportView(store: store, lookup: lookup)
            .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
            .task { await store.load() }
    }
}

/// The screen a route in the panel's stack opens.
public struct HomeDestination: View {
    var home: HomeModel
    var route: SheetRoute

    public init(home: HomeModel, route: SheetRoute) {
        self.home = home; self.route = route
    }

    public var body: some View {
        switch route {
        case .flight(let id):
            FlightScreen(env: home.env, id: id, owner: home.owner, onAirport: home.open(airport:), onClose: home.shell.close)
        case .airport(let code):
            AirportScreen(env: home.env, code: code, onClose: home.shell.close)
        }
    }
}

// MARK: - Chrome

/// Floating pill with the two tabs and the round search button beside it.
public struct HomeTabPill: View {
    @Binding var tab: HomeTab
    var onSearch: () -> Void
    var bottom: CGFloat
    @Namespace private var selectionSpace

    /// Darkens the glass so the cards scrolling under it stay quiet, as in the reference.
    static let tint = Color(light: 0xFFFFFF, dark: 0x1C1C1E).opacity(0.55)

    /// - Parameter bottom: space under the pill; negative reaches into a home indicator inset.
    public init(tab: Binding<HomeTab>, bottom: CGFloat = 0, onSearch: @escaping () -> Void) {
        _tab = tab; self.bottom = bottom; self.onSearch = onSearch
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                item(.flights, title: "My Flights", systemImage: "airplane.circle.fill")
                item(.passport, title: "Passport", systemImage: "person.text.rectangle.fill")
            }
            .padding(4)
            .glassEffect(.regular.tint(Self.tint), in: .capsule)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 59, height: 59)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Self.tint).interactive(), in: .circle)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, bottom)
    }

    private func item(_ value: HomeTab, title: String, systemImage: String) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.snappy) { tab = value }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 25)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 51)
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Round grey button for the panel header (Settings) and the close X, filled as in the reference.
public struct RoundButton: View {
    static let fill = Color(light: 0xE3E3E8, dark: 0x3A3A3C)

    var systemImage: String
    var label: String
    var action: () -> Void

    public init(systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage; self.label = label; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Self.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The circular X at the top right of a pushed screen or a modal sheet.
public struct CloseButton: View {
    var action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        RoundButton(systemImage: "xmark", label: "Close", action: action)
            .padding(.top, 16)
            .padding(.trailing, 16)
    }
}

/// What shows for the moment the environment takes to build, or the reason it could not.
public struct LaunchPlaceholder: View {
    var failure: String?

    public init(failure: String?) { self.failure = failure }

    /// The line shown when the cache cannot open.
    public static let storageFailure = "Soma Flight could not open its storage. Restart the app to try again."

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
    }
}
