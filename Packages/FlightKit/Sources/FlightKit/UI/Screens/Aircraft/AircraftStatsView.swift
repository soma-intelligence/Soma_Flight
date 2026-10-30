import SwiftUI
import Charts
import FlightCore

/// Aircraft stats, opened from the most flown aircraft card: on the light blue page, the totals and the
/// most flown type, then the blueprint panels (frequented tail, cabin classes and seats); on the dark
/// page under them, the aircraft types, class, seat and reason donuts, the most frequent tails and,
/// when delivery dates are known, the age chart with the newest and oldest aircraft.
struct AircraftStatsView: View {
    @Bindable var store: PassportStore
    var onClose: () -> Void
    /// The frequented tail's age, asked of the store when the figures change.
    @State private var leadAge: UInt32?

    /// The light blue page (behind the year chips).
    static let page = Theme.aircraftPage.stops[0].color
    static let bar = Blueprint.sky
    /// The dark sections under the blueprint.
    static let sections = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255)

    var body: some View {
        FullPageChrome(title: FullPage.aircraftStats.title, year: $store.year, years: store.years, scheme: .light,
                       page: Self.page, shareKey: store.revision, onClose: onClose, bar: Self.bar,
                       sectionBackground: Self.sections, heroInset: 0,
                       chipInk: Color(red: 0x5E / 255, green: 0x68 / 255, blue: 0x8C / 255),
                       chipFill: .white.opacity(0.7), buttonFill: Color(red: 0xA9 / 255, green: 0xB9 / 255, blue: 0xDA / 255)) {
            hero
        } content: {
            sections.environment(\.colorScheme, .dark)
        }
        .task(id: store.revision) { leadAge = await store.leadTailAge() }
    }

    @ViewBuilder private var hero: some View {
        let s = store.aircraft
        if s.totalTypes == 0 {
            Text("No aircraft flown in this period")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Blueprint.navy.opacity(0.7))
                .frame(maxWidth: .infinity)
                .scaledPadding(.vertical, 60)
        } else {
            VStack(spacing: 0) {
                AircraftTotalsPanel(stats: s, mostFlownType: store.mostFlownType, mostFlownAirline: store.mostFlownAirline)
                    .background(LinearGradient(gradient: Theme.aircraftPage, startPoint: .top, endPoint: .bottom))
                if s.tails.first != nil || CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                    BlueprintPanel {
                        VStack(spacing: 0) {
                            if let tail = s.tails.first {
                                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                                FrequentedTailPanel(tail: tail, ageMonths: leadAge)
                            }
                            if CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                                CabinPanel(stats: s)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var sections: some View {
        let s = store.aircraft
        if s.totalTypes > 0 {
            AircraftTypesSection(stats: s, year: store.year)
            ClassSeatSection(stats: s)
            FrequentTailsSection(tails: s.tails, year: store.year)
            if AircraftStatsCopy.showsAges(s) { AircraftAgeSection(stats: s) }
        }
    }
}

// MARK: - Types

struct AircraftTypesSection: View {
    var stats: AircraftStats
    var year: Int?
    @State private var metric: AircraftStatsCopy.TypeMetric = .flights
    @State private var opened: Set<Int> = []
    @Environment(\.units) private var units

    var body: some View {
        PassportSection(title: "Aircraft types") {
            VStack(alignment: .leading, spacing: 0) {
                UnitNumber(parts: [AircraftStatsCopy.typesTotal(stats.totalTypes)], size: 46, unitSize: 34)
                Text("Counted by ICAO type, sub-types apart")
                    .scaledFont(16)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledPadding(.top, 2)
                MetricToggle(metric: $metric).scaledPadding(.top, 16).scaledPadding(.bottom, 12)
                RankedBars(items: AircraftStatsCopy.typeBars(stats, metric: metric, units: units.distance),
                           noun: "aircraft types", showMore: openBinding($opened, year: year),
                           tint: AircraftStatsCopy.blue)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Class and seat

struct ClassSeatSection: View {
    var stats: AircraftStats
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var bigSide: CGFloat = 290
    @ScaledMetric(relativeTo: .title) private var smallSide: CGFloat = 160

    var body: some View {
        let donuts = [AircraftStatsCopy.classDonut(stats), AircraftStatsCopy.seatDonut(stats),
                      AircraftStatsCopy.reasonDonut(stats)]
        let shown = donuts.enumerated().filter { !$0.element.isHidden }
        if !shown.isEmpty {
            PassportSection(title: "Class and seat") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.offset) { i, donut in
                        if i != shown.first?.offset { Rectangle().fill(Theme.separator).frame(height: 1) }
                        Group {
                            if i == 0 { bigDonut(donut) } else { sideDonut(donut) }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }

    /// The class donut, wide and centered, its legend under it.
    private func bigDonut(_ d: AircraftStatsCopy.Donut) -> some View {
        let side = min(bigSide, 330)
        return VStack(spacing: 16) {
            DonutChart(donut: d, valueSize: 34)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity)
            DonutLegend(slices: d.slices)
        }
        .scaledPadding(.vertical, 14)
    }

    /// A smaller donut at the left, its legend at the right; the legend goes under it at accessibility sizes.
    private func sideDonut(_ d: AircraftStatsCopy.Donut) -> some View {
        let side = min(smallSide, 240)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
        return layout {
            DonutChart(donut: d, valueSize: 24, inner: 0.7)
                .frame(width: side, height: side)
            DonutLegend(slices: d.slices)
        }
        .scaledPadding(.vertical, 22)
    }
}

private struct DonutChart: View {
    var donut: AircraftStatsCopy.Donut
    var valueSize: CGFloat
    var inner: CGFloat = 0.7

    var body: some View {
        Chart(donut.slices.filter { $0.count > 0 }) { s in
            SectorMark(angle: .value("Flights", s.count), innerRadius: .ratio(inner), angularInset: 1.5)
                .foregroundStyle(s.color)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text(donut.centerTitle).scaledFont(13).foregroundStyle(Theme.secondary)
                Text(donut.centerValue)
                    .scaledFont(valueSize, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .scaledPadding(.horizontal, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(donut.centerTitle), \(donut.centerValue)")
    }
}

private struct DonutLegend: View {
    var slices: [AircraftStatsCopy.Slice]
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 22

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(slices) { s in
                GridRow {
                    RoundedRectangle(cornerRadius: swatch * 0.23, style: .continuous).fill(s.color)
                        .frame(width: swatch, height: swatch)
                    Text(s.label).scaledFont(18).foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(PassportFacts.count(s.count)).scaledFont(18).monospacedDigit().foregroundStyle(Theme.primary)
                        .gridColumnAlignment(.trailing)
                    Text("\(s.percent)%").scaledFont(18).monospacedDigit().foregroundStyle(Theme.secondary)
                        .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.label), \(s.count), \(s.percent) percent")
            }
        }
    }
}

// MARK: - Tails

struct FrequentTailsSection: View {
    var tails: [TailTally]
    var year: Int?
    @State private var opened: Set<Int> = []
    @Environment(\.reference) private var reference
    /// Rows shown before "Show more", the lead tail included.
    static let limit = 4

    var body: some View {
        if let first = tails.first {
            PassportSection(title: "Most frequent tails") {
                list(first: first, showMore: openBinding($opened, year: year))
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    private func list(first: TailTally, showMore: Binding<Bool>) -> some View {
        let rest = Array(tails.dropFirst())
        let shown = PassportLists.visible(rest, limit: Self.limit - 1, expanded: showMore.wrappedValue)
        return VStack(alignment: .leading, spacing: 0) {
            lead(first)
            ForEach(shown, id: \.registration) { row($0) }
            if PassportLists.showsToggle(count: rest.count, limit: Self.limit - 1, expanded: showMore.wrappedValue) {
                ShowMoreButton(expanded: showMore, noun: "tails", limit: Self.limit).scaledPadding(.top, 8)
            }
        }
    }

    private func marks(_ t: TailTally) -> some View {
        HStack(spacing: 14) {
            if let airline = t.airline { AirlineMark(airline: airline, size: 26) }
            CountryFlag(code: AircraftStatsCopy.tailCountry(t, reference: reference), size: 24)
        }
    }

    private func lead(_ t: TailTally) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t.registration).scaledFont(40, weight: .bold).foregroundStyle(Theme.primary)
            Text(AircraftStatsCopy.flights(t.flights)).scaledFont(20).foregroundStyle(Theme.secondary)
            HStack {
                Text(AircraftStatsCopy.tailLine(t, reference: reference)).scaledFont(18).foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                marks(t)
            }
            .scaledPadding(.top, 10)
        }
        .scaledPadding(.bottom, 18)
        .background(alignment: .trailing) {
            BlueprintTail(type: t.icaoType.flatMap(reference.type), registration: t.registration, ink: Theme.secondary)
                .aspectRatio(1.8, contentMode: .fit)
                .frame(height: 150)
                .opacity(0.45)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ t: TailTally) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.registration).scaledFont(20, weight: .semibold).foregroundStyle(Theme.primary)
                Text(AircraftStatsCopy.tailLine(t, reference: reference)).scaledFont(17).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                marks(t)
                Text(AircraftStatsCopy.flights(t.flights)).scaledFont(17).foregroundStyle(Theme.secondary)
            }
        }
        .scaledPadding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Age

struct AircraftAgeSection: View {
    var stats: AircraftStats
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 230

    var body: some View {
        PassportSection(title: "Aircraft age") {
            VStack(alignment: .leading, spacing: 0) {
                if let median = stats.medianAgeMonths {
                    let words = AircraftStatsCopy.ageOld(months: median).split(separator: " ", maxSplits: 1).map(String.init)
                    UnitNumber(parts: [(words.first ?? "", " " + (words.last ?? ""))], size: 58, unitSize: 40)
                    Text("median age").scaledFont(18).foregroundStyle(Theme.secondary)
                }
                chart.frame(height: chartHeight).scaledPadding(.top, 20)
                // Side by side; one under the other at accessibility sizes.
                let cards = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                cards {
                    if let newest = stats.newest { AgedCard(title: "Newest aircraft", aircraft: newest) }
                    if let oldest = stats.oldest { AgedCard(title: "Oldest aircraft", aircraft: oldest) }
                }
                .scaledPadding(.top, 24)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private var chart: some View {
        let labels = AircraftStatsCopy.decadeLabels(stats.decades)
        return Chart(Array(zip(labels, stats.decades)), id: \.0) { label, d in
            BarMark(x: .value("Decade", label), y: .value("Aircraft", d.aircraft), width: .ratio(0.25))
                .foregroundStyle(AircraftStatsCopy.blue)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel().foregroundStyle(Theme.secondary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.primary).font(.subheadline) }
        }
        .accessibilityLabel("Aircraft by delivery decade")
        .accessibilityValue(zip(labels, stats.decades).map { "\($0) \($1.aircraft)" }.joined(separator: ", "))
    }
}

/// "Newest aircraft, 7 months old, 6/9/2022", the type's side view and "B78X / PH-BKL".
private struct AgedCard: View {
    var title: String
    var aircraft: AgedAircraft
    @Environment(\.reference) private var reference

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(15).foregroundStyle(Theme.primary)
            Text(AircraftStatsCopy.ageOld(months: aircraft.ageMonths))
                .scaledFont(22, weight: .medium)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AircraftStatsCopy.deliveryDay(aircraft.deliveredAt)).scaledFont(13).foregroundStyle(Theme.secondary)
            AircraftImage(type: aircraft.icaoType.flatMap { reference.type($0) }, airline: nil, height: 34)
                .frame(maxWidth: .infinity)
                .scaledPadding(.vertical, 18)
            Text([aircraft.icaoType, aircraft.registration].compactMap { $0 }.joined(separator: " / "))
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .scaledPadding(.horizontal, 8)
                .scaledPadding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pill))
        }
        .scaledPadding(.all, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}
