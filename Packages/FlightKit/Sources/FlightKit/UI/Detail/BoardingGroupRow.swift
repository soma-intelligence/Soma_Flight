import SwiftUI

// MARK: - Wording

/// The words of the boarding group row under the boarding pass. No SwiftUI here, so the tests read the
/// exact text.
enum BoardingGroupFacts {
    /// "Group 5, about 14:12".
    static func title(_ e: BoardingGroupTiming.Estimate, tz: TimeZone, clock: TimeStyle) -> String {
        "\(e.group.title), about \(Format.clock(e.calledAt, tz, clock))"
    }

    /// What the time rests on, and where boarding stands.
    static func caption(_ e: BoardingGroupTiming.Estimate, tz: TimeZone, clock: TimeStyle) -> String {
        switch e.phase {
        case .beforeBoarding:
            let start = Format.clock(e.boardingStarts, tz, clock)
            return e.fromPass ? "Approximate. Boarding starts at \(start) on your pass."
                : "Approximate. Boarding usually starts about \(start)."
        case .boarding:
            return "Approximate. Boarding has started, your group comes later."
        case .called:
            return "Approximate. Your group is likely being called now."
        }
    }
}

// MARK: - Row

/// Under the boarding pass: about when the traveller's group is called, from the group on the pass and
/// the boarding start (`BoardingGroupTiming`). Hidden without a group, and once the plane has left.
struct BoardingGroupRow: View {
    var estimate: BoardingGroupTiming.Estimate
    var timeZone: TimeZone
    @Environment(\.units) private var units

    var body: some View {
        DetailCard {
            InfoRow(symbol: "person.3.sequence.fill",
                    title: BoardingGroupFacts.title(estimate, tz: timeZone, clock: units.clock),
                    text: BoardingGroupFacts.caption(estimate, tz: timeZone, clock: units.clock))
        }
        .id("boardingGroup")
    }
}
