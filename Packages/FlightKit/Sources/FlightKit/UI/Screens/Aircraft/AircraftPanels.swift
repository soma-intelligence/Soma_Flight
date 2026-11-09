import SwiftUI
import FlightCore

/// Wording and picks for the Aircraft Stats page over the core's `AircraftStats`. Nothing here counts:
/// it chooses the core's rows, labels them and formats them.
enum AircraftStatsCopy {
    /// "7 months" under a year, else "29 years"; singular for one.
    static func ageCopy(months: UInt32) -> String {
        if months < 12 { return months == 1 ? "1 month" : "\(months) months" }
        let years = months / 12
        return years == 1 ? "1 year" : "\(years) years"
    }

    /// "7 months old".
    static func ageOld(months: UInt32) -> String { ageCopy(months: months) + " old" }

    /// "1990s" for each of the core's decades, in its order.
    static func decadeLabels(_ decades: [DecadeCount]) -> [String] { decades.map { "\($0.decade)s" } }

    /// Ages need delivery dates: the core gives no median without facts, and every age section hides.
    static func showsAges(_ s: AircraftStats) -> Bool { s.medianAgeMonths != nil && s.newest != nil }

    /// `part` of `whole` in whole percent, half up; 0 when `whole` is 0.
    static func percent(_ part: UInt32, of whole: UInt32) -> Int {
        guard whole > 0 else { return 0 }
        return Int((200 * UInt64(part) + UInt64(whole)) / (2 * UInt64(whole)))
    }

    /// "8 flights · 90 hours" (hours rounded half up).
    static func flightsAndHours(_ t: TypeTally) -> String {
        let hours = (t.minutes + 30) / 60
        return "\(PassportFacts.count(t.flights)) \(t.flights == 1 ? "flight" : "flights") · "
            + "\(PassportFacts.count(hours)) \(hours == 1 ? "hour" : "hours")"
    }

    /// "2 flights".
    static func flights(_ n: UInt32) -> String { "\(PassportFacts.count(n)) \(n == 1 ? "flight" : "flights")" }

    /// "56% Boeing" from the core's top manufacturer share.
    static func makerChip(_ s: AircraftStats) -> String? {
        s.manufacturers.first.map { "\($0.percent)% \($0.key)" }
    }

    /// The type's name from the reference list, else its ICAO designator.
    static func typeName(_ icao: String?, reference: ReferenceData) -> String? {
        guard let icao else { return nil }
        return reference.type(icao)?.name ?? icao
    }

    /// Delivery day as "6/9/2022" (UTC, the day the fact stores).
    static func deliveryDay(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(Date.FormatStyle(date: .numeric, time: .omitted, timeZone: .gmt).locale(Locale(identifier: "en_US")))
    }

    /// Delivery year, "2022".
    static func deliveryYear(_ seconds: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        return String(cal.component(.year, from: Date(timeIntervalSince1970: TimeInterval(seconds))))
    }

    // MARK: Types

    enum TypeMetric: String, CaseIterable, Identifiable, RankMetric {
        case flights = "Flights", time = "Time", distance = "Distance"
        var id: String { rawValue }
    }

    /// The core's type list for the metric, as ranked bars labelled with the ICAO designator.
    static func typeBars(_ s: AircraftStats, metric: TypeMetric, units: DistanceUnit) -> [RankedBar] {
        switch metric {
        case .flights:
            s.typesByFlights.map { RankedBar(id: $0.icaoType, label: .code($0.icaoType), value: Int($0.flights),
                                             caption: PassportFacts.count($0.flights)) }
        case .time:
            s.typesByMinutes.map { t in
                RankedBar(id: t.icaoType, label: .code(t.icaoType), value: Int(t.minutes),
                          caption: PassportFacts.hoursMinutes(t.minutes).map { "\($0.number)\($0.unit)" }.joined(separator: " "))
            }
        case .distance:
            s.typesByDistance.map { RankedBar(id: $0.icaoType, label: .code($0.icaoType), value: Int($0.distanceKm),
                                              caption: TravelFacts.distance(Int($0.distanceKm), units)) }
        }
    }

    /// "12 total aircraft", "1 aircraft".
    static func typesTotal(_ n: UInt32) -> (number: String, unit: String) {
        (PassportFacts.count(n), n == 1 ? " aircraft" : " total aircraft")
    }

    // MARK: Donuts

    struct Slice: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var count: UInt32
        var percent: Int
        var color: Color
    }

    struct Donut: Equatable {
        var centerTitle: String
        var centerValue: String
        var slices: [Slice]
        /// Nothing to draw: every count is 0.
        var isHidden: Bool { slices.allSatisfy { $0.count == 0 } }
    }

    static let economy = Color(red: 0xBB / 255, green: 0xDB / 255, blue: 0xFA / 255)
    static let premium = Color(red: 0x99 / 255, green: 0xD5 / 255, blue: 0xF6 / 255)
    static let business = Color(red: 0x47 / 255, green: 0xA2 / 255, blue: 0xE8 / 255)
    static let first = Color(red: 0x34 / 255, green: 0x6F / 255, blue: 0xE6 / 255)
    static let green = Color(red: 0x54 / 255, green: 0xB4 / 255, blue: 0x71 / 255)
    static let orange = Color(red: 0xEA / 255, green: 0x99 / 255, blue: 0x3A / 255)
    /// The page's blue: type and age bars, First, Window and Business slices.
    static let blue = first
    static let purple = Color(red: 0x8E / 255, green: 0x6C / 255, blue: 0xE0 / 255)
    static let teal = Color(red: 0x4C / 255, green: 0xC2 / 255, blue: 0xC4 / 255)
    static let gray = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0xA0 / 255)

    /// Rare picks (Private, Crew, cockpit seats) join a donut only once flown, so most legends keep their
    /// usual slices.
    private static func extra(_ rows: [(String, UInt32, Color)]) -> [(String, UInt32, Color)] {
        rows.filter { $0.1 > 0 }
    }

    private static func donut(_ title: String, _ rows: [(String, UInt32, Color)], value: String? = nil) -> Donut {
        let total = rows.reduce(0) { $0 + $1.1 }
        let slices = rows.map { Slice(label: $0.0, count: $0.1, percent: percent($0.1, of: total), color: $0.2) }
        // The first of the largest, in the legend's order.
        let top = slices.reduce(nil as Slice?) { best, s in s.count > (best?.count ?? 0) ? s : best }
        return Donut(centerTitle: title, centerValue: value ?? top?.label ?? "", slices: slices)
    }

    static func classDonut(_ s: AircraftStats) -> Donut {
        let c = s.seatClasses
        return donut("Top class", [("Economy", c.economy, economy), ("Premium Economy", c.premiumEconomy, premium),
                                   ("Business", c.business, business), ("First", c.first, first)]
                                  + extra([("Private", c.private, purple)]))
    }

    /// Centered on the favorite seat ("20D") when there is one, else the top position.
    static func seatDonut(_ s: AircraftStats) -> Donut {
        let p = s.seatPositions
        return donut("Top seat", [("Aisle", p.aisle, green), ("Middle", p.middle, orange), ("Window", p.window, blue)]
                                 + extra([("Captain", p.captain, purple), ("Pilot", p.pilot, teal),
                                          ("Jumpseat", p.jumpseat, gray)]),
                     value: s.favouriteSeat?.seat)
    }

    static func reasonDonut(_ s: AircraftStats) -> Donut {
        donut("Top reason", [("Personal", s.reasons.personal, green), ("Business", s.reasons.business, blue)]
                            + extra([("Crew", s.reasons.crew, orange)]))
    }

    /// "Favorite seat", "20D (2 times)".
    static func favoriteSeat(_ s: AircraftStats) -> (title: String, value: String)? {
        s.favouriteSeat.map { ("Favorite seat", "\($0.seat) (\($0.flights) \($0.flights == 1 ? "time" : "times"))") }
    }

    // MARK: Tails

    /// "AF · B77W · Rambouillet": the airline's IATA code, the type and the airframe's name when known.
    static func tailLine(_ t: TailTally, reference: ReferenceData) -> String {
        let airline = t.airline.map { reference.airline($0)?.iata ?? $0 }
        return [airline, t.icaoType, t.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The registering country from the registration's nationality mark (ICAO Annex 7), else the airline's
    /// country.
    static func tailCountry(_ t: TailTally, reference: ReferenceData) -> String? {
        registrationCountry(t.registration) ?? t.airline.flatMap { reference.airline($0)?.country }
    }

    /// ISO 3166 code for a registration's nationality mark: "F-GSQI" FR, "N370DN" US, "B-HNR" HK.
    static func registrationCountry(_ registration: String) -> String? {
        let r = registration.trimmingCharacters(in: .whitespaces).uppercased()
        guard !r.isEmpty else { return nil }
        if let dash = r.firstIndex(of: "-") {
            let mark = String(r[..<dash])
            let rest = r[r.index(after: dash)...]
            if mark == "B", let next = rest.first {
                if "HKL".contains(next) { return "HK" }
                if next == "M" { return "MO" }
                // Taiwan: five digits (B-18901) or a leading 0 (B-0001); China: four characters (B-1234, B-30AB).
                if next == "0" || (rest.count == 5 && rest.allSatisfy(\.isNumber)) { return "TW" }
                return "CN"
            }
            // Two marks share VP / VQ: the letter after the dash picks the territory.
            if let next = rest.first, let territory = territories[mark + "-" + String(next)] { return territory }
            return marks[mark]
        }
        // Marks written without a dash.
        for mark in ["JA", "HL", "N"] where r.hasPrefix(mark) { return marks[mark] }
        return nil
    }

    private static let marks: [String: String] = [
        "N": "US", "C": "CA", "F": "FR", "G": "GB", "D": "DE", "I": "IT", "EC": "ES", "EI": "IE", "PH": "NL",
        "OO": "BE", "HB": "CH", "OE": "AT", "SE": "SE", "LN": "NO", "OY": "DK", "OH": "FI", "SP": "PL", "OK": "CZ",
        "HA": "HU", "YR": "RO", "LZ": "BG", "SX": "GR", "TC": "TR", "CS": "PT", "LX": "LU", "TF": "IS", "9H": "MT",
        "5B": "CY", "4X": "IL", "A6": "AE", "A7": "QA", "A9C": "BH", "HZ": "SA", "9K": "KW", "A4O": "OM", "SU": "EG",
        "CN": "MA", "ZS": "ZA", "5Y": "KE", "ET": "ET", "5N": "NG", "VT": "IN", "AP": "PK", "9V": "SG", "9M": "MY",
        "HS": "TH", "PK": "ID", "RP": "PH", "VN": "VN", "JA": "JP", "HL": "KR", "VH": "AU", "ZK": "NZ", "XA": "MX",
        "XB": "MX", "XC": "MX", "PP": "BR", "PR": "BR", "PS": "BR", "PT": "BR", "PU": "BR", "LV": "AR", "CC": "CL",
        "HK": "CO", "OB": "PE", "YV": "VE", "HP": "PA", "TI": "CR", "YU": "RS", "9A": "HR", "S5": "SI", "UR": "UA",
        "RA": "RU", "UP": "KZ", "4K": "AZ", "4L": "GE", "EK": "AM", "4R": "LK", "S2": "BD", "EP": "IR", "JY": "JO",
        "OD": "LB", "7T": "DZ", "TS": "TN", "9G": "GH", "6V": "SN", "TU": "CI", "5H": "TZ", "3B": "MU", "8Q": "MV",
        "6Y": "JM", "C6": "BS", "8P": "BB", "9Y": "TT", "HI": "DO", "HC": "EC", "CX": "UY", "ZP": "PY", "CP": "BO",
        "9N": "NP", "M": "IM", "ES": "EE", "YL": "LV", "LY": "LT", "OM": "SK", "ER": "MD", "EW": "BY", "Z3": "MK",
        "E7": "BA", "ZA": "AL", "4O": "ME", "5R": "MG", "UK": "UZ", "XU": "KH", "ST": "SD",
    ]

    /// Overseas territories under the UK's VP / VQ / VR marks.
    private static let territories: [String: String] = [
        "VP-B": "BM", "VQ-B": "BM", "VP-C": "KY", "VR-C": "KY", "VP-L": "VG", "VP-A": "AI", "VP-M": "MS",
        "VQ-T": "TC", "VP-F": "FK",
    ]
}

// MARK: - Blueprint

/// The page's colours around the blueprint (the panel, grid and ink are `Theme.blueprint*`).
enum Blueprint {
    static let ink = Theme.blueprintInk
    static let navy = Color(red: 0x17 / 255, green: 0x2F / 255, blue: 0x5E / 255)
    /// The bar above the page, light blue.
    static let sky = Color(red: 0xCF / 255, green: 0xE0 / 255, blue: 0xF8 / 255)
    /// The most flown type's "9 flights · 42 hours" line: it sits where the page fade reaches its mid blue,
    /// so it needs a deeper ink than `navy` for 4.5:1 there.
    static let deepRGB: (r: Double, g: Double, b: Double) = (0x0B / 255, 0x17 / 255, 0x33 / 255)
    static let deep = Color(red: deepRGB.r, green: deepRGB.g, blue: deepRGB.b)
}

// MARK: - Header panel

/// Totals (aircraft, newest, oldest with their chips) and the most flown type over a light blue fade.
struct AircraftTotalsPanel: View {
    var stats: AircraftStats
    var mostFlownType: AircraftType?
    var mostFlownAirline: Airline?
    /// The next types by flights, each in the livery it was flown most in (`PassportStore.runnersUp`).
    var ranking: [AircraftRank] = []
    @Environment(\.reference) private var reference
    @ScaledMetric(relativeTo: .title) private var valueHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            totals
            if let most = stats.mostFlown { mostFlown(most) }
            if !ranking.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(ranking.enumerated()), id: \.element.tally.icaoType) { i, rank in
                        AircraftRankRow(place: i + 2, rank: rank)
                    }
                }
                .scaledPadding(.bottom, 12)
            }
        }
        .foregroundStyle(Blueprint.navy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totals: some View {
        let ages = AircraftStatsCopy.showsAges(stats)
        return HStack(alignment: .top, spacing: 8) {
            column("Total aircraft", value: PassportFacts.count(stats.totalTypes), number: Double(stats.totalTypes), sub: nil,
                   chip: AircraftStatsCopy.makerChip(stats), big: true)
            if ages, let newest = stats.newest, let oldest = stats.oldest {
                column("Newest aircraft", value: AircraftStatsCopy.ageCopy(months: newest.ageMonths),
                       number: Double(newest.ageMonths),
                       sub: AircraftStatsCopy.deliveryYear(newest.deliveredAt),
                       chip: AircraftStatsCopy.typeName(newest.icaoType, reference: reference), big: false)
                column("Oldest aircraft", value: AircraftStatsCopy.ageCopy(months: oldest.ageMonths),
                       number: Double(oldest.ageMonths),
                       sub: AircraftStatsCopy.deliveryYear(oldest.deliveredAt),
                       chip: AircraftStatsCopy.typeName(oldest.icaoType, reference: reference), big: false)
            }
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 14)
    }

    private func column(_ title: String, value: String, number: Double, sub: String?, chip: String?, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui: title).scaledFont(15, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
            // One value height in every column, so the chips line up.
            Text(ui: value).scaledFont(big ? 30 : 21, weight: .regular).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .rollingDigits(number)
                .frame(minHeight: valueHeight, alignment: .bottomLeading)
            Text(sub ?? " ").scaledFont(13).monospacedDigit().opacity(sub == nil ? 0 : 0.75)
                .rollingDigits(sub.flatMap(Double.init))
            if let chip {
                Text(ui: chip)
                    .scaledFont(12, weight: .medium, design: .monospaced)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.7)
                    .scaledPadding(.horizontal, 8)
                    .scaledPadding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.45)))
                    .scaledPadding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func mostFlown(_ most: TypeTally) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Most flown aircraft").scaledFont(16, weight: .semibold)
            Text(mostFlownType?.name ?? most.icaoType)
                .scaledFont(40, weight: .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(AircraftStatsCopy.flightsAndHours(most))
                .scaledFont(16, weight: .medium)
                .monospacedDigit()
                .rollingDigits(Double(most.flights))
                .foregroundStyle(Blueprint.deep)
            // As wide as the panel, like the reference's hero plane: up to 96 pt tall, no wider than 353 pt.
            AircraftImage(type: mostFlownType, airline: mostFlownAirline,
                          height: min(96, 353 / AircraftSideView.aspect(type: mostFlownType)))
                .frame(maxWidth: .infinity)
                .scaledPadding(.top, 12)
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 30)
        .scaledPadding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ranking

/// One of the next most flown types: its place, name and "3 flights · 7 hours" at the left, its side view
/// in the livery it was flown most in at the right, large and cut by the panel's right edge (nose in view).
struct AircraftRankRow: View {
    var place: Int
    var rank: AircraftRank
    @ScaledMetric(relativeTo: .title) private var planeHeight: CGFloat = 62
    /// What shows of the aircraft before the edge cuts it: the front two thirds or so.
    @ScaledMetric(relativeTo: .title) private var planeWidth: CGFloat = 190

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(place)")
                    .scaledFont(13, weight: .semibold, design: .monospaced)
                    .opacity(0.55)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rank.type?.name ?? rank.tally.icaoType)
                        .scaledFont(19, weight: .regular)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AircraftStatsCopy.flightsAndHours(rank.tally))
                        .scaledFont(13, weight: .medium)
                        .monospacedDigit()
                        .rollingDigits(Double(rank.tally.flights))
                        .foregroundStyle(Blueprint.deep.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The aircraft starts near the panel's middle and runs past its right edge.
            Color.clear
                .frame(minWidth: planeWidth, maxWidth: planeWidth)
                .frame(height: planeHeight)
                .overlay(alignment: .leading) {
                    AircraftImage(type: rank.type, airline: rank.airline, height: planeHeight)
                        .fixedSize()
                }
                .clipped()
        }
        .scaledPadding(.leading, 20)
        .scaledPadding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Blueprint.navy.opacity(0.12)).frame(height: 1).scaledPadding(.leading, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(place), \(rank.type?.name ?? rank.tally.icaoType), "
                            + AircraftStatsCopy.flightsAndHours(rank.tally).replacingOccurrences(of: " · ", with: ", "))
    }
}

// MARK: - Frequented tail

/// The tail drawing at the left, the most flown registration at the right with its flag, airline, name,
/// type and age.
struct FrequentedTailPanel: View {
    var tail: TailTally
    var ageMonths: UInt32?
    @Environment(\.reference) private var reference

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            BlueprintTail(type: tail.icaoType.flatMap(reference.type), registration: tail.registration)
                .aspectRatio(1.8, contentMode: .fit)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text("Frequented tail").scaledFont(15, weight: .semibold)
                Text(AircraftStatsCopy.flights(tail.flights)).scaledFont(30).monospacedDigit()
                    .rollingDigits(Double(tail.flights))
                HStack(spacing: 10) {
                    CountryFlag(code: AircraftStatsCopy.tailCountry(tail, reference: reference), size: 22)
                    if let airline = tail.airline { AirlineTailMark(airline: airline, size: 30) }
                }
                .scaledPadding(.top, 8)
                Text(ui: tail.registration).scaledFont(19, weight: .bold).scaledPadding(.top, 6)
                if let name = tail.name { Text(ui: name).scaledFont(15).opacity(0.85) }
                Text(ui: detailLine).scaledFont(13).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Blueprint.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaledPadding(.trailing, 16)
            .accessibilityElement(children: .combine)
        }
        .scaledPadding(.vertical, 22)
    }

    private var detailLine: String {
        [AircraftStatsCopy.typeName(tail.icaoType, reference: reference), ageMonths.map(AircraftStatsCopy.ageOld)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Cabin

/// The cabin over the store's seat classes, positions and favourite seat, as a technical drawing: the plan
/// of the most flown type's family with its class zones, the class table under it, then the half section
/// A-A with the seat counts lettered over the seats. At accessibility sizes the drawing gives way to the
/// text plan (`CabinPlan`), which reflows.
struct CabinPanel: View {
    var stats: AircraftStats
    /// The most flown type, whose family the plan draws.
    var type: AircraftType? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    static func hasClasses(_ s: AircraftStats) -> Bool { CabinPlan.hasClasses(s.seatClasses) }

    static func hasSeats(_ s: AircraftStats) -> Bool {
        CabinPlan.hasSeats(s.seatPositions, hasFavourite: s.favouriteSeat != nil)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            CabinPlan(classes: stats.seatClasses, positions: stats.seatPositions,
                      favourite: AircraftStatsCopy.favoriteSeat(stats))
                .scaledPadding(.vertical, 22)
        } else {
            CabinBlueprint(stats: stats, family: PlanFamily(type?.family), typeName: type?.name)
                .scaledPadding(.vertical, 18)
        }
    }
}

/// The drawing sheet itself: title block, plan, class table, half section.
struct CabinBlueprint: View {
    var stats: AircraftStats
    var family: PlanFamily
    var typeName: String?

    /// Class table rows in the bar's order, with the letter the plan's zones carry. Private joins once flown.
    static func classRows(_ c: SeatClassCounts) -> [(code: String, name: String, count: UInt32)] {
        [("Y", "Eco", c.economy), ("W", "Eco+", c.premiumEconomy), ("J", "Business", c.business), ("F", "First", c.first)]
            + (c.private > 0 ? [("P", "Private", c.private)] : [])
    }

    /// Zones front to back for the plan.
    static func zones(_ c: SeatClassCounts) -> [(code: String, share: Double)] {
        [("F", Double(c.first)), ("J", Double(c.business)), ("W", Double(c.premiumEconomy)), ("Y", Double(c.economy))]
    }

    var body: some View {
        let classes = stats.seatClasses
        let p = stats.seatPositions
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
            if CabinPanel.hasClasses(stats) || CabinPanel.hasSeats(stats) {
                CabinCutaway(family: family) { favouriteSeat }
                    .scaledPadding(.top, 6)
            }
            if CabinPanel.hasClasses(stats) { classTable(classes) }
            if CabinPanel.hasSeats(stats) {
                HStack(alignment: .top, spacing: 14) {
                    HalfSection(family: family, counts: seatCounts(p), names: seatNames)
                        .frame(maxWidth: 220)
                        .clipped()
                    VStack(alignment: .leading, spacing: 14) {
                        caption("Section A-A", "Looking forward")
                        if family.plan.layout[0] < 3, p.middle > 0 {
                            Text("Middle \(PassportFacts.count(p.middle))").scaledFont(13).monospacedDigit()
                                .rollingDigits(Double(p.middle))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 22)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Seats: window \(p.window), middle \(p.middle), aisle \(p.aisle)")
            }
            if let cockpit = CabinPlan.cockpitLine(p) {
                HStack(spacing: 8) {
                    Text("Cockpit").scaledFont(13, weight: .semibold)
                    Text(ui: cockpit).scaledFont(13).monospacedDigit()
                }
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(Theme.blueprintInk)
    }

    /// The favourite seat, written inside the cutaway's cabin.
    @ViewBuilder private var favouriteSeat: some View {
        if let fav = AircraftStatsCopy.favoriteSeat(stats) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ui: fav.title).scaledFont(12, weight: .semibold)
                    Text(fav.value.drop { $0 != "(" }.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
                        .scaledFont(12).monospacedDigit().opacity(0.8)
                        .rollingDigits(stats.favouriteSeat.map { Double($0.flights) })
                }
                Text(stats.favouriteSeat?.seat ?? "")
                    .scaledFont(28, weight: .regular, design: .monospaced)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
        }
    }

    /// One seat a side (a business jet's club seats) is window and aisle at once: it takes every count.
    private var seatNames: [String] {
        switch family.plan.layout[0] {
        case 1: ["Window"]
        case 2: ["Window", "Aisle"]
        default: ["Window", "Middle", "Aisle"]
        }
    }

    private func seatCounts(_ p: PositionCounts) -> [String] {
        switch family.plan.layout[0] {
        case 1: [PassportFacts.count(p.window + p.middle + p.aisle)]
        case 2: [p.window, p.aisle].map { PassportFacts.count($0) }
        default: [p.window, p.middle, p.aisle].map { PassportFacts.count($0) }
        }
    }

    private func caption(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ui: title).scaledFont(11, weight: .semibold, design: .monospaced).textCase(.uppercase).tracking(0.8)
            Text(ui: sub).scaledFont(11, design: .monospaced).opacity(0.7)
        }
        .accessibilityHidden(true)
    }

    /// "PLAN · NARROWBODY TWIN" at the left, the type at the right, over a hairline.
    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Plan · \(family.title)").scaledFont(11, weight: .semibold, design: .monospaced).textCase(.uppercase).tracking(0.8)
            Spacer(minLength: 8)
            if let typeName {
                Text(ui: typeName).scaledFont(11, design: .monospaced).lineLimit(1).minimumScaleFactor(0.7).opacity(0.75)
            }
        }
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.bottom, 4)
        .accessibilityHidden(true)
    }

    /// One ruled cell per class, like a drawing's parts list: the zone letter in a circle, the name, the count.
    private func classTable(_ c: SeatClassCounts) -> some View {
        let rows = Self.classRows(c)
        return HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(ui: row.code)
                            .scaledFont(10, weight: .bold, design: .monospaced)
                            .frame(width: 17, height: 17)
                            .overlay(Circle().stroke(Theme.blueprintInk.opacity(0.8), lineWidth: 0.75))
                        Text(ui: row.name).scaledFont(13).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(PassportFacts.count(row.count))
                        .scaledFont(24, weight: .regular)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .rollingDigits(Double(row.count))
                        .opacity(row.count == 0 ? 0.45 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaledPadding(.horizontal, 8)
                .scaledPadding(.vertical, 8)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Theme.blueprintInk.opacity(0.45)).frame(width: 0.75) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.name), \(row.count)")
            }
        }
        .overlay(Rectangle().stroke(Theme.blueprintInk.opacity(0.7), lineWidth: 0.75))
        .scaledPadding(.horizontal, 20)
        .scaledPadding(.top, 6)
    }
}
