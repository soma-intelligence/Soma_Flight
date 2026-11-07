import SwiftUI

/// The suggestion groups under the search field while the user types, each row a button whose
/// VoiceOver label says what picking it does.
struct SearchSuggestionList: View {
    var suggestions: SearchSuggestions
    var lookup: (String) -> Airport?
    var onPick: (SearchSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.groups.enumerated()), id: \.element.id) { index, group in
                CapsHeader(group.kind.title)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, index == 0 ? 8 : 14)
                    .scaledPadding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                    SearchSuggestionRow(item: item, lookup: lookup) { onPick(item) }
                }
            }
        }
    }
}

/// One suggestion: a logo, flag or symbol, a title and a grey line.
struct SearchSuggestionRow: View {
    var item: SearchSuggestion
    var lookup: (String) -> Airport?
    var action: () -> Void

    var body: some View {
        content
            .accessibilityLabel(Self.accessibilityLabel(item, lookup: lookup))
            .accessibilityHint(Self.hint(item))
    }

    @ViewBuilder private var content: some View {
        let (title, subtitle) = Self.lines(item, lookup: lookup)
        switch item {
        case .flight(let ident, _):
            FrequentRow(title: title, subtitle: subtitle) {
                let code = TravelFacts.airlineCode(ident: ident)
                AirlineMark(code: code, key: code, size: SearchView.frequentIcon, decorative: true)
            } action: { action() }
        case .airline(let a):
            FrequentRow(title: title, subtitle: subtitle) {
                AirlineLogo(airline: a, code: a.iata ?? a.id, size: SearchView.frequentIcon, decorative: true)
            } action: { action() }
        case .airport(let a):
            FrequentRow(title: title, subtitle: subtitle) {
                CountryFlag(code: a.country, size: SearchView.frequentIcon, decorative: true)
            } action: { action() }
        case .board:
            OptionRow(icon: "building.columns", title: title, subtitle: subtitle, action: action)
        case .route:
            OptionRow(icon: SearchView.routeIcon, title: title, subtitle: subtitle, action: action)
        case .recent:
            OptionRow(icon: "clock.arrow.circlepath", title: title, subtitle: subtitle, action: action)
        }
    }

    /// Title and grey line: "AF 84" over "Paris to San Francisco · Following", "Air France" over
    /// "AF · AFR", "Flights from CDG today" over "Departures and arrivals".
    static func lines(_ item: SearchSuggestion, lookup: (String) -> Airport?) -> (String, String) {
        func city(_ code: String) -> String { lookup(code)?.city ?? code }
        switch item {
        case .flight(let ident, let known):
            guard let k = known else { return (Format.ident(ident), "Look up this flight today") }
            let route = ScreenFormat.route(city(k.origin), city(k.destination))
            return (Format.ident(ident), "\(route) \u{00B7} \(k.followed ? "In My Flights" : "Flown before")")
        case .airline(let a):
            return (a.name, [a.iata, a.id].compactMap { $0 }.joined(separator: " \u{00B7} "))
        case .airport(let a):
            return (DetailFacts.shortName(a.name), [a.iata, a.id, a.city].compactMap { $0 }.joined(separator: " \u{00B7} "))
        case .board(let a):
            return ("Flights from \(a.iata ?? a.id) today", "Departures and arrivals at \(DetailFacts.shortName(a.name))")
        case .route(let o, let d):
            return ("\(o.iata ?? o.id) to \(d.iata ?? d.id)", "\(ScreenFormat.route(o.city, d.city)), today")
        case .recent(let q):
            return (q, "Recent search")
        }
    }

    /// Spoken: "Flight AF 84, Paris to San Francisco, following", "Airline Air France, AF",
    /// "Airport Charles de Gaulle International, Paris".
    static func accessibilityLabel(_ item: SearchSuggestion, lookup: (String) -> Airport?) -> String {
        let (title, subtitle) = lines(item, lookup: lookup)
        switch item {
        case .flight: return "Flight \(title), \(subtitle.replacingOccurrences(of: " \u{00B7} ", with: ", "))"
        case .airline(let a): return "Airline \(a.name), \(a.iata ?? a.id)"
        case .airport(let a): return "Airport \(DetailFacts.shortName(a.name)), \(a.city)"
        case .board: return title
        case .route(let o, let d): return "Route, \(ScreenFormat.route(o.city, d.city)), today"
        case .recent: return "Recent search \(title)"
        }
    }

    static func hint(_ item: SearchSuggestion) -> String {
        if case .board = item { return "Opens the airport" }
        return item.searches ? "Searches for flights" : "Fills the search field"
    }

    /// What VoiceOver says when the list changes.
    static func announcement(count: Int) -> String {
        count == 0 ? "No suggestions" : count == 1 ? "1 suggestion" : "\(count) suggestions"
    }
}
