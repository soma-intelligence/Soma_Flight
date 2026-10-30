import SwiftUI
import WidgetKit

/// The extension's widgets: the flight Live Activity (lock screen and Dynamic Island), Next Flight
/// (home screen small and medium, lock screen) and Upcoming Flights (home screen large).
@main
struct SomaFlightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
        NextFlightWidget()
        UpcomingFlightsWidget()
    }
}
