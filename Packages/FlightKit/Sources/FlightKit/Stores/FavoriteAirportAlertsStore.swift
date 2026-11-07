import Foundation
import Observation

/// Whether one airport is followed for disruption alerts, behind the toggle on the airport sheet. Stays
/// hidden (`isAvailable` false) until the account's list has loaded, so a backend without the feature
/// shows nothing instead of a switch that fails.
@MainActor @Observable
public final class FavoriteAirportAlertsStore {
    public private(set) var icao: String?
    public private(set) var isFollowing = false
    public private(set) var isAvailable = false
    public private(set) var error: APIError?
    public private(set) var isSaving = false

    private let service: any FavoriteAirportAlertsService

    public init(service: any FavoriteAirportAlertsService) { self.service = service }

    /// The countries whose airports the FAA status feed covers: the only ones the server alerts for.
    public static let coveredCountries: Set<String> = ["US", "PR", "GU", "VI", "AS", "MP"]

    public static func covers(country: String) -> Bool { coveredCountries.contains(country.uppercased()) }

    /// Reads the account's list for `icao` (ICAO code); nil clears the store.
    public func load(icao: String?) async {
        self.icao = icao
        isAvailable = false
        guard let icao else { return }
        do {
            let all = try await service.followed()
            guard self.icao == icao else { return }
            isFollowing = all.contains(icao)
            isAvailable = true
            error = nil
        } catch {
            // Offline or not deployed: no toggle, no banner.
            isAvailable = false
        }
    }

    /// Flips the switch at once and puts it back when the save fails.
    public func toggle() async {
        guard isAvailable, !isSaving, let icao else { return }
        let target = !isFollowing
        isFollowing = target
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.set(icao, following: target)
            error = nil
        } catch {
            isFollowing = !target
            self.error = error
        }
    }
}
