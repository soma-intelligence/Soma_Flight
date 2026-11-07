import AppIntents

/// The phrases Siri knows without setup, and the actions Spotlight and the Shortcuts app show.
struct SomaFlightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextFlightIntent(), phrases: [
            "Is my flight on time in \(.applicationName)",
            "When does my flight leave in \(.applicationName)",
            "\(.applicationName) next flight",
            "Check my flight with \(.applicationName)",
        ], shortTitle: "Next Flight", systemImageName: "airplane.departure")
        AppShortcut(intent: FlightStatusIntent(), phrases: [
            "Status of \(\.$flight) in \(.applicationName)",
            "Where is \(\.$flight) in \(.applicationName)",
        ], shortTitle: "Flight Status", systemImageName: "clock")
        AppShortcut(intent: OpenFlightIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show my flight in \(.applicationName)",
        ], shortTitle: "Open Flight", systemImageName: "airplane")
        AppShortcut(intent: SearchFlightsIntent(), phrases: [
            "Find a flight in \(.applicationName)",
            "Follow a flight in \(.applicationName)",
        ], shortTitle: "Find a Flight", systemImageName: "magnifyingglass")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
