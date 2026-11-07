import FlightImportKit
import SwiftUI

extension UpcomingFlight {
    /// The flight a planned search row adds. Its day is read in the origin's zone (`tz`), so a late
    /// departure keeps the day printed on the ticket.
    public init(_ f: ScheduledFlight, tz: TimeZone) {
        self.init(ident: f.ident, day: LocalDay(f.scheduledOut, in: tz), origin: f.origin, destination: f.destination,
                  departure: f.scheduledOut)
    }
}

/// How the screen names each piece the search read: "Air France", "Paris (CDG, ORY)", "Fri Nov 7", "Evening".
enum SearchChipText {
    static func label(_ chip: SearchIntent.Chip, clock: TimeStyle) -> String {
        switch chip {
        case .ident(let i): Format.ident(i)
        case .airline(let a): a.name
        case .place(let airports): place(airports)
        case .day(let d): day(d)
        case .time(let m): time(m, clock: clock)
        }
    }

    /// The first airport's city and every airport's code.
    static func place(_ airports: [Airport]) -> String {
        guard let first = airports.first else { return "" }
        return "\(first.city) (\(airports.map { $0.iata ?? $0.id }.joined(separator: ", ")))"
    }

    /// "Fri Nov 7".
    static func day(_ d: LocalDay) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        guard let date = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12)) else {
            return d.description
        }
        return dayFormatter.string(from: date)
    }

    /// The named times of day by their words, any other minute as a clock time in the user's style.
    static func time(_ minutes: Int, clock: TimeStyle) -> String {
        if let name = namedTimes[minutes] { return name }
        return Format.clock(Date(timeIntervalSince1970: TimeInterval(minutes * 60)), .gmt, clock)
    }

    private static let namedTimes = [480: "Morning", 720: "Midday", 900: "Afternoon", 1140: "Evening", 1320: "Night"]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = .gmt
        f.dateFormat = "EEE MMM d"
        return f
    }()
}

/// What the empty field offers: day shortcuts, then the frequently used airlines and airports.
struct SearchStart: Equatable {
    /// A chip that adds a day word to the field.
    struct DayShortcut: Hashable {
        var title: String
        var word: String
    }

    var days: [DayShortcut] = [.init(title: "Today", word: "today"), .init(title: "Tomorrow", word: "tomorrow")]
    var frequent: [FrequentItem]

    init(frequent: [FrequentItem]) { self.frequent = frequent }

    /// `word` after the typed text, one space between.
    static func appending(_ word: String, to text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? word : "\(t) \(word)"
    }
}

/// A capsule in `Theme.pill` that acts on a tap anywhere on it: a shortcut, or a piece of the search
/// that a tap removes (its small x is only the cue).
struct SearchChip: View {
    var title: String
    var removes = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(ui: title)
                    .scaledFont(15, weight: .medium)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if removes {
                    Image(systemName: "xmark")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                }
            }
            .scaledPadding(.horizontal, 12)
            .scaledPadding(.vertical, 6)
            .background(Capsule().fill(Theme.pill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(title, removes: removes))
    }

    /// "Remove Air France" for a piece of the search, the title alone for a shortcut.
    static func accessibilityLabel(_ title: String, removes: Bool) -> String {
        removes ? "Remove \(title)" : title
    }
}

/// The pieces the search read, under the field, each with an x that takes its words out of the text,
/// then the store's note.
struct SearchChipsRow: View {
    var chips: [SearchIntent.Chip]
    var note: String?
    var onRemove: (SearchIntent.Chip) -> Void
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chips.isEmpty {
                ChipFlow(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        SearchChip(title: SearchChipText.label(chip, clock: units.clock), removes: true) { onRemove(chip) }
                            .transition(.opacity)
                    }
                }
            }
            if let note {
                Text(ui: note)
                    .scaledFont(13)
                    .foregroundStyle(Theme.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: chips)
        .animation(.easeOut(duration: 0.15), value: note)
    }
}
