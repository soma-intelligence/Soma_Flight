import ActivityKit
import FlightActivityKit
import SwiftUI
import WidgetKit

/// The flight Live Activity. The views live in FlightActivityKit, shared with the snapshot tests; this
/// only places them on the lock screen and in the Dynamic Island.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            FlightActivityLockScreenView(FlightActivityDisplay(context.attributes, context.state,
                                                               twelveHour: SharedSettings.twelveHour()))
                .activityBackgroundTint(ActivityPalette.background)
                .activitySystemActionForegroundColor(ActivityPalette.primary)
        } dynamicIsland: { context in
            let display = FlightActivityDisplay(context.attributes, context.state, twelveHour: SharedSettings.twelveHour())
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
            .keylineTint(ActivityPalette.color(display.level))
        }
    }
}
