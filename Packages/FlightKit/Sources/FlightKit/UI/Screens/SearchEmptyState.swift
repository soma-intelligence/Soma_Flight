import SwiftUI

/// A search that found nothing (D6): a quiet empty state, not the amber error card, worded for what was
/// looked for (a flight number, a route, an airport, an airline). Nothing is wrong: the search ran and
/// the answer is "none".
/// Penpot: Search · No results
struct SearchEmptyState: View {
    var intent: SearchIntent
    @Environment(\.metricsScale) private var scale

    /// What the text was read as, which picks the words.
    enum Kind: Equatable { case flightNumber, route, airport, airline, other }

    static func kind(_ intent: SearchIntent) -> Kind {
        if intent.ident != nil { return .flightNumber }
        if !intent.origins.isEmpty && !intent.destinations.isEmpty { return .route }
        if !intent.origins.isEmpty || !intent.destinations.isEmpty { return .airport }
        if intent.airline != nil { return .airline }
        return .other
    }

    static func title(_ kind: Kind) -> String {
        switch kind {
        case .flightNumber: "No flight with this number"
        case .route: "No flights on this route"
        case .airport: "No flights at this airport"
        case .airline: "No flights for this airline"
        case .other: "No flights found"
        }
    }

    static func message(_ kind: Kind) -> String {
        switch kind {
        case .flightNumber: "Check the number, or try another day."
        case .route: "Try another day, or search one of the airports for all its flights."
        case .airport: "Try another day, or add where you're flying to."
        case .airline: "Add the flight number, or where it flies."
        case .other: "Try a flight number like AF 84, or two cities like Paris Rome."
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .flightNumber, .airline: "airplane"
        case .route: SearchView.routeIcon
        case .airport: "building.columns"
        case .other: "magnifyingglass"
        }
    }

    var body: some View {
        let kind = Self.kind(intent)
        VStack(spacing: Theme.metric(Theme.Space.xs, scale)) {
            Image(systemName: Self.symbol(kind))
                .scaledFont(28, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
                .scaledPadding(.bottom, Theme.Space.xxs)
            Text(ui: Self.title(kind))
                .themeFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.primary)
                .accessibilityAddTraits(.isHeader)
            Text(ui: Self.message(kind))
                .themeFont(.label)
                .foregroundStyle(Theme.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .scaledPadding(.horizontal, Theme.Space.lg)
        .scaledPadding(.vertical, Theme.Space.lg)
        .accessibilityElement(children: .combine)
    }
}
