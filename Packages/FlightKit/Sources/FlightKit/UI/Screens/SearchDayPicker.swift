import FlightImportKit
import SwiftUI

/// The day the search looks at, first under the field: "Today" until the text names a day. A tap opens
/// the calendar.
struct SearchDayButton: View {
    var day: LocalDay?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .scaledFont(13, weight: .semibold)
                    .accessibilityHidden(true)
                Text(ui: Self.title(day))
                    .scaledFont(15, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundStyle(day == nil ? Theme.primary : Theme.accent)
            .scaledPadding(.horizontal, 12)
            .scaledPadding(.vertical, 6)
            .background(Capsule().fill(Theme.pill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Date, \(Self.title(day))")
        .accessibilityHint("Opens the calendar")
    }

    /// "Today" when the text names no day, else "Fri Nov 7".
    static func title(_ day: LocalDay?) -> String {
        day.map(SearchChipText.day) ?? "Today"
    }
}

/// A month calendar to pick the search's day, with Today, Tomorrow and This weekend on top. Days past
/// the schedules' reach (`DateWords.maxDaysAhead`) are out of range. Picking closes the sheet; Today
/// takes the day out of the text (the search looks at today by default).
struct SearchDaySheet: View {
    var selected: LocalDay?
    var today: LocalDay
    var onPick: (LocalDay?) -> Void

    @State private var date: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // No title row: the drag indicator and a swipe close it, and the calendar fits the medium detent.
            HStack(spacing: 8) {
                ForEach(Self.shortcuts(today: today), id: \.title) { s in
                    SearchChip(title: s.title) { onPick(s.day) }
                }
            }
            DatePicker("Date", selection: $date, in: Self.range(today: today), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.top, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { date = Self.date(selected ?? today) }
        .onChange(of: date) { _, d in
            let day = LocalDay(d, in: .current)
            guard day != (selected ?? today) else { return }
            onPick(day == today ? nil : day)
        }
    }

    struct Shortcut { var title: String; var day: LocalDay? }

    /// Today (no day in the text), Tomorrow, and the coming weekend's Saturday (today on a weekend).
    static func shortcuts(today: LocalDay) -> [Shortcut] {
        let date = Self.date(today)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let weekday = cal.component(.weekday, from: date)
        let toWeekend = weekday == 1 || weekday == 7 ? 0 : 7 - weekday
        func plus(_ n: Int) -> LocalDay? {
            cal.date(byAdding: .day, value: n, to: date).map { LocalDay($0, in: .current) }
        }
        return [Shortcut(title: "Today", day: nil), Shortcut(title: "Tomorrow", day: plus(1)),
                Shortcut(title: "This weekend", day: toWeekend == 0 ? nil : plus(toWeekend))]
    }

    /// Today through the schedules' reach.
    static func range(today: LocalDay) -> ClosedRange<Date> {
        let start = Self.date(today)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let end = cal.date(byAdding: .day, value: DateWords.maxDaysAhead, to: start) ?? start
        return cal.startOfDay(for: start)...end
    }

    /// Noon of `day` on this device.
    static func date(_ day: LocalDay) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? .now
    }
}
