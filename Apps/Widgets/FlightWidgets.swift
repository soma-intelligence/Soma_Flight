import FlightActivityKit
import SwiftUI
import WidgetKit

/// One moment of a flight widget's timeline: the snapshot the app last wrote, drawn at `date`.
struct FlightWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var twelveHour: Bool

    /// The flights to show at `date`, as the widgets list them.
    var displays: [FlightWidgetDisplay] {
        snapshot.flights(at: date).map { FlightWidgetDisplay($0, at: date, twelveHour: twelveHour) }
    }

    var next: FlightWidgetDisplay? { displays.first }
}

/// Reads the snapshot from the App Group (never the network) and plans an entry at each moment the
/// display changes (`WidgetTimeline`). The app reloads the timelines whenever it writes a new snapshot.
struct FlightTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FlightWidgetEntry {
        FlightWidgetEntry(date: .now, snapshot: .preview(), twelveHour: SharedSettings.twelveHour())
    }

    func getSnapshot(in context: Context, completion: @escaping (FlightWidgetEntry) -> Void) {
        // The gallery shows sample flights when nothing is followed yet.
        let saved = WidgetSnapshotStore.load()
        let snapshot = context.isPreview && saved.flights(at: .now).isEmpty ? .preview() : saved
        completion(FlightWidgetEntry(date: .now, snapshot: snapshot, twelveHour: SharedSettings.twelveHour()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FlightWidgetEntry>) -> Void) {
        let now = Date.now
        let snapshot = WidgetSnapshotStore.load()
        let twelveHour = SharedSettings.twelveHour()
        let dates = WidgetTimeline.entryDates(for: snapshot, now: now)
        let entries = dates.map { FlightWidgetEntry(date: $0, snapshot: snapshot, twelveHour: twelveHour) }
        let policy: TimelineReloadPolicy = WidgetTimeline.reloadDate(for: snapshot, entries: dates, now: now)
            .map { .after($0) } ?? .never
        completion(Timeline(entries: entries, policy: policy))
    }
}

// MARK: - Next Flight

/// The next followed flight, on the home screen (small, medium) and the lock screen (rectangular,
/// circular, inline). A tap opens it in the app.
struct NextFlightWidget: Widget {
    static let kind = "NextFlight"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FlightTimelineProvider()) { entry in
            NextFlightEntryView(entry: entry)
        }
        .configurationDisplayName("Next Flight")
        .description("Your next flight: countdown, times, gate and status.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NextFlightEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FlightWidgetEntry

    var body: some View {
        content
            .widgetURL(entry.next.map { FlightLink.url(for: $0.flight.id) })
            .containerBackground(for: .widget) {
                if family.isAccessory { AccessoryWidgetBackground().opacity(0) } else { ActivityPalette.background }
            }
    }

    @ViewBuilder private var content: some View {
        if let next = entry.next {
            switch family {
            case .systemMedium: NextFlightMediumView(next)
            case .accessoryRectangular: NextFlightRectangularView(next)
            case .accessoryCircular: NextFlightCircularView(next)
            case .accessoryInline: NextFlightInlineView(next)
            default: NextFlightSmallView(next)
            }
        } else {
            FlightWidgetEmptyView(family.emptySize)
        }
    }
}

// MARK: - Upcoming Flights

/// The next three to four followed flights on the home screen, as rows like My Flights. Each row opens
/// its flight.
struct UpcomingFlightsWidget: Widget {
    static let kind = "UpcomingFlights"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FlightTimelineProvider()) { entry in
            Group {
                if entry.displays.isEmpty {
                    FlightWidgetEmptyView(.large)
                } else {
                    UpcomingFlightsLargeView(entry.displays)
                }
            }
            .containerBackground(ActivityPalette.background, for: .widget)
        }
        .configurationDisplayName("Upcoming Flights")
        .description("Your next flights at a glance.")
        .supportedFamilies([.systemLarge])
    }
}

private extension WidgetFamily {
    var isAccessory: Bool { [.accessoryRectangular, .accessoryCircular, .accessoryInline].contains(self) }

    var emptySize: FlightWidgetEmptyView.Size {
        switch self {
        case .systemMedium: .medium
        case .systemLarge: .large
        case .accessoryRectangular: .rectangular
        case .accessoryCircular: .circular
        case .accessoryInline: .inline
        default: .small
        }
    }
}

// MARK: - Previews

private extension FlightWidgetEntry {
    static let previewNow = Date.now
    static let flights = FlightWidgetEntry(date: previewNow, snapshot: .preview(now: previewNow), twelveHour: false)
    /// The same flights with UA 1527 first: before take-off, 25 minutes late from gate F11.
    static let beforeDeparture: FlightWidgetEntry = {
        var s = WidgetSnapshot.preview(now: previewNow)
        s.flights.removeFirst()
        return FlightWidgetEntry(date: previewNow, snapshot: s, twelveHour: false)
    }()
    static let empty = FlightWidgetEntry(date: previewNow, snapshot: .empty(at: previewNow), twelveHour: false)
}

#Preview("Small", as: .systemSmall) {
    NextFlightWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.beforeDeparture
    FlightWidgetEntry.empty
}

#Preview("Medium", as: .systemMedium) {
    NextFlightWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.beforeDeparture
    FlightWidgetEntry.empty
}

#Preview("Large", as: .systemLarge) {
    UpcomingFlightsWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.empty
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NextFlightWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.beforeDeparture
    FlightWidgetEntry.empty
}

#Preview("Circular", as: .accessoryCircular) {
    NextFlightWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.beforeDeparture
    FlightWidgetEntry.empty
}

#Preview("Inline", as: .accessoryInline) {
    NextFlightWidget()
} timeline: {
    FlightWidgetEntry.flights
    FlightWidgetEntry.beforeDeparture
    FlightWidgetEntry.empty
}
