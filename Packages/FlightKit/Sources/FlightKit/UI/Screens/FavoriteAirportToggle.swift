import SwiftUI

/// The bell on the airport sheet: follow this airport for ground stops, delay programs and closures.
/// Hidden outside the FAA's coverage and until the account's follow list has loaded.
public struct FavoriteAirportToggle: View {
    @State private var store: FavoriteAirportAlertsStore
    private let icao: String?
    private let covered: Bool

    /// - Parameters:
    ///   - icao: the airport's ICAO code, nil while it loads.
    ///   - country: the airport's country code; only the FAA's airports can alert.
    public init(service: any FavoriteAirportAlertsService, icao: String?, country: String?) {
        _store = State(initialValue: FavoriteAirportAlertsStore(service: service))
        self.icao = icao
        covered = country.map(FavoriteAirportAlertsStore.covers(country:)) ?? false
    }

    public var body: some View {
        Group {
            if covered && store.isAvailable {
                RoundButton(systemImage: store.isFollowing ? "bell.fill" : "bell",
                            label: store.isFollowing ? "Stop alerts for this airport" : "Alert me about this airport") {
                    Task { await store.toggle() }
                }
                .accessibilityValue(store.isFollowing ? "On" : "Off")
                .accessibilityHint("Ground stops, delay programs and closures")
                .scaledPadding(.top, 16)
            }
        }
        .task(id: "\(icao ?? "")\(covered)") { await store.load(icao: covered ? icao : nil) }
    }
}
