import SwiftUI

/// One line of the detailed timetable: the schedule beside the best other time (actual, else estimated).
struct TimetableRow: Hashable, Sendable {
    enum Section: String, Hashable, Sendable { case depart, arrive, totals }
    var section: Section
    var title: String
    var scheduled: String
    var other: String
    /// "Actual" when every time behind `other` happened, else "Estimated".
    var otherLabel: String
    /// How late the other time runs against the schedule; nil for spans and unknown times.
    var level: DelayLevel?
}

/// The detailed timetable: gate and runway times on both ends, the taxi spans between them, and the
/// air and total times. Gate and runway times read in their airport's zone.
enum Timetable {
    static let title = "Detailed Timetable"
    static let subtitle = "Scheduled, estimated and actual times"
    static let unknown = "--"

    /// One known time, and whether it happened (actual) or is planned (estimated).
    private struct Point { var date: Date; var actual: Bool }

    private static func best(actual: Date?, estimated: Date?) -> Point? {
        if let actual { return Point(date: actual, actual: true) }
        return estimated.map { Point(date: $0, actual: false) }
    }

    static func rows(_ f: Flight, originTz: TimeZone = .gmt, destinationTz: TimeZone = .gmt,
                     clock: TimeStyle = .h24) -> [TimetableRow] {
        let out = best(actual: f.actualOut, estimated: f.estimatedOut)
        let off = best(actual: f.actualOff, estimated: f.estimatedOff)
        let on = best(actual: f.actualOn, estimated: f.estimatedOn)
        let inn = best(actual: f.actualIn, estimated: f.estimatedIn)

        func time(_ section: TimetableRow.Section, _ title: String, _ scheduled: Date?, _ other: Point?,
                  _ tz: TimeZone) -> TimetableRow {
            let level = scheduled.flatMap { s in
                other.map { DelayLevel.for(delay: .seconds($0.date.timeIntervalSince(s)), status: .scheduled) }
            }
            return TimetableRow(section: section, title: title,
                                scheduled: scheduled.map { Format.clock($0, tz, clock) } ?? unknown,
                                other: other.map { Format.clock($0.date, tz, clock) } ?? unknown,
                                otherLabel: other?.actual == true ? "Actual" : "Estimated", level: level)
        }
        func span(_ section: TimetableRow.Section, _ title: String, scheduled: (Date?, Date?),
                  other: (Point?, Point?)) -> TimetableRow {
            let s = minutes(scheduled.0, scheduled.1)
            let o = minutes(other.0?.date, other.1?.date)
            let actual = other.0?.actual == true && other.1?.actual == true
            return TimetableRow(section: section, title: title, scheduled: s.map(DetailFacts.span(minutes:)) ?? unknown,
                                other: o.map(DetailFacts.span(minutes:)) ?? unknown,
                                otherLabel: actual ? "Actual" : "Estimated", level: nil)
        }

        return [
            time(.depart, "Gate Departure", f.scheduledOut, out, originTz),
            span(.depart, "Taxi", scheduled: (f.scheduledOut, f.scheduledOff), other: (out, off)),
            time(.depart, "Take Off", f.scheduledOff, off, originTz),
            time(.arrive, "Land", f.scheduledOn, on, destinationTz),
            span(.arrive, "Taxi", scheduled: (f.scheduledOn, f.scheduledIn), other: (on, inn)),
            time(.arrive, "Gate Arrival", f.scheduledIn, inn, destinationTz),
            span(.totals, "Air Time", scheduled: (f.scheduledOff, f.scheduledOn), other: (off, on)),
            span(.totals, "Total Time", scheduled: (f.scheduledOut, f.scheduledIn), other: (out, inn)),
        ]
    }

    /// Whole minutes from `a` to `b`; nil when either is unknown or the order is wrong.
    private static func minutes(_ a: Date?, _ b: Date?) -> Int? {
        guard let a, let b, b >= a else { return nil }
        return Int((b.timeIntervalSince(a) / 60).rounded())
    }
}

/// The timetable card: DEPART, ARRIVE and TOTALS groups, each row with the schedule and the other time.
struct TimetableCard: View {
    var rows: [TimetableRow]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        DetailCard(padded: false) {
            CardTitle(Timetable.title, subtitle: Timetable.subtitle)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 20)
                .scaledPadding(.bottom, 8)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Hairline() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: UIText.localized(group.section.rawValue).uppercased())
                        .scaledFont(14, weight: .medium)
                        .foregroundStyle(Theme.secondary.opacity(0.7))
                        .scaledPadding(.top, 16)
                        .scaledPadding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        line(row)
                    }
                }
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.bottom, 10)
            }
        }
    }

    private var groups: [(section: TimetableRow.Section, rows: [TimetableRow])] {
        [TimetableRow.Section.depart, .arrive, .totals].map { s in (s, rows.filter { $0.section == s }) }
            .filter { !$0.rows.isEmpty }
    }

    @ViewBuilder private func line(_ row: TimetableRow) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Text(ui: row.title)
                .scaledFont(17)
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                cell("Scheduled", row.scheduled, color: row.scheduled == Timetable.unknown ? Theme.secondary : Theme.primary)
                cell(row.otherLabel, row.other, color: row.level?.color ?? (row.other == Timetable.unknown ? Theme.secondary : Theme.primary))
            }
        }
        .scaledPadding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue("Scheduled \(row.scheduled), \(row.otherLabel.lowercased()) \(row.other)")
    }

    private func cell(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui: label).scaledFont(15).foregroundStyle(Theme.secondary)
            Text(ui: value).scaledFont(19).monospacedDigit().foregroundStyle(color)
        }
        .frame(minWidth: 82, alignment: .leading)
    }
}
