#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// Aircraft Stats on the fake history, rendered to docs/screens/screens in light and dark (393 pt @3x): the
/// hero (totals, most flown type, the ranking, the blueprint panels) and the dark sections under it; then
/// the cabin blueprint for every plan family, in docs/screens/components/CabinBlueprint-<family>.png.
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter aircraftStatsScreens
extension ComponentSnapshotTests {
    @Test func aircraftStatsScreens() async throws {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        let service = BundledSideViews(over: FakeBrandAssetService())
        let ranking = store.runnersUp()
        await AircraftImage.preload([(airline: store.mostFlownAirline, type: store.mostFlownType)]
                                    + ranking.map { (airline: $0.airline, type: $0.type) }, service: service)
        let s = store.aircraft
        for (light, suffix) in [(true, "light"), (false, "dark")] {
            try render("aircraft-stats-hero-\(suffix)", to: Self.screensDir, light: light) {
                VStack(spacing: 0) {
                    AircraftTotalsPanel(stats: s, mostFlownType: store.mostFlownType,
                                        mostFlownAirline: store.mostFlownAirline, ranking: ranking)
                        .background(LinearGradient(gradient: Theme.aircraftPage, startPoint: .top, endPoint: .bottom))
                    BlueprintPanel {
                        VStack(spacing: 0) {
                            if let tail = s.tails.first {
                                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                                FrequentedTailPanel(tail: tail, ageMonths: nil)
                            }
                            Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                            CabinPanel(stats: s, type: store.mostFlownType)
                        }
                    }
                }
                .environment(\.brandAssets, service)
            }
        }
        try render("aircraft-stats-sections", to: Self.screensDir) {
            VStack(spacing: 0) {
                AircraftTypesSection(stats: s, year: nil)
                ClassSeatSection(stats: s)
            }
            .background(AircraftStatsView.sections)
        }
        for family in PlanFamily.allCases {
            try render("CabinBlueprint-\(family.rawValue)") {
                BlueprintPanel {
                    CabinBlueprint(stats: s, family: family, typeName: nil).padding(.vertical, 18)
                }
            }
        }
    }
}
#endif
