import AppIntents
import FlightActivityKit
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action button: the next flight at a glance (opens it), and a
/// button that opens Search. Both read the App Group snapshot only.
struct NextFlightControl: ControlWidget {
    static let kind = "me.somalabs.flight.control.next"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { line in
            ControlWidgetButton(action: OpenNextFlightIntent()) {
                Label(line.title, systemImage: "airplane.departure")
                Text(line.detail)
            }
        }
        .displayName("Next Flight")
        .description("Your next flight's gate and delay. Opens it in Soma Flight.")
    }

    struct Line: Sendable {
        var title: String
        var detail: String
    }

    struct Provider: ControlValueProvider {
        var previewValue: Line { Line(title: "UA 1527", detail: "Gate F11 · On Time") }

        func currentValue() async throws -> Line {
            guard let next = WidgetSnapshotStore.load().flights(at: .now).first else {
                return Line(title: "Next Flight", detail: "No flights")
            }
            let d = FlightWidgetDisplay(next, at: .now, twelveHour: SharedSettings.twelveHour())
            let rest = d.inlineText.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            return Line(title: d.ident, detail: rest.isEmpty ? d.headlineTime : rest)
        }
    }
}

/// Opens Search in Soma Flight.
struct FindFlightControl: ControlWidget {
    static let kind = "me.somalabs.flight.control.find"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SearchFlightsIntent()) {
                Label("Find a Flight", systemImage: "magnifyingglass")
            }
        }
        .displayName("Find a Flight")
        .description("Opens Search in Soma Flight to follow a flight.")
    }
}
