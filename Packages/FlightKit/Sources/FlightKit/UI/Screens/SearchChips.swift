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
        guard FlightActivityDisplay.uiLocale.language.languageCode?.identifier != "en" else {
            return dayFormatter.string(from: date)
        }
        var style = Date.FormatStyle(locale: FlightActivityDisplay.uiLocale, timeZone: .gmt)
        style = style.weekday(.abbreviated).day().month(.abbreviated)
        return date.formatted(style)  // "ven. 7 nov." in French
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

/// A whole query in one line: "Los Angeles → Tokyo · Wed Nov 4 · 18:00", "AF 84 · Mon Nov 2".
enum SearchSummary {
    static func text(_ intent: SearchIntent, clock: TimeStyle) -> String {
        var parts: [String] = []
        if let ident = intent.ident {
            parts.append(Format.ident(ident))
        } else if let airline = intent.airline {
            parts.append(airline.name)
        }
        let places = intent.chips.compactMap { if case .place(let a) = $0 { a.first?.city } else { nil } }
        if !places.isEmpty { parts.append(places.joined(separator: " \u{2192} ")) }
        if let day = intent.day { parts.append(SearchChipText.day(day)) }
        if let t = intent.timeOfDay { parts.append(SearchChipText.time(t, clock: clock)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The day the calendar picks, written into the field as if typed.
enum SearchDayText {
    /// `text` with its date words replaced by `day` ("20 dec"), or taken out when `day` is nil.
    static func setting(_ day: LocalDay?, in text: String, intent: SearchIntent) -> String {
        var t = text
        if let old = intent.day { t = intent.removing(.day(old), from: t) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard let day else { return t }
        return SearchStart.appending(word(day), to: t)
    }

    /// "20 dec": a day and a short month, which every reading of the field takes the same way.
    static func word(_ day: LocalDay) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        guard let date = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else {
            return day.description
        }
        return formatter.string(from: date).lowercased()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "d MMM"
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
    /// The calendar button, first in the row; nil leaves it out.
    var day: SearchDayButton?
    var onRemove: (SearchIntent.Chip) -> Void
    @Environment(\.units) private var units

    init(chips: [SearchIntent.Chip], note: String?, day: SearchDayButton? = nil,
         onRemove: @escaping (SearchIntent.Chip) -> Void) {
        self.chips = chips; self.note = note; self.day = day; self.onRemove = onRemove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chips.isEmpty || day != nil {
                ChipFlow(spacing: 8) {
                    if let day { day }
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
