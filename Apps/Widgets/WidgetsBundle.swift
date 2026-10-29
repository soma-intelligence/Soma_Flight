import SwiftUI
import WidgetKit

/// The extension's widgets: the flight Live Activity (lock screen and Dynamic Island).
@main
struct SomaFlightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}
