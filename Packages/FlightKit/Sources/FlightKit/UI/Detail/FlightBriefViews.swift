import SwiftUI

// MARK: - Environment

extension EnvironmentValues {
    /// The language-model texts. Unavailable (every section hidden, no call) unless the build turns them on
    /// (`LLM_ENABLED`) or runs on the fakes.
    @Entry public var flightBrief: any FlightBriefService = UnavailableFlightBriefService()
}

// MARK: - Model

/// One brief on screen: asks the service when its facts change and keeps the text. Any failure (the model
/// switched off or over budget, the answer refused by the facts check, no connection) leaves nothing to
/// show: the card never appears and never an error banner.
@MainActor @Observable final class FlightBriefModel {
    private(set) var brief: FlightBrief?
    private let kind: BriefKind
    private let subject: String
    private let service: any FlightBriefService

    init(kind: BriefKind, subject: String, service: any FlightBriefService) {
        self.kind = kind; self.subject = subject; self.service = service
    }

    func load(_ facts: [BriefFact]?) async {
        guard service.isAvailable, let facts, !facts.isEmpty else { brief = nil; return }
        do {
            let answer = try await service.brief(kind, subject: subject, facts: facts)
            if !Task.isCancelled { brief = answer }
        } catch {
            if !Task.isCancelled { brief = nil }
        }
    }
}

// MARK: - Wording

enum FlightBriefFacts {
    static let doorToDoorTitle = "Door to door"
    static let delayTitle = "Why it is late"
    static let airportTitle = "Airport summary"
    /// Under every text: what wrote it and from what.
    static let note = "Written by a language model from the facts shown"
}

// MARK: - Views

/// The card: a title, the text, and the note that a language model wrote it.
struct BriefCard: View {
    var title: String
    var text: String

    var body: some View {
        DetailCard {
            CardTitle(title)
            Text(verbatim: text)
                .scaledFont(16)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
            Text(ui: FlightBriefFacts.note)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The flight sheet's two brief cards, under Good to Know: door to door before the flight leaves, why it is
/// late once it is. Hidden when the language model is off.
struct FlightBriefSections: View {
    var store: FlightDetailStore
    var flight: Flight
    var now: Date
    @Environment(\.flightBrief) private var service
    @Environment(\.leaveTimes) private var estimator

    var body: some View {
        if service.isAvailable, !store.isArchived {
            let door = estimator.flatMap { e in
                BriefFacts.doorToDoor(flight: flight, leave: e.leaveTime(for: flight), walk: e.gateWalk(for: flight),
                                      tz: e.timeZone(for: flight), now: now)
            }
            let late = BriefFacts.delayCause(flight: flight, inbound: store.inbound, originWeather: store.originWeather,
                                             destinationWeather: store.destinationWeather,
                                             advisories: store.advisories, events: store.events)
            if door != nil {
                LanguageBriefSection(kind: .doorToDoor, subject: flight.id.uuidString.lowercased(), facts: door,
                             title: FlightBriefFacts.doorToDoorTitle, service: service)
            }
            if late != nil {
                LanguageBriefSection(kind: .delayCause, subject: flight.id.uuidString.lowercased(), facts: late,
                             title: FlightBriefFacts.delayTitle, service: service)
            }
        }
    }
}

/// The airport screen's summary card, under the weather. Hidden when the language model is off.
struct AirportBriefSection: View {
    var store: AirportStore
    @Environment(\.flightBrief) private var service

    var body: some View {
        if service.isAvailable, let airport = store.airport {
            LanguageBriefSection(kind: .airportSummary, subject: airport.id,
                         facts: BriefFacts.airportSummary(code: airport.iata ?? airport.id, weather: store.weather,
                                                          stats: store.stats, programs: store.programs,
                                                          security: store.security, level: store.status.level),
                         title: FlightBriefFacts.airportTitle, service: service)
                .scaledPadding(.horizontal, 16).scaledPadding(.top, 16)
        }
    }
}

/// One brief card with its model: asks again whenever the facts change, shows nothing without a text.
struct LanguageBriefSection: View {
    var facts: [BriefFact]?
    var title: String
    @State private var model: FlightBriefModel

    init(kind: BriefKind, subject: String, facts: [BriefFact]?, title: String, service: any FlightBriefService) {
        self.facts = facts; self.title = title
        _model = State(initialValue: FlightBriefModel(kind: kind, subject: subject, service: service))
    }

    var body: some View {
        Group {
            if let brief = model.brief { BriefCard(title: title, text: brief.text) }
        }
        .task(id: facts) { await model.load(facts) }
    }
}
