#if DEBUG
import SwiftUI

// Contract
// - Name: `ComponentGallery` (D10), Debug builds only.
// - Use: every shared component of `UI/Refined/` and the banners in their states, on one scrolling page.
//   The iOS app opens it with the launch argument `-gallery YES`; `RefinedSnapshotTests` records the same
//   specimens, so what the gallery shows is what the snapshots protect.
// - Controls: a light/dark switch, a Dynamic Type slider (xSmall to accessibility5) and a long-content
//   switch (very long airport names, a missing airline name, an emoji friend name: A13).
// - Data: the seed fixtures at the seed's own "now", so every run draws the same thing.

/// A page of every refined component in its states, with appearance, text size and content controls.
public struct ComponentGallery: View {
    @State private var dark = false
    @State private var typeIndex = Double(ComponentGallery.sizes.firstIndex(of: .large) ?? 3)
    @State private var longContent = false

    public init() {}

    /// The launch asked for the gallery (`-gallery YES`).
    public static var isRequested: Bool { UserDefaults.standard.bool(forKey: "gallery") }

    static let sizes = Array(DynamicTypeSize.allCases)

    private var typeSize: DynamicTypeSize { Self.sizes[min(Self.sizes.count - 1, max(0, Int(typeIndex)))] }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                controls
                ForEach(GallerySpecimen.allCases) { specimen in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: specimen.title)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .dynamicTypeSize(.large)
                        specimen.view(long: longContent)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .background(Theme.background.ignoresSafeArea())
        .dynamicTypeSize(typeSize)
        .environment(\.colorScheme, dark ? .dark : .light)
        .preferredColorScheme(dark ? .dark : .light)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Component Gallery").font(.system(size: 28, weight: .bold))
            Toggle(isOn: $dark) { Text(verbatim: "Dark") }
            Toggle(isOn: $longContent) { Text(verbatim: "Long content") }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Text size: \(String(describing: typeSize))")
                Slider(value: $typeIndex, in: 0...Double(Self.sizes.count - 1), step: 1)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Theme.primary)
        .dynamicTypeSize(.large)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
        .padding(.horizontal, 16)
    }
}

/// One component of the gallery in all its states. `RefinedSnapshotTests` renders each one.
enum GallerySpecimen: String, CaseIterable, Identifiable {
    case statusLine, progressBar, refinedCard, sectionLabel, sheetHeader, actionBar, mapControls, statusPill
    case errorBanner, offlinePill, staleBadge, formField, loadingButton, myFlightRow, boardRow, friendRow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .statusLine: "StatusLine"
        case .progressBar: "FlightProgressBar"
        case .refinedCard: "RefinedCard"
        case .sectionLabel: "SectionLabel"
        case .sheetHeader: "SheetHeader"
        case .actionBar: "GlassActionBar"
        case .mapControls: "MapControlCapsule"
        case .statusPill: "StatusPill"
        case .errorBanner: "ErrorBanner"
        case .offlinePill: "OfflineBanner"
        case .staleBadge: "StaleBadge"
        case .formField: "FormField"
        case .loadingButton: "LoadingButtonStyle"
        case .myFlightRow: "MyFlightRow"
        case .boardRow: "BoardRow"
        case .friendRow: "FriendRow"
        }
    }

    /// - Parameter long: the extreme content of A13 (very long names, no airline name, emoji names).
    @MainActor @ViewBuilder func view(long: Bool) -> some View {
        switch self {
        case .statusLine: GallerySpecimens.statusLines(long: long)
        case .progressBar: GallerySpecimens.progressBars
        case .refinedCard: GallerySpecimens.cards(long: long)
        case .sectionLabel: GallerySpecimens.sectionLabels(long: long)
        case .sheetHeader: GallerySpecimens.sheetHeaders(long: long)
        case .actionBar: GallerySpecimens.actionBar
        case .mapControls: GallerySpecimens.mapControls
        case .statusPill: GallerySpecimens.statusPills(long: long)
        case .errorBanner: GallerySpecimens.errorBanners
        case .offlinePill: GallerySpecimens.offline
        case .staleBadge: GallerySpecimens.staleBadges
        case .formField: GallerySpecimens.formFields(long: long)
        case .loadingButton: GallerySpecimens.loadingButtons
        case .myFlightRow: GallerySpecimens.myFlightRows(long: long)
        case .boardRow: GallerySpecimens.boardRows(long: long)
        case .friendRow: GallerySpecimens.friendRows(long: long)
        }
    }
}

/// Fixed data for the specimens: the seed at its own "now", plus the extreme cases of A13.
enum GalleryFixtures {
    static let now = PreviewData.now
    static let longCity = "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"
    static let longAirportName = "Aeropuerto Internacional Presidente Comandante Arturo Merino Benítez de Santiago"
    static let longIdent = "UAL123456"
    static let emojiName = "🦊🌍✈️🏝️🎒"

    /// An airport of the seed with a very long city and name.
    static func longAirport(_ icao: String) -> Airport? {
        guard var a = PreviewData.airport(icao) else { return nil }
        a.city = longCity
        a.name = longAirportName
        return a
    }

    static func airline(for flight: Flight) -> Airline? { ReferenceData.bundled().airline(ident: flight.ident) }

    /// A friend whose chosen name is only emoji.
    static let emojiFriend = Friend(id: UUID(uuidString: "F00D0000-0000-4000-8000-000000000001")!, displayName: emojiName,
                                    emoji: "🦊", since: now.addingTimeInterval(-86_400 * 40))
    static let plainFriend = Friend(id: UUID(uuidString: "F00D0000-0000-4000-8000-000000000002")!, displayName: "Noa Levi",
                                    since: now.addingTimeInterval(-86_400 * 400))
}

/// One row of a row specimen, its airports already chosen.
struct GalleryRow: Identifiable {
    var flight: Flight
    var origin: Airport? = nil
    var destination: Airport? = nil
    var airline: Airline? = nil
    var striped = false
    var id: Flight.ID { flight.id }
}

/// The specimen views, one builder per component.
@MainActor enum GallerySpecimens {
    static let gutter: CGFloat = 16

    // MARK: Status

    static func statusLines(long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusLine("On time · gate B22", tone: Theme.onTime, textTone: Theme.onTimeText)
            StatusLine("Departed 16m late · lands 05:28", tone: Theme.late, textTone: Theme.lateText)
            StatusLine("48m late · lands 06:00", tone: Theme.veryLate, textTone: Theme.veryLateText)
            StatusLine(FlightStatusSummary(text: "Canceled", level: .canceled))
            StatusLine("Diverted to OAK", tone: Theme.diverted, textTone: Theme.divertedText)
            if long {
                StatusLine("Diverted to \(GalleryFixtures.longCity) · gate B22 · lands 23:59",
                           tone: Theme.diverted, textTone: Theme.divertedText)
            }
        }
        .padding(.horizontal, gutter)
    }

    static var progressBars: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlightProgressBar(progress: 0, tone: Theme.onTime)
            FlightProgressBar(progress: 0.35, tone: Theme.onTime)
            FlightProgressBar(progress: 0.6, tone: Theme.late)
            FlightProgressBar(progress: 0.85, tone: Theme.veryLate, showsHead: false)
            FlightProgressBar(progress: 1, tone: Theme.onTime)
        }
        .padding(.horizontal, gutter)
    }

    static func cards(long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RefinedCard {
                Text(verbatim: long ? "Gate change to \(GalleryFixtures.longAirportName)" : "Gate B22, boarding 17:55")
                    .scaledFont(15).foregroundStyle(Theme.primary)
            }
            RefinedCard(severity: Theme.late) {
                Text(verbatim: "Departure 25 min late").scaledFont(15).foregroundStyle(Theme.primary)
            }
            RefinedCard(severity: Theme.veryLate, action: {}) {
                Text(verbatim: "Canceled: rebook from the airline's app").scaledFont(15).foregroundStyle(Theme.primary)
            }
        }
        .padding(.horizontal, gutter)
    }

    static func sectionLabels(long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Upcoming")
            SectionLabel("Friends in the air", trailing: "3")
            SectionLabel(long ? "Flights to \(GalleryFixtures.longCity)" : "Past flights", trailing: "See All", action: {})
        }
        .padding(.horizontal, gutter)
    }

    static func sheetHeaders(long: Bool) -> some View {
        VStack(spacing: 12) {
            SheetHeader.root("My Flights") {
                Circle().fill(Theme.friend).frame(width: 36, height: 36)
            }
            SheetHeader.detail(overline: long ? GalleryFixtures.longAirportName : "Air France",
                               title: long ? "AF 84 to \(GalleryFixtures.longCity)" : "AF 84 to Paris",
                               onClose: {}) {
                Image(systemName: "airplane").scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
            }
            SheetHeader(.modal(title: "Settings", leading: .close({}), onDone: nil))
            SheetHeader(.modal(title: "Travel Documents", leading: .cancel({}), onDone: {}, doneDisabled: false))
            SheetHeader(.modal(title: "Profile", leading: .cancel({}), onDone: {}, doneDisabled: true))
        }
    }

    static var actionBar: some View {
        GlassActionBar([
            GlassActionItem("Share", systemImage: "square.and.arrow.up") {},
            GlassActionItem("Alerts", systemImage: "bell.fill", tint: Theme.accent) {},
            GlassActionItem("Seat", systemImage: "carseat.right") {},
            GlassActionItem("More", systemImage: "ellipsis") {},
        ])
    }

    static var mapControls: some View {
        HStack(alignment: .top, spacing: 24) {
            MapControlCapsule([
                MapControlItem("Map style", systemImage: "map") {},
                MapControlItem("My location", systemImage: "location.fill", isSelected: true) {},
            ])
            MapControlCapsule([
                MapControlItem("3D", glyph: "3D") {},
                MapControlItem("Map style", systemImage: "globe.americas.fill") {},
                MapControlItem("Follow", systemImage: "scope", isSelected: true) {},
            ])
        }
        .padding(.horizontal, gutter)
    }

    static func statusPills(long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusPill("Offline · positions estimated", systemImage: "wifi.slash")
            StatusPill("Refreshing", systemImage: "arrow.clockwise", tone: Theme.accentText)
            if long { StatusPill("Offline · last updated in \(GalleryFixtures.longCity)", systemImage: "wifi.slash") }
        }
        .padding(.horizontal, gutter)
    }

    // MARK: Errors and freshness

    static var errorBanners: some View {
        VStack(spacing: 12) {
            ErrorBanner(error: .providerUnavailable, retry: {})
            ErrorBanner(error: .unauthorized, retry: {}, signIn: {})
            ErrorBanner(error: .offline, hasContent: false, retry: {})
            ErrorBanner(error: .planLimit)
        }
        .padding(.horizontal, gutter)
    }

    static var offline: some View {
        VStack(alignment: .leading, spacing: 12) {
            OfflineBanner.Pill(retry: {}, fetchedAt: GalleryFixtures.now.addingTimeInterval(-4 * 60), now: GalleryFixtures.now)
            OfflineBanner.Pill(fetchedAt: nil, now: GalleryFixtures.now)
            OfflineBanner(OfflineBanner.text(hasContent: true), retry: {})
            OfflineBanner(OfflineBanner.text(hasContent: false))
        }
        .padding(.horizontal, gutter)
    }

    static var staleBadges: some View {
        let now = GalleryFixtures.now
        return VStack(alignment: .leading, spacing: 10) {
            StaleBadge(fetchedAt: now.addingTimeInterval(-4 * 60), ttl: .seconds(15 * 60), now: now, source: "FlightAware")
            StaleBadge(fetchedAt: now.addingTimeInterval(-3 * 3600), ttl: .seconds(15 * 60), now: now)
            StaleBadge(fetchedAt: now.addingTimeInterval(-90), ttl: .seconds(15 * 60), now: now, style: .badge)
            StaleBadge(fetchedAt: now.addingTimeInterval(-2 * 3600), ttl: .seconds(15 * 60), now: now, style: .badge)
        }
        .padding(.horizontal, gutter)
    }

    // MARK: Forms and buttons

    static func formFields(long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField("Passport number", text: .constant(""), prompt: "AB1234567", footnote: "As printed on the photo page.")
            FormField("Airline", text: .constant(long ? GalleryFixtures.longAirportName : "Air France"),
                      capitalization: .words)
            FormField("Redress number", text: .constant("12ab"), error: "Use digits only.", keyboard: .number)
        }
        .padding(.horizontal, gutter)
    }

    static var loadingButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Accept") {}.buttonStyle(LoadingButtonStyle(isLoading: false, variant: .tinted))
                Button("Accept") {}.buttonStyle(LoadingButtonStyle(isLoading: true, variant: .tinted))
            }
            HStack(spacing: 12) {
                Button("Send Code") {}.buttonStyle(LoadingButtonStyle(isLoading: false, variant: .filled))
                Button("Send Code") {}.buttonStyle(LoadingButtonStyle(isLoading: true, variant: .filled))
            }
            HStack(spacing: 12) {
                Button("Save") {}.buttonStyle(LoadingButtonStyle(isLoading: false, variant: .plain))
                Button("Save") {}.buttonStyle(LoadingButtonStyle(isLoading: true, variant: .plain))
            }
        }
        .padding(.horizontal, gutter)
    }

    // MARK: Rows (A13)

    /// Two seed flights; with `long`, the same flights between very long city names, one without its airline.
    static func myFlightRows(long: Bool) -> some View {
        let flights = Array(PreviewData.followed.prefix(2))
        let rows: [GalleryRow] = flights.enumerated().map { index, f in
            let airport: (String) -> Airport? = { long ? GalleryFixtures.longAirport($0) : PreviewData.airport($0) }
            return GalleryRow(flight: f, origin: airport(f.originIcao), destination: airport(f.destinationIcao),
                              airline: long && index == 1 ? nil : GalleryFixtures.airline(for: f))
        }
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                MyFlightRow(flight: row.flight, origin: row.origin, destination: row.destination, airline: row.airline,
                            now: GalleryFixtures.now)
            }
        }
        .padding(.horizontal, gutter)
    }

    /// Departures from the seed board; with `long`, a destination with a very long city and a flight with no
    /// airline or city at all.
    static func boardRows(long: Bool) -> some View {
        let board = PreviewData.board("KAUS", .departures).flights
        let tz = PreviewData.kaus.timeZone
        let rows: [GalleryRow] = board[2..<5].enumerated().map { i, f in
            let normal = PreviewData.airport(f.destinationIcao)
            return GalleryRow(flight: f, destination: long && i == 0 ? GalleryFixtures.longAirport(f.destinationIcao) ?? normal : normal,
                              striped: !i.isMultiple(of: 2))
        }
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                BoardRow(flight: row.flight, kind: .departures, airport: row.destination, timeZone: tz,
                         now: GalleryFixtures.now, striped: row.striped)
            }
            if long {
                BoardRow(flight: PreviewData.sparse, kind: .departures, airport: nil, timeZone: tz,
                         now: GalleryFixtures.now, striped: true)
            }
        }
    }

    /// A friend in the list; with `long`, one whose name is only emoji, flying to a very long city.
    static func friendRows(long: Bool) -> some View {
        let next = PreviewData.followed[1]
        let lookup: (String) -> Airport? = { long ? GalleryFixtures.longAirport($0) : PreviewData.airport($0) }
        return VStack(spacing: 0) {
            FriendRow(friend: long ? GalleryFixtures.emojiFriend : GalleryFixtures.plainFriend, next: next,
                      lookup: lookup, now: GalleryFixtures.now)
            FriendRow(friend: GalleryFixtures.plainFriend, next: nil, now: GalleryFixtures.now)
        }
        .padding(.horizontal, gutter)
    }
}

#Preview("Component gallery") {
    ComponentGallery()
}
#endif
