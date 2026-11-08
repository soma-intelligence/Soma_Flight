import SwiftUI

/// What the Travel Tools rows of Settings read: the history and the airport lookup the Passport uses,
/// and the name the expense reports and the poster print.
@MainActor
public struct TravelToolsSource {
    public var store: PassportStore
    public var lookup: (String) -> Airport?
    public var travellerName: String?

    public init(store: PassportStore, lookup: @escaping (String) -> Airport?, travellerName: String? = nil) {
        self.store = store; self.lookup = lookup; self.travellerName = travellerName
    }
}

/// Settings' Travel Tools: the year in review, the route poster, the Schengen 90/180 count, status goals
/// and expense reports. Each row opens its sheet. Rows that have nothing to show yet are not drawn.
/// The status goals belong to the history's account: the section is drawn again from scratch for each
/// history (`SettingsView` keys it by the store), so an account switch never shows or saves the previous
/// account's goals.
struct TravelToolsSection: View {
    var source: TravelToolsSource
    @State private var statusPrograms: StatusPrograms
    @State private var statusTarget: StatusTarget?
    @State private var schengen: Schengen.Summary?
    @State private var reviewYear: Int?
    @State private var showingReview = false
    @State private var showingPoster = false
    @State private var showingExpenses = false
    @Environment(\.units) private var units

    /// The status goal the editor sheet opens on: a new one, or one already kept.
    enum StatusTarget: Identifiable {
        case add
        case edit(StatusProgram)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let p): p.id.uuidString
            }
        }
    }

    init(source: TravelToolsSource) {
        self.source = source
        _statusPrograms = State(initialValue: StatusPrograms(owner: source.store.owner))
    }

    private var store: PassportStore { source.store }

    var body: some View {
        let now = Date.now
        let review = reviewEntry(now: now)
        let count = store.schengen(on: now)
        let poster = RoutePoster.isAvailable(store.allFlights, airport: source.lookup)
        SettingsSection("Travel Tools", footer: "Worked out on this device from your flight history.") {
            if let review {
                SettingsRow(icon: "sparkles.rectangle.stack.fill", title: "Year in Review", subtitle: review.title,
                            tint: SettingsStyle.purple, action: { reviewYear = review.year; showingReview = true }) {
                    RowChevron()
                }
            }
            if poster {
                SettingsRow(icon: "map.fill", title: "Route Poster", tint: SettingsStyle.teal,
                            action: { showingPoster = true }) { RowChevron() }
            }
            if let count {
                SettingsRow(icon: "globe.europe.africa.fill", title: "Schengen 90/180",
                            subtitle: SchengenFacts.used(count), tint: SettingsStyle.blue,
                            action: { schengen = count }) { RowChevron() }
            }
            ForEach(statusPrograms.programs) { p in
                let progress = StatusTracker.progress(p, flights: store.allFlights, now: now)
                SettingsRow(icon: "chart.bar.fill", title: p.name, subtitle: statusLine(p, progress),
                            tint: SettingsStyle.orange, action: { statusTarget = .edit(p) }) { RowChevron() }
            }
            if statusPrograms.canAdd {
                SettingsRow(icon: "plus", title: "Track a Status Goal", tint: SettingsStyle.orange,
                            action: { statusTarget = .add }) { RowChevron() }
            }
            SettingsRow(icon: "doc.text.fill", title: "Expense Reports", tint: SettingsStyle.slate, last: true,
                        action: { showingExpenses = true }) { RowChevron() }
        }
        .sheet(item: Binding(get: { schengen.map(SchengenItem.init) }, set: { if $0 == nil { schengen = nil } })) {
            SchengenDetailSheet(summary: $0.summary)
        }
        .sheet(item: $statusTarget) { target in
            switch target {
            case .add: StatusProgramEditor(store: statusPrograms, unit: units.distance)
            case .edit(let p): StatusProgramEditor(store: statusPrograms, program: p, unit: units.distance)
            }
        }
        .sheet(isPresented: $showingReview) {
            YearInReviewSheet(flights: store.allFlights, unit: units.distance, year: reviewYear)
        }
        .sheet(isPresented: $showingPoster) {
            RoutePosterSheet(flights: store.allFlights, name: source.travellerName, unit: units.distance,
                             lookup: source.lookup, year: store.year)
        }
        .sheet(isPresented: $showingExpenses) {
            ExpenseReportsSheet(flights: store.allFlights, lookup: source.lookup, traveller: source.travellerName,
                                units: units)
        }
    }

    /// The Schengen count as a sheet item.
    private struct SchengenItem: Identifiable {
        var summary: Schengen.Summary
        var id: Int { summary.day.number }
    }

    /// "12 of 30 segments": the first goal the programme sets.
    private func statusLine(_ p: StatusProgram, _ progress: StatusProgress) -> String {
        if let goal = p.segmentGoal, goal > 0 { return StatusFacts.segments(progress.segments, of: goal) }
        if let goal = p.distanceGoal, goal > 0 {
            return StatusFacts.distance(progress, goal: goal, goalUnit: p.distanceUnit, in: units.distance)
        }
        return StatusFacts.scope(p)
    }

    /// The year the Year in Review row opens on: the chosen Passport year when it has a flight to count, else
    /// the newest such year; nil when there is none.
    private func reviewEntry(now: Date) -> (year: Int, title: String)? {
        let years = YearInReview.years(store.allFlights)
        guard let year = store.year.flatMap({ years.contains($0) ? $0 : nil }) ?? years.first else { return nil }
        let current = Calendar.current.component(.year, from: now)
        return (year, YearInReviewFacts.entry(year: year, soFar: year == current))
    }
}
