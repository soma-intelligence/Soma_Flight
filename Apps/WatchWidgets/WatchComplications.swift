import FlightWatchKit
import SwiftUI
import WidgetKit

/// The watch's complications and Smart Stack widget: the next followed flight, from the snapshot the watch
/// app keeps in its App Group (never the network).
@main
struct SomaFlightComplications: WidgetBundle {
    var body: some Widget {
        NextFlightComplication()
    }
}

/// One moment of the timeline: the watch's snapshot drawn at `date`, with its Smart Stack score.
struct ComplicationEntry: TimelineEntry {
    var date: Date
    var snapshot: WatchSnapshot?
    var relevance: TimelineEntryRelevance?

    var next: FlightWidgetDisplay? {
        guard let snapshot, let f = snapshot.flights.flights(at: date).first else { return nil }
        return FlightWidgetDisplay(f, at: date, twelveHour: snapshot.twelveHour)
    }
}

/// Reads the snapshot the watch app saved and plans an entry at each moment the display or the relevance
/// changes (`WatchComplicationTimeline`). The watch app reloads the timelines when a new snapshot comes.
struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, snapshot: .preview())
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        let saved = WatchSnapshotStore.load()
        // The gallery shows a sample flight when nothing is followed yet.
        let empty = saved.map { $0.flights.flights(at: .now).isEmpty } ?? true
        completion(ComplicationEntry(date: .now, snapshot: context.isPreview && empty ? .preview() : saved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let snapshot = WatchSnapshotStore.load()
        let plan = WatchComplicationTimeline.plan(for: snapshot, now: .now)
        let entries = plan.entries.map {
            ComplicationEntry(date: $0.date, snapshot: snapshot,
                              relevance: TimelineEntryRelevance(score: $0.score, duration: $0.duration))
        }
        completion(Timeline(entries: entries, policy: plan.reload.map { .after($0) } ?? .never))
    }
}

/// Next Flight on the watch face: rectangular (number, route, status), circular (countdown or progress
/// ring), corner and inline. A tap opens the flight in the watch app.
struct NextFlightComplication: Widget {
    static let kind = "NextFlightWatch"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .widgetURL(entry.next.map { FlightLink.url(for: $0.flight.id) })
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Next Flight")
        .description("Your next flight: countdown, status and gate.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ComplicationEntry

    var body: some View {
        if let next = entry.next {
            switch family {
            case .accessoryRectangular: NextFlightRectangularView(next)
            case .accessoryCircular: NextFlightCircularView(next)
            case .accessoryCorner: NextFlightCornerView(display: next)
            default: NextFlightInlineView(next)
            }
        } else {
            switch family {
            case .accessoryRectangular: FlightWidgetEmptyView(.rectangular)
            case .accessoryCircular: FlightWidgetEmptyView(.circular)
            case .accessoryCorner:
                Image(systemName: "airplane")
                    .font(.system(size: 20, weight: .semibold))
                    .widgetAccentable()
                    .widgetLabel("No flights")
            default: FlightWidgetEmptyView(.inline)
            }
        }
    }
}

/// Corner: the plane (or the countdown) in the corner, the progress along the bezel while in the air, else
/// the number and the time that leads.
struct NextFlightCornerView: View {
    let display: FlightWidgetDisplay

    var body: some View {
        Group {
            if display.isAirborne {
                Image(systemName: "airplane")
                    .font(.system(size: 20, weight: .semibold))
                    .widgetAccentable()
                    .widgetLabel {
                        Gauge(value: display.progress) {
                            Text(display.ident)
                        } currentValueLabel: {
                            Text(display.flight.destination.code)
                        } minimumValueLabel: {
                            Text(display.flight.origin.code)
                        } maximumValueLabel: {
                            Text(display.flight.destination.code)
                        }
                    }
            } else {
                Text(display.shortCountdown ?? display.flight.origin.code)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                    .widgetLabel("\(display.ident) · \(display.headlineTime)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NextFlightComplication()
} timeline: {
    ComplicationEntry(date: .now, snapshot: .preview())
    ComplicationEntry(date: .now, snapshot: nil)
}

#Preview("Circular", as: .accessoryCircular) {
    NextFlightComplication()
} timeline: {
    ComplicationEntry(date: .now, snapshot: .preview())
    ComplicationEntry(date: .now.addingTimeInterval(5 * 3600), snapshot: .preview())
}

#Preview("Corner", as: .accessoryCorner) {
    NextFlightComplication()
} timeline: {
    ComplicationEntry(date: .now, snapshot: .preview())
}

#Preview("Inline", as: .accessoryInline) {
    NextFlightComplication()
} timeline: {
    ComplicationEntry(date: .now, snapshot: .preview())
}
