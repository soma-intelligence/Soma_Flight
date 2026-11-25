import SwiftUI
import Charts
import FlightCore

/// Aircraft stats, opened from the most flown aircraft card: on the light blue page, the totals and the
/// most flown type, then the blueprint panels (frequented tail, cabin classes and seats); on the dark
/// page under them, the aircraft types, class, seat and reason splits, the most frequent tails and,
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
                       page: Self.page, onClose: onClose, bar: Self.bar,
                       sectionBackground: Self.sections, heroInset: 0,
                       chipInk: Color(red: 0x5E / 255, green: 0x68 / 255, blue: 0x8C / 255),
                       chipFill: .white.opacity(0.7), buttonFill: Color(red: 0xA9 / 255, green: 0xB9 / 255, blue: 0xDA / 255),
                       header: AnyView(AircraftSky())) {
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
                AircraftTotalsPanel(stats: s, mostFlownType: store.mostFlownType, mostFlownAirline: store.mostFlownAirline,
                                    ranking: store.runnersUp())
                    .background(LinearGradient(gradient: Theme.aircraftPage, startPoint: .top, endPoint: .bottom))
                if s.tails.first != nil || CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                    BlueprintPanel {
                        VStack(spacing: 0) {
                            if let tail = s.tails.first {
                                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                                FrequentedTailPanel(tail: tail, ageMonths: leadAge, tails: s.tails)
                            }
                            if CabinPanel.hasClasses(s) || CabinPanel.hasSeats(s) {
                                Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
                                CabinPanel(stats: s, type: store.mostFlownType)
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

// MARK: - Sky

/// Behind the top bar and the year chips: white light washed with soft violet, settling at the bottom
/// into the page's lavender so the hero carries on without a seam.
struct AircraftSky: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xFE / 255),
                                    Color(red: 0xE4 / 255, green: 0xDF / 255, blue: 0xFA / 255),
                                    Theme.aircraftPage.stops[0].color],
                           startPoint: .top, endPoint: .bottom)
            // A violet bloom at the top right, white light at the left.
            RadialGradient(colors: [Color(red: 0xC8 / 255, green: 0xB6 / 255, blue: 0xF4 / 255).opacity(0.75), .clear],
                           center: UnitPoint(x: 0.9, y: 0.15), startRadius: 0, endRadius: 240)
            RadialGradient(colors: [.white.opacity(0.85), .clear],
                           center: UnitPoint(x: 0.12, y: 0.05), startRadius: 0, endRadius: 200)
            // Back to the page colour along the bottom edge.
            LinearGradient(colors: [.clear, Theme.aircraftPage.stops[0].color],
                           startPoint: UnitPoint(x: 0.5, y: 0.7), endPoint: .bottom)
        }
        .accessibilityHidden(true)
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
                    .rollingDigits(Double(stats.totalTypes))
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

    var body: some View {
        let splits = [AircraftStatsCopy.classDonut(stats), AircraftStatsCopy.seatDonut(stats),
                      AircraftStatsCopy.reasonDonut(stats)]
        let shown = splits.enumerated().filter { !$0.element.isHidden }
        if !shown.isEmpty {
            PassportSection(title: "Class and seat") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.offset) { i, split in
                        if i != shown.first?.offset { Rectangle().fill(Theme.separator).frame(height: 1) }
                        ShareSplit(donut: split).scaledPadding(.vertical, 20)
                    }
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }
}

/// One split (class, seat, reason) as a headline share, a segmented bar and a legend: "67% in Economy",
/// then one bar cut into parts with a 2 pt gap between them, then a dot, name, count and percent per part.
/// Parts take distinct hues in a fixed order, so the same slot keeps its colour from year to year.
private struct ShareSplit: View {
    var donut: AircraftStatsCopy.Donut
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 9

    struct Part: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var count: UInt32
        var percent: Int
        var color: Color
    }

    /// Categorical hues in their fixed order: blue, indigo, purple, orange, teal, pink; grey for "Other".
    static let hues: [Color] = [
        Color(light: 0x0A84FF, dark: 0x0A84FF),
        Color(light: 0x5E5CE6, dark: 0x7D7AFF),
        Color(light: 0xBF5AF2, dark: 0xDA8FFF),
        Color(light: 0xFF9F0A, dark: 0xFFB340),
        Color(light: 0x30B0C7, dark: 0x5DE6FF),
        Color(light: 0xFF2D55, dark: 0xFF6482),
    ]
    static let otherHue = Color(light: 0x8E8E93, dark: 0x98989D)
    /// Past this many parts, the smallest fold into "Other".
    static let maxParts = 6

    /// The donut's slices in their own order with a hue each; more than `maxParts` keeps the largest
    /// `maxParts - 1` and folds the rest into "Other".
    static func parts(_ donut: AircraftStatsCopy.Donut) -> [Part] {
        let slices = donut.slices
        let total = slices.reduce(0) { $0 + $1.count }
        var parts = slices.enumerated().map { i, s in
            Part(label: s.label, count: s.count, percent: s.percent, color: hues[i % hues.count])
        }
        guard parts.count > maxParts else { return parts }
        let keep = Set(parts.indices.sorted { parts[$0].count > parts[$1].count }.prefix(maxParts - 1))
        let rest = parts.indices.filter { !keep.contains($0) }.reduce(0) { $0 + parts[$1].count }
        parts = parts.indices.filter { keep.contains($0) }.map { parts[$0] }
        parts.append(Part(label: "Other", count: rest, percent: AircraftStatsCopy.percent(rest, of: total),
                          color: otherHue))
        return parts
    }

    /// "Class" from "Top class".
    static func title(_ donut: AircraftStatsCopy.Donut) -> String {
        let t = donut.centerTitle.hasPrefix("Top ") ? String(donut.centerTitle.dropFirst(4)) : donut.centerTitle
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// The first of the largest parts, in the legend's order.
    static func top(_ parts: [Part]) -> Part? {
        parts.reduce(nil as Part?) { best, p in p.count > (best?.count ?? 0) ? p : best }
    }

    /// "Class: Economy 22 flights, 67 percent; Business 3 flights, 9 percent".
    static func summary(_ donut: AircraftStatsCopy.Donut, _ parts: [Part]) -> String {
        let rows = parts.filter { $0.count > 0 }.map { "\($0.label) \($0.count), \($0.percent) percent" }
        return "\(title(donut)): " + rows.joined(separator: "; ")
    }

    var body: some View {
        let parts = Self.parts(donut)
        let flown = parts.filter { $0.count > 0 }
        let total = flown.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 12) {
            Text(ui: Self.title(donut)).scaledFont(20, weight: .bold).foregroundStyle(Theme.primary)
            if let top = Self.top(parts) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(top.percent)%").scaledFont(28, weight: .bold).monospacedDigit()
                        .foregroundStyle(Theme.primary)
                        .rollingDigits(Double(top.percent))
                    Text(ui: "in \(top.label)").scaledFont(15).foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GeometryReader { g in
                let gaps = CGFloat(max(flown.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(flown) { p in
                        Rectangle().fill(p.color)
                            .frame(width: max(0, (g.size.width - gaps) * CGFloat(p.count) / CGFloat(max(total, 1))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 14)
            VStack(spacing: 8) {
                ForEach(parts) { p in
                    HStack(spacing: 8) {
                        Circle().fill(p.color).frame(width: dot, height: dot)
                        Text(ui: p.label).scaledFont(15).foregroundStyle(Theme.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(PassportFacts.count(p.count)).scaledFont(15, weight: .semibold).monospacedDigit()
                            .foregroundStyle(Theme.primary)
                            .rollingDigits(Double(p.count))
                        Text("\(p.percent)%").scaledFont(15).monospacedDigit().foregroundStyle(Theme.secondary)
                            .rollingDigits(Double(p.percent))
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.summary(donut, parts))
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
            if let airline = t.airline { AirlineTailMark(airline: airline, size: 30) }
            CountryFlag(code: AircraftStatsCopy.tailCountry(t, reference: reference), size: 24)
        }
    }

    private func lead(_ t: TailTally) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui: t.registration).scaledFont(40, weight: .bold).foregroundStyle(Theme.primary)
            Text(AircraftStatsCopy.flights(t.flights)).scaledFont(20).monospacedDigit().foregroundStyle(Theme.secondary)
                .rollingDigits(Double(t.flights))
            HStack {
                Text(AircraftStatsCopy.tailLine(t, reference: reference)).scaledFont(18).foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                marks(t)
            }
            .scaledPadding(.top, 10)
        }
        .scaledPadding(.bottom, 18)
        // Faint, at the bottom right and kept inside the lead block, so it never runs into the section's
        // title or its Share button.
        .background(alignment: .bottomTrailing) {
            BlueprintTail(type: t.icaoType.flatMap(reference.type), registration: t.registration, ink: Theme.secondary,
                          showsRegistration: false, fitsFin: true)
                .aspectRatio(2.4, contentMode: .fit)
                .frame(height: 76)
                .opacity(0.3)
                .scaledPadding(.bottom, 50)
        }
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private func row(_ t: TailTally) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: t.registration).scaledFont(20, weight: .semibold).foregroundStyle(Theme.primary)
                Text(AircraftStatsCopy.tailLine(t, reference: reference)).scaledFont(17).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                marks(t)
                Text(AircraftStatsCopy.flights(t.flights)).scaledFont(17).monospacedDigit().foregroundStyle(Theme.secondary)
                    .rollingDigits(Double(t.flights))
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
                        .rollingDigits(Double(median))
                    Text("median age").scaledFont(18).foregroundStyle(Theme.secondary)
                }
                chart.frame(height: chartHeight).scaledPadding(.top, 20)
                // Side by side; one under the other at accessibility sizes.
                let cards = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                cards {
                    if let newest = stats.newest {
                        AgedCard(title: "Newest aircraft", aircraft: newest, airline: Self.airline(of: newest, in: stats))
                    }
                    if let oldest = stats.oldest {
                        AgedCard(title: "Oldest aircraft", aircraft: oldest, airline: Self.airline(of: oldest, in: stats))
                    }
                }
                .scaledPadding(.top, 24)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    /// The airline that flies this airframe: the one its tail row carries (the latest flight's airline).
    static func airline(of aircraft: AgedAircraft, in stats: AircraftStats) -> String? {
        stats.tails.first { $0.registration == aircraft.registration }?.airline
    }

    private var chart: some View {
        let labels = AircraftStatsCopy.decadeLabels(stats.decades)
        return Chart(Array(zip(labels, stats.decades)), id: \.0) { label, d in
            // Wide rounded bars in a light-to-deep blue, the count on top: no y axis to read across.
            BarMark(x: .value("Decade", label), y: .value("Aircraft", d.aircraft), width: .ratio(0.55))
                .foregroundStyle(LinearGradient(colors: [AircraftStatsCopy.business, AircraftStatsCopy.first],
                                                startPoint: .top, endPoint: .bottom))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
                .annotation(position: .top, spacing: 6) {
                    Text(PassportFacts.count(d.aircraft)).scaledFont(15, weight: .semibold).monospacedDigit()
                        .foregroundStyle(Theme.primary)
                }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.primary).font(.subheadline) }
        }
        .accessibilityLabel("Aircraft by delivery decade")
        .accessibilityValue(zip(labels, stats.decades).map { "\($0) \($1.aircraft)" }.joined(separator: ", "))
    }
}

/// "Newest aircraft, 7 months old, 6/9/2022", the airframe's side view in its airline's livery and
/// "B78X / PH-BKL".
private struct AgedCard: View {
    var title: String
    var aircraft: AgedAircraft
    /// The airline's name or code as the tail row has it; nil draws the plain aircraft.
    var airline: String?
    @Environment(\.reference) private var reference

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui: title).scaledFont(15).foregroundStyle(Theme.primary)
            Text(AircraftStatsCopy.ageOld(months: aircraft.ageMonths))
                .scaledFont(22, weight: .medium)
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AircraftStatsCopy.deliveryDay(aircraft.deliveredAt)).scaledFont(13).foregroundStyle(Theme.secondary)
            AircraftImage(type: aircraft.icaoType.flatMap { reference.type($0) },
                          airline: airline.flatMap { TravelFacts.badgeAirline(code: $0, key: $0, reference: reference) },
                          height: 46)
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
