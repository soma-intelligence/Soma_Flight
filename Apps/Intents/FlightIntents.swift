import AppIntents
import FlightActivityKit
import Foundation

// Siri, Shortcuts, Spotlight and the Control Center. Compiled into the app and the widget extension (the
// controls run these intents there). Every answer comes from the snapshot the app keeps in the App Group:
// no network, no account call, nothing leaves the device.

/// A followed flight, as Shortcuts and Siri list it.
struct FlightEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Flight")
    static let defaultQuery = FlightEntityQuery()

    var id: UUID
    /// "AF 84".
    var ident: String
    /// "Paris to San Francisco".
    var route: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ident)", subtitle: "\(route)")
    }

    init(_ flight: WidgetFlight) {
        let d = FlightWidgetDisplay(flight, at: .now)
        id = flight.id; ident = d.ident; route = d.routeCities
    }
}

/// The followed flights still worth showing, in My Flights' order.
struct FlightEntityQuery: EntityStringQuery {
    static func followed() -> [WidgetFlight] { WidgetSnapshotStore.load().flights(at: .now) }

    func entities(for identifiers: [FlightEntity.ID]) async throws -> [FlightEntity] {
        Self.followed().filter { identifiers.contains($0.id) }.map(FlightEntity.init)
    }

    func suggestedEntities() async throws -> [FlightEntity] {
        Self.followed().map(FlightEntity.init)
    }

    /// "AF84", "af 84", "Paris", "SFO": the ident without spaces, a city or an airport code.
    func entities(matching string: String) async throws -> [FlightEntity] {
        let q = string.lowercased().replacingOccurrences(of: " ", with: "")
        guard !q.isEmpty else { return try await suggestedEntities() }
        return Self.followed().filter { f in
            let d = FlightWidgetDisplay(f, at: .now)
            return [d.ident, f.origin.code, f.destination.code, f.origin.name, f.destination.name]
                .contains { $0.lowercased().replacingOccurrences(of: " ", with: "").contains(q) }
        }.map(FlightEntity.init)
    }
}

/// "Is my flight on time?": the next followed flight in one sentence, without opening the app.
struct NextFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Flight Status"
    static let description = IntentDescription("Tells you when your next flight leaves or lands, how late it is and its gate.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = FlightAnswer.nextFlight(WidgetSnapshotStore.load(), at: .now, twelveHour: SharedSettings.twelveHour())
        return .result(value: text, dialog: "\(text)")
    }
}

/// The status of one followed flight, without opening the app.
struct FlightStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Flight Status"
    static let description = IntentDescription("Tells you where one of your flights is: its time, delay and gate.")

    @Parameter(title: "Flight")
    var flight: FlightEntity

    static var parameterSummary: some ParameterSummary { Summary("Status of \(\.$flight)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let f = FlightEntityQuery.followed().first(where: { $0.id == flight.id }) else {
            let text = "\(flight.ident) is no longer in My Flights."
            return .result(value: text, dialog: "\(text)")
        }
        let text = FlightAnswer.sentence(f, at: .now, twelveHour: SharedSettings.twelveHour())
        return .result(value: text, dialog: "\(text)")
    }
}

/// Opens a followed flight in the app.
struct OpenFlightIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Flight"
    static let description = IntentDescription("Opens one of your flights in Soma Flight.")

    @Parameter(title: "Flight")
    var target: FlightEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(FlightLink.url(for: target.id)))
    }
}

/// Opens the next followed flight, or the app when nothing is followed: the Next Flight control.
struct OpenNextFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Next Flight"
    static let description = IntentDescription("Opens your next flight in Soma Flight.")

    func perform() async throws -> some IntentResult & OpensIntent {
        let next = FlightEntityQuery.followed().first
        let url = next.map { FlightLink.url(for: $0.id) } ?? FlightLink.searchURL(query: "")
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Opens Search, with a flight number, route or airport when given: "Find UA 1527".
struct SearchFlightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a Flight"
    static let description = IntentDescription("Opens Search in Soma Flight to find a flight by number, route or airport and follow it.")

    @Parameter(title: "Flight, route or airport", description: "For example UA 1527, SFO AUS or CDG.")
    var query: String?

    static var parameterSummary: some ParameterSummary { Summary("Find \(\.$query)") }

    init() {}
    init(query: String?) { self.query = query }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(FlightLink.searchURL(query: query ?? "")))
    }
}
