import FlightWatchKit
import SwiftUI
import WidgetKit

/// The Apple Watch app: My Flights and each flight's screen, from the snapshot the iPhone sends over
/// WatchConnectivity. It keeps the last snapshot in its App Group, so it and the complications work
/// offline; it never calls the network in v1.
@main
struct SomaFlightWatchApp: App {
    @State private var model: WatchFlightsModel
    /// The flight open over the list, by id.
    @State private var path: [UUID] = []
    private let receiver: WatchSessionReceiver
    @Environment(\.scenePhase) private var phase

    init() {
        let model = WatchFlightsModel { WidgetCenter.shared.reloadAllTimelines() }
        _model = State(initialValue: model)
        receiver = WatchSessionReceiver(model: model)
        receiver.activate()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                FlightListView(model: model)
            }
            .preferredColorScheme(.dark)
            // A complication's tap opens its flight: `somaflight://flight/<id>`.
            .onOpenURL { url in
                if let id = FlightLink.flightID(from: url) { path = [id] }
            }
        }
        .onChange(of: phase) { _, now in
            // The phone answers with a fresh snapshot when it can be reached.
            if now == .active { receiver.requestRefresh() }
        }
    }
}
