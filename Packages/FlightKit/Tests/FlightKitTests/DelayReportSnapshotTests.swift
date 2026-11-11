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
            DelayReportSections(report: report, year: nil, lookup: PreviewData.airport)
                .background(DelayInk.sections)
                .environment(\.brandAssets, service)
        }
    }

    /// The hardest-hit tail across the families (narrow and wide bodies, tail-engined jets, props, our own
    /// drawing for a pair without a side view), in a bar as narrow as three airlines leave it and as wide as
    /// one alone, in docs/screens/components/AircraftTail.png.
    ///
    ///     SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter aircraftTailGallery
    @Test func aircraftTailGallery() async throws {
        let service = BundledSideViews(over: FakeBrandAssetService())
        let reference = ReferenceData.bundled()
        let pairs = ["UAL-B789", "UAL-B38M", "AAL-A321", "AFR-A359", "AAL-B77W", "ANA-A388", "DLH-B748",
                     "ANE-CRJ9", "ANE-AT72", "ANA-DH8D", "AAL-E75L", "DAL-BCS3", "DLH-A320", "UAL-B752"]
        let resolved = pairs.map { pair -> (Airline?, AircraftType?) in
            let parts = pair.split(separator: "-").map(String.init)
            return (reference.airline(parts[0]), reference.type(parts[1]))
        }
        await AircraftImage.preload(resolved.map { (airline: $0.0, type: $0.1) }, service: service)
        try render("AircraftTail") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(resolved.enumerated()), id: \.offset) { i, pair in
                    HStack(alignment: .bottom, spacing: 12) {
                        tailBlock(pair.0, pair.1, width: 166)
                        tailBlock(pair.0, pair.1, width: 190)
                    }
                    Text(pairs[i]).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                tailBlock(reference.airline("UAL"), reference.type("B789"), width: 361)
                tailBlock(reference.airline("AFR"), reference.type("A359"), width: 361)
            }
            .padding(16)
            .background(DelayInk.page)
            .environment(\.brandAssets, service)
        }
    }

    /// The Aircraft Stats hero (totals and the most flown type's side view on the light blue page), to check
    /// the side view sits on the page with no box around it, in docs/screens/components/AircraftStatsHero.png.
    @Test func aircraftStatsHero() async throws {
        let store = PassportStore(history: FakeHistoryService())
        await store.load()
        let service = BundledSideViews(over: FakeBrandAssetService())
        await AircraftImage.preload([(airline: store.mostFlownAirline, type: store.mostFlownType)], service: service)
        try render("AircraftStatsHero", light: true) {
            AircraftTotalsPanel(stats: store.aircraft, mostFlownType: store.mostFlownType,
                                mostFlownAirline: store.mostFlownAirline)
                .background(LinearGradient(gradient: Theme.aircraftPage, startPoint: .top, endPoint: .bottom))
                .environment(\.brandAssets, service)
        }
    }

    private func tailBlock(_ airline: Airline?, _ type: AircraftType?, width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(DelayInk.late)
            AircraftTail(type: type, airline: airline, rise: AirlineLossBar.rise)
        }
        .frame(width: width, height: 64)
        .padding(.top, AirlineLossBar.rise)
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
