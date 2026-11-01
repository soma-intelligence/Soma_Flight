#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import FlightKit

/// The Delay Report on the fake history, rendered to docs/screens/screens (393 pt @3x): the hero under
/// the top bar and the chips, and the sections. The page scrolls, and ImageRenderer draws a ScrollView
/// blank, so the parts are rendered one after the other as the page stacks them.
///
///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter delayReportScreens
extension ComponentSnapshotTests {
    @Test func delayReportScreens() async throws {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        let report = store.delayReport
        #expect(report.withTimes > 0 && report.lateDepartures.of > 0)
        // Fill the side view memo, so the hardest-hit airline's tail shows in a render that runs no task.
        let service = BundledSideViews(over: FakeBrandAssetService())
        let reference = ReferenceData.bundled()
        let pairs = report.airlineLosses.prefix(1).map {
            (airline: reference.airline($0.key), type: $0.type.flatMap { reference.type($0) })
        }
        await AircraftImage.preload(pairs, service: service)

        try render("delay-report-hero", to: Self.screensDir) {
            VStack(spacing: 0) {
                topBar
                YearChips(years: store.years, selection: .constant(nil), fill: .white.opacity(0.14))
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background(DelayInk.page)
                DelayReportHero(report: report, year: nil, lookup: PreviewData.airport)
            }
            .environment(\.airportStaticControls, true)
            .environment(\.brandAssets, service)
        }
        try render("delay-report-sections", to: Self.screensDir) {
            DelayReportSections(report: report, year: nil, key: 0, lookup: PreviewData.airport)
                .background(DelayInk.sections)
                .environment(\.brandAssets, service)
        }
    }

    private var topBar: some View {
        ZStack {
            Text("Delay Report").scaledFont(17, weight: .semibold).foregroundStyle(.white)
            HStack {
                Circle().fill(.white.opacity(0.10)).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "xmark").font(.system(size: 18, weight: .medium)).foregroundStyle(.white))
                Spacer()
                Circle().fill(.white.opacity(0.10)).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium)).foregroundStyle(.white))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(DelayInk.page)
    }
}
#endif
