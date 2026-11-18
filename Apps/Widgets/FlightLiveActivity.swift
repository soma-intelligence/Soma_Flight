import ActivityKit
import FlightActivityKit
import SwiftUI
import WidgetKit

/// The flight Live Activity. The views live in FlightActivityKit, shared with the snapshot tests; this
/// only places them on the lock screen and in the Dynamic Island.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            // `isStale`: no news since the content's stale date (20 minutes while the flight moves), so
            // the card greys and says the times may be old instead of looking live.
            FlightActivityLockScreenView(FlightActivityDisplay(context.attributes, context.state,
                                                               twelveHour: SharedSettings.twelveHour(), now: .now,
                                                               isStale: context.isStale))
                .activityBackgroundTint(ActivityPalette.background)
                .activitySystemActionForegroundColor(ActivityPalette.primary)
                // A tap on the lock screen opens this flight, not just the app.
                .widgetURL(FlightLink.url(for: context.attributes.flightId))
        } dynamicIsland: { context in
            let display = FlightActivityDisplay(context.attributes, context.state, twelveHour: SharedSettings.twelveHour(), now: .now,
                                                isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FlightActivityExpandedEnd(code: context.attributes.originIata, time: display.departureTime,
                                              alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FlightActivityExpandedEnd(code: context.attributes.destinationIata,
                                              time: [display.arrivalTime, display.arrivalDayMark].compactMap { $0 }
                                                  .joined(separator: " "),
                                              alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    FlightActivityExpandedCenter(display)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    FlightActivityExpandedBottom(display)
                }
            } compactLeading: {
                FlightActivityCompactLeading(display)
            } compactTrailing: {
                FlightActivityCompactTrailing(display)
            } minimal: {
                FlightActivityMinimal(display)
            }
            // A tap on the island (compact, minimal or expanded) opens this flight too.
            .widgetURL(FlightLink.url(for: context.attributes.flightId))
            .keylineTint(ActivityPalette.color(display.level))
        }
    }
}
