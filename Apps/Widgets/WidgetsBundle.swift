import SwiftUI
import WidgetKit

/// The extension's widgets: the flight Live Activity (lock screen and Dynamic Island), Next Flight
/// (home screen small and medium, lock screen), Upcoming Flights (home screen large) and the two Control
/// Center controls (Next Flight, Find a Flight).
@main
struct SomaFlightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
        NextFlightWidget()
        UpcomingFlightsWidget()
        NextFlightControl()
        FindFlightControl()
    }
}
