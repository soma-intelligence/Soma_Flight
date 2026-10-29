import SwiftUI

// MARK: - Units

public enum DistanceUnit: String, Sendable, Hashable, CaseIterable {
    case km, mi
}

/// Display units chosen in Settings. The shells keep them (Task 12 stores them in `@AppStorage`)
/// and hand them down through the environment.
public struct Units: Sendable, Hashable {
    public var distance: DistanceUnit
    public var clock: TimeStyle

    public init(distance: DistanceUnit = .km, clock: TimeStyle = .h24) {
        self.distance = distance; self.clock = clock
    }
}

public extension EnvironmentValues {
    @Entry var units = Units()
}

// MARK: - Titles and labels

/// Large bold sheet title ("My Flights", "Passport"), with an optional grey line under it.
/// The trailing 60 pt stay free for the shell's buttons.
struct ScreenTitle: View {
    var title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title; self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(32, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).scaledFont(17).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.trailing, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small grey capitals over a group of rows ("RECENT SEARCHES").
struct CapsHeader: View {
    var text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text; self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text.uppercased())
            Spacer()
            if let trailing { Text(trailing.uppercased()) }
        }
        .scaledFont(13)
        .foregroundStyle(Theme.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Monospaced code in a small outlined box ("CDG", "LFPG", "AF 84").
struct CodeChip: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Font.chip)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.grid, lineWidth: 1))
    }
}

/// Full-width hairline.
struct Hairline: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, leading)
    }
}

/// Grey chevron at the end of a navigating row.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .scaledFont(14, weight: .semibold)
            .foregroundStyle(Theme.secondary.opacity(0.7))
            .accessibilityHidden(true)
    }
}

// MARK: - Pages

/// A screen body that scrolls in the app and lays out flat for snapshots (ImageRenderer cannot
/// draw a ScrollView's content).
struct ScreenScroll<Content: View>: View {
    var scrolls: Bool
    /// Pull to refresh; nil leaves the scroll view without it.
    var refresh: (() async -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            if let refresh {
                ScrollView { content }.refreshable { await refresh() }
            } else {
                ScrollView { content }
            }
        } else {
            VStack(spacing: 0) { content; Spacer(minLength: 0) }
        }
    }
}

/// Follows the clock each minute, or stays at `fixed` (previews and snapshots).
struct ClockView<Content: View>: View {
    var fixed: Date?
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let fixed {
            content(fixed)
        } else {
            TimelineView(.everyMinute) { content($0.date) }
        }
    }
}

// MARK: - Formatting shared by the screens

enum ScreenFormat {
    /// "Paris to San Francisco" with codes as fallback.
    static func route(_ from: String, _ to: String) -> String { "\(from) to \(to)" }

    /// Hours and minutes until or since `date`: "2h 14m". Under a minute reads `floor` ("under a minute")
    /// instead of "0m".
    static func span(_ seconds: TimeInterval, floor: String = "0m") -> String {
        let m = Int((abs(seconds) / 60).rounded())
        return m < 1 ? floor : Format.minutes(m)
    }

    /// "Apr 25, 2026" in `tz`, worded for the user's locale.
    static func day(_ date: Date, _ tz: TimeZone) -> String {
        var style = mediumDay
        style.timeZone = tz
        return date.formatted(style)
    }

    /// "Fri, Oct 23" in `tz`.
    static func chipDay(_ date: Date, _ tz: TimeZone) -> String {
        var style = shortDay
        style.timeZone = tz
        return date.formatted(style)
    }

    private static let mediumDay = Date.FormatStyle(locale: .autoupdatingCurrent).month(.abbreviated).day().year()
    private static let shortDay = Date.FormatStyle(locale: .autoupdatingCurrent).weekday(.abbreviated).month(.abbreviated).day()
}

#if DEBUG
// MARK: - Preview and snapshot support

/// A fixed offline copy for previews: the seed's flights and history, saved `age` seconds
/// before the seed's now.
actor PreviewCache: FlightListCache, PastFlightCache {
    private var savedFlights: [Flight]
    private var savedPast: [PastFlight]
    private let savedAt: Date

    init(age: TimeInterval = 3 * 3600) {
        savedFlights = PreviewData.followed
        savedPast = FakeSeed.load("past_flights")
        savedAt = PreviewData.now.addingTimeInterval(-age)
    }

    func save(flights: [Flight]) { savedFlights = flights }
    func flights() -> [Flight] { savedFlights }
    func flightsSavedAt() -> Date? { savedAt }
    func save(past: [PastFlight]) { savedPast = past }
    func past() -> [PastFlight] { savedPast }
    func pastSavedAt() -> Date? { savedAt }
}

/// Cache that remembers nothing, so a failed load stays empty.
actor EmptyPreviewCache: FlightListCache, PastFlightCache {
    func save(flights: [Flight]) {}
    func flights() -> [Flight] { [] }
    func save(past: [PastFlight]) {}
    func past() -> [PastFlight] { [] }
    func pastSavedAt() -> Date? { nil }
}
#endif
