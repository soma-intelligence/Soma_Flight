import FlightWatchKit
import SwiftUI

/// My Flights on the wrist: one row per flight, in the air first, then by departure. Each row has the
/// number, the route, the countdown or status and the leading time in its colour, as on the phone.
struct FlightListView: View {
    let model: WatchFlightsModel

    var body: some View {
        // Redrawn each minute: the countdowns and the progress follow the clock between snapshots.
        TimelineView(.everyMinute) { context in
            let rows = model.rows(at: context.date)
            List {
                if rows.isEmpty {
                    WatchEmptyView(synced: model.hasSynced)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(rows, id: \.flight.id) { row in
                        NavigationLink(value: row.flight.id) {
                            FlightRow(display: row)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ActivityPalette.background))
                    }
                }
                if let updated = model.updatedText(at: context.date) {
                    Text(updated)
                        .font(.footnote)
                        .foregroundStyle(ActivityPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("My Flights")
        .navigationDestination(for: UUID.self) { id in
            WatchFlightScreen(model: model, id: id)
        }
    }
}

/// One flight in the list.
struct FlightRow: View {
    let display: FlightWidgetDisplay

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(ActivityPalette.color(display.level)).frame(width: 7, height: 7)
                    Text(display.ident)
                        .font(.headline)
                        .foregroundStyle(ActivityPalette.primary)
                }
                Text(display.routeCodes)
                    .font(.subheadline)
                    .foregroundStyle(ActivityPalette.secondary)
                Text(display.headlineTime)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(WatchTone.color(display.headlineTone))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            WatchCountdown(display: display)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

/// The countdown column: a figure over its unit, or a word alone in its colour.
struct WatchCountdown: View {
    let display: FlightWidgetDisplay

    var body: some View {
        let c = display.countdown
        VStack(alignment: .trailing, spacing: 0) {
            if !c.value.isEmpty {
                Text(c.value)
                    .font(.system(.title2, design: .default, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ActivityPalette.primary)
            }
            Text(c.unit)
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(c.value.isEmpty ? WatchTone.unitColor(display.flight.status) : ActivityPalette.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Nothing to list: before the first sync, or nothing followed.
struct WatchEmptyView: View {
    let synced: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: synced ? "airplane.departure" : "iphone")
                .font(.title2)
                .foregroundStyle(ActivityPalette.secondary)
                .accessibilityHidden(true)
            Text(synced ? "No upcoming flights" : "Waiting for iPhone")
                .font(.headline)
            Text(synced ? "Follow a flight in Soma Flight on your iPhone to see it here."
                        : "Open Soma Flight on your iPhone to bring your flights to your watch.")
                .font(.footnote)
                .foregroundStyle(ActivityPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// The flight sheet's colours for a time and for a countdown word.
enum WatchTone {
    /// Late in red, early or on time in green, white while only the schedule is known.
    static func color(_ tone: FlightWidgetDisplay.Tone) -> Color {
        switch tone {
        case .neutral: ActivityPalette.primary
        case .onTime: ActivityPalette.onTime
        case .late: ActivityPalette.veryLate
        }
    }

    /// Red for canceled, purple for diverted, else grey, as in My Flights.
    static func unitColor(_ status: FlightStatus) -> Color {
        switch status {
        case .canceled: ActivityPalette.veryLate
        case .diverted: ActivityPalette.diverted
        default: ActivityPalette.secondary
        }
    }
}

#Preview("My Flights") {
    let model = WatchFlightsModel(defaults: UserDefaults(suiteName: "preview")!)
    model.receive(WatchSnapshot(flights: .preview()))
    return NavigationStack { FlightListView(model: model) }
}

#Preview("Empty") {
    NavigationStack { FlightListView(model: WatchFlightsModel(defaults: UserDefaults(suiteName: "preview.empty")!)) }
}
