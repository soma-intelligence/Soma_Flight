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

    /// The light blue page (behind the year chips).
    static let page = Color(red: 0xC9 / 255, green: 0xD4 / 255, blue: 0xF6 / 255)
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
                    .background(LinearGradient(colors: [Self.page, Color(red: 0x9E / 255, green: 0xC0 / 255, blue: 0xF0 / 255),
                                                        Blueprint.top],
                                               startPoint: .top, endPoint: .bottom))
                if s.tails.first != nil || CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                    VStack(spacing: 0) {
                        if let tail = s.tails.first {
                            Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                            FrequentedTailPanel(tail: tail, ageMonths: store.tailAgeMonths[tail.registration])
                        }
                        if CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                            Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                            CabinPanel(stats: s)
                        }
                    }
                    .background(BlueprintPaper())
                }
            }
        }
    }

    @ViewBuilder private var sections: some View {
        let s = store.aircraft
        if s.totalTypes > 0 {
            AircraftTypesSection(stats: s)
            ClassSeatSection(stats: s)
            FrequentTailsSection(tails: s.tails, ages: store.tailAgeMonths)
            if AircraftStatsCopy.showsAges(s) { AircraftAgeSection(stats: s) }
        }
    }
}

/// Starts lists open on screenshot runs (`-passportShowMore YES`).
private var startsOpen: Bool {
    #if DEBUG
    UserDefaults.standard.bool(forKey: "passportShowMore")
    #else
    false
    #endif
}

private let barBlue = Color(red: 0x34 / 255, green: 0x6F / 255, blue: 0xE6 / 255)

/// "Show more" in the link colour, "Show less" once open.
private struct MoreToggle: View {
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Text(expanded ? "Show less" : "Show more")
                .scaledFont(17, weight: .medium)
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Types

struct AircraftTypesSection: View {
    var stats: AircraftStats
    @State private var metric: AircraftStatsCopy.TypeMetric = .flights
    @State private var expanded = startsOpen
    @Environment(\.units) private var units
    static let limit = 8

    var body: some View {
        let bars = AircraftStatsCopy.typeBars(stats, metric: metric, units: units.distance)
        let shown = expanded ? bars : Array(bars.prefix(Self.limit))
        PassportSection(title: "Aircraft types") {
            VStack(alignment: .leading, spacing: 0) {
                UnitNumber(parts: [(PassportFacts.count(stats.totalTypes), stats.totalTypes == 1 ? " total aircraft" : " total aircraft")],
                           size: 46, unitSize: 34)
                Text("Counted by ICAO type, sub-types apart")
                    .scaledFont(16)
                    .foregroundStyle(Theme.secondary)
                    .scaledPadding(.top, 2)
                picker.scaledPadding(.top, 16).scaledPadding(.bottom, 12)
                TypeBars(bars: shown, top: bars.map(\.value).max() ?? 1)
                if bars.count > Self.limit { MoreToggle(expanded: $expanded).scaledPadding(.top, 8) }
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(AircraftStatsCopy.TypeMetric.allCases) { m in
                Button { metric = m } label: {
                    Text(m.rawValue)
                        .scaledFont(16, weight: .medium)
                        .foregroundStyle(m == metric ? Theme.primary : Theme.secondary)
                        .scaledPadding(.horizontal, 17)
                        .frame(minHeight: 42)
                        .background(Capsule().fill(m == metric ? Theme.pill : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(m == metric ? .isSelected : [])
            }
        }
    }
}

/// Blue bars, one per type: the designator, then its bar sized against the largest, the figure after it.
private struct TypeBars: View {
    var bars: [AircraftStatsCopy.TypeBar]
    var top: UInt64
    @ScaledMetric(relativeTo: .body) private var row: CGFloat = 38

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            ForEach(bars) { bar in
                GridRow {
                    Text(bar.id)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .fixedSize()
                    GeometryReader { geo in
                        let reserve = CGFloat(bar.caption.count) * 10 + 14
                        let fraction = Double(bar.value) / Double(max(top, 1))
                        let width = max(row * 0.4, (geo.size.width - reserve) * fraction)
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: row * 0.16, style: .continuous)
                                .fill(barBlue)
                                .frame(width: width, height: row * 0.62)
                            Text(bar.caption)
                                .scaledFont(17)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondary)
                                .fixedSize()
                        }
                        .frame(height: geo.size.height)
                    }
                    .frame(height: row)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bar.id), \(bar.caption)")
            }
        }
    }
}

// MARK: - Class and seat

struct ClassSeatSection: View {
    var stats: AircraftStats

    var body: some View {
        let donuts = [AircraftStatsCopy.classDonut(stats), AircraftStatsCopy.seatDonut(stats),
                      AircraftStatsCopy.reasonDonut(stats)]
        let shown = donuts.enumerated().filter { !$0.element.isHidden }
        if !shown.isEmpty {
            PassportSection(title: "Class and seat") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.offset) { i, donut in
                        if i != shown.first?.offset { Rectangle().fill(Theme.separator).frame(height: 1) }
                        if i == 0 { bigDonut(donut) } else { sideDonut(donut) }
                    }
                }
            }
        }
    }

    /// The class donut, wide and centred, its legend under it.
    private func bigDonut(_ d: AircraftStatsCopy.Donut) -> some View {
        VStack(spacing: 16) {
            DonutChart(donut: d, valueSize: 34)
                .frame(width: 290, height: 290)
                .frame(maxWidth: .infinity)
            DonutLegend(slices: d.slices)
        }
        .scaledPadding(.vertical, 14)
    }

    /// A smaller donut at the left, its legend at the right.
    private func sideDonut(_ d: AircraftStatsCopy.Donut) -> some View {
        HStack(alignment: .center, spacing: 22) {
            DonutChart(donut: d, valueSize: 24, inner: 0.7)
                .frame(width: 160, height: 160)
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
                Text(donut.centreTitle).scaledFont(13).foregroundStyle(Theme.secondary)
                Text(donut.centreValue)
                    .scaledFont(valueSize, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .scaledPadding(.horizontal, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(donut.centreTitle), \(donut.centreValue)")
    }
}

private struct DonutLegend: View {
    var slices: [AircraftStatsCopy.Slice]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(slices) { s in
                GridRow {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(s.color).frame(width: 22, height: 22)
                    Text(s.label).scaledFont(18).foregroundStyle(Theme.primary).lineLimit(1).minimumScaleFactor(0.8)
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
    var ages: [String: UInt32]
    @State private var expanded = startsOpen
    @Environment(\.reference) private var reference
    static let limit = 4

    var body: some View {
        if let first = tails.first {
            let rest = Array(tails.dropFirst())
            let shown = expanded ? rest : Array(rest.prefix(Self.limit - 1))
            PassportSection(title: "Most frequent tails") {
                VStack(alignment: .leading, spacing: 0) {
                    lead(first)
                    ForEach(shown, id: \.registration) { row($0) }
                    if rest.count > Self.limit - 1 { MoreToggle(expanded: $expanded).scaledPadding(.top, 8) }
                }
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
            BlueprintTail(registration: t.registration, ink: Theme.secondary)
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

    var body: some View {
        PassportSection(title: "Aircraft age") {
            VStack(alignment: .leading, spacing: 0) {
                if let median = stats.medianAgeMonths {
                    let words = AircraftStatsCopy.ageOld(months: median).split(separator: " ", maxSplits: 1).map(String.init)
                    UnitNumber(parts: [(words.first ?? "", " " + (words.last ?? ""))], size: 58, unitSize: 40)
                    Text("median age").scaledFont(18).foregroundStyle(Theme.secondary)
                }
                chart.frame(height: 230).scaledPadding(.top, 20)
                HStack(alignment: .top, spacing: 12) {
                    if let newest = stats.newest { AgedCard(title: "Newest aircraft", aircraft: newest) }
                    if let oldest = stats.oldest { AgedCard(title: "Oldest aircraft", aircraft: oldest) }
                }
                .scaledPadding(.top, 24)
            }
        }
    }

    private var chart: some View {
        let labels = AircraftStatsCopy.decadeLabels(stats.decades)
        return Chart(Array(zip(labels, stats.decades)), id: \.0) { label, d in
            BarMark(x: .value("Decade", label), y: .value("Aircraft", d.aircraft), width: .ratio(0.25))
                .foregroundStyle(barBlue)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel().foregroundStyle(Theme.secondary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.primary).font(.system(size: 14)) }
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
