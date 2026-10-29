import SwiftUI

/// Year chips: All-Time then each year with flights, the chosen one in a grey capsule.
struct YearChips: View {
    var years: [Int]
    @Binding var selection: Int?
    /// The chosen chip's fill and the other chips' text.
    var fill: Color = Theme.pill
    var ink: Color = Theme.secondary
    @Environment(\.airportStaticControls) private var staticControls

    var body: some View {
        HorizontalStrip(scrolls: !staticControls) {
            HStack(spacing: 4) {
                chip(nil, "All-Time")
                ForEach(years, id: \.self) { chip($0, String($0)) }
            }
            .scaledPadding(.horizontal, 16)
        }
    }

    private func chip(_ year: Int?, _ label: String) -> some View {
        let on = year == selection
        return Button { selection = year } label: {
            Text(label)
                .scaledFont(17, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(on ? Theme.primary : ink)
                .scaledPadding(.horizontal, 15)
                .frame(minHeight: 38)
                .background(Capsule().fill(on ? fill : .clear))
                .overlay(Capsule().strokeBorder(on ? Theme.primary.opacity(0.08) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The deep blue card with the totals for the chosen period. The whole card opens the full Passport.
struct PassportCard: View {
    var stats: PassportStats
    var year: Int?
    var units: Units
    var onOpen: () -> Void = {}

    static let ink = Color.white
    static let soft = Color(red: 0.80, green: 0.82, blue: 1.0).opacity(0.78)

    var body: some View {
        Button(action: onOpen) { face() }
            .buttonStyle(CardPressStyle())
            .accessibilityLabel("Soma Flight Passport, all flight stats")
            .accessibilityValue("\(stats.flights) flights, \(TravelFacts.distance(stats.distanceKm, units.distance))")
    }

    /// The card without its button, also what the full Passport page shows and shares. `framed: false`
    /// leaves out the card's own fill and rim, for the Passport page's header panel that draws its own.
    func face(row: Bool = true, framed: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(year.map(String.init) ?? "All-Time") Soma Flight Passport".uppercased())
                .scaledFont(20, weight: .medium)
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle").scaledFont(11, weight: .semibold)
                Text("TRAVEL RECORD").scaledFont(12, weight: .semibold)
            }
            .foregroundStyle(Self.soft)
            .scaledPadding(.top, 3)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    flightsStat.frame(minWidth: 112, alignment: .leading)
                    distanceStat
                }
                VStack(alignment: .leading, spacing: 12) { flightsStat; distanceStat }
            }
            .scaledPadding(.top, 20)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    stat("Flight time", TravelFacts.flightTime(stats.flightTime))
                        .frame(minWidth: 112, alignment: .leading)
                    stat("Airports", "\(stats.airports)")
                        .frame(minWidth: 84, alignment: .leading)
                    stat("Airlines", "\(stats.airlines)")
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    stat("Flight time", TravelFacts.flightTime(stats.flightTime))
                    stat("Airports", "\(stats.airports)")
                    stat("Airlines", "\(stats.airlines)")
                }
            }
            .scaledPadding(.top, 12)
            if row {
                CardRow(title: "All flight stats", fill: .white.opacity(0.12), ink: Self.ink)
                    .scaledPadding(.top, 18)
            }
        }
        .monospacedDigit()
        .scaledPadding(.horizontal, 18)
        .scaledPadding(.top, 20)
        .scaledPadding(.bottom, row ? 16 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if framed { Self.background } }
        .clipShape(shape)
        .overlay { if framed { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) } }
    }

    private var flightsStat: some View {
        stat("Flights", "\(stats.flights)", big: true, caption: stats.longHaul > 0 ? "\(stats.longHaul) long haul" : nil)
    }

    private var distanceStat: some View {
        stat("Distance", TravelFacts.distance(stats.distanceKm, units.distance), big: true,
             caption: stats.distanceKm > 0 ? TravelFacts.aroundTheWorld(stats.distanceKm) : nil)
    }

    static var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.04, blue: 0.30), Color(red: 0.11, green: 0.13, blue: 0.47)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.33, green: 0.40, blue: 0.78).opacity(0.75), .clear],
                           center: UnitPoint(x: 0.95, y: 1.05), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [Color(red: 0.20, green: 0.10, blue: 0.55).opacity(0.6), .clear],
                           center: UnitPoint(x: 0.0, y: 0.0), startRadius: 0, endRadius: 220)
        }
    }

    private func stat(_ label: String, _ value: String, big: Bool = false, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .scaledFont(14)
                .foregroundStyle(Self.soft)
            Text(value)
                .scaledFont(big ? 34 : 24, weight: .bold)
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .scaledFont(15)
                    .foregroundStyle(Self.soft)
                    .lineLimit(1)
            }
        }
    }
}

/// The red card: time lost to delays and how late the delayed flights were. The whole card opens the
/// delay stats page.
struct DelaysCard: View {
    var stats: PassportStats
    var onOpen: () -> Void = {}

    static let soft = Color(red: 1.0, green: 0.70, blue: 0.68)

    var body: some View {
        let lost = TravelFacts.delayLost(stats.delayLost)
        Button(action: onOpen) { face() }
            .buttonStyle(CardPressStyle())
            .accessibilityLabel("Delays, all delay stats")
            .accessibilityValue("\(lost.value) \(lost.caption)")
    }

    /// The card without its button, also the delay page's header and what it shares.
    func face(row: Bool = true) -> some View {
        let lost = TravelFacts.delayLost(stats.delayLost)
        return VStack(alignment: .leading, spacing: 0) {
            Text(lost.value)
                .scaledFont(64, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.white)
                .scaledPadding(.bottom, -4)
            Text(lost.caption)
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(.white)
            Text(TravelFacts.delayedAverageLine(stats.avgDelayedMinutes, delayed: stats.delayedFlights))
                .scaledFont(17)
                .foregroundStyle(Self.soft)
                .scaledPadding(.top, 4)
            if row {
                CardRow(title: "All delay stats", fill: .white.opacity(0.13), ink: .white)
                    .scaledPadding(.top, 18)
            }
        }
        .scaledPadding(.horizontal, 18)
        .scaledPadding(.top, 14)
        .scaledPadding(.bottom, row ? 16 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    static var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.62, green: 0.13, blue: 0.11), Color(red: 0.36, green: 0.07, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.75, green: 0.30, blue: 0.24).opacity(0.5), .clear],
                           center: UnitPoint(x: 1.0, y: 1.1), startRadius: 0, endRadius: 240)
        }
    }
}

/// The pale card with the aircraft flown most, drawn for the airline that flew it most for the user.
/// The whole card opens the aircraft stats page.
struct AircraftCard: View {
    var typeCode: String
    var type: AircraftType?
    var airline: Airline?
    var count: Int
    var onOpen: () -> Void = {}

    static let ink = Color(red: 0.11, green: 0.18, blue: 0.34)

    var body: some View {
        Button(action: onOpen) { face() }
            .buttonStyle(CardPressStyle())
            .accessibilityLabel("Most flown aircraft, all aircraft stats")
            .accessibilityValue("\(name), \(flightsText)")
    }

    private var name: String { type?.name ?? TravelFacts.aircraftName(typeCode) }
    private var flightsText: String { count == 1 ? "1 flight" : "\(count) flights" }

    /// The card without its button, also the aircraft page's hero.
    func face(row: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Most flown aircraft")
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(Self.ink)
            Text(name)
                .scaledFont(32)
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .scaledPadding(.top, 2)
            Text(flightsText)
                .scaledFont(17)
                .foregroundStyle(Self.ink.opacity(0.6))
                .scaledPadding(.top, 2)
            AircraftImage(type: type, airline: airline, height: 72)
                .frame(maxWidth: .infinity)
                .scaledPadding(.top, 14)
            if row {
                CardRow(title: "All aircraft stats", fill: Self.ink.opacity(0.07), ink: Self.ink)
                    .scaledPadding(.top, 14)
            }
        }
        .scaledPadding(.horizontal, 18)
        .scaledPadding(.top, 20)
        .scaledPadding(.bottom, row ? 16 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    static var background: some View {
        LinearGradient(colors: [Color(red: 0.87, green: 0.85, blue: 0.96), Color(red: 0.76, green: 0.85, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The row at the foot of a Passport card: "All flight stats" and a chevron on a tinted bar. Part of
/// the card's one button, not a button of its own.
struct CardRow: View {
    var title: String
    var fill: Color
    var ink: Color

    var body: some View {
        HStack {
            Text(title).scaledFont(17, weight: .medium)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").scaledFont(15, weight: .semibold).opacity(0.8)
        }
        .foregroundStyle(ink)
        .scaledPadding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
    }
}

/// A Passport card as a button: it dims and sinks a little while pressed.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Past flights: sort chips, then groups (years for the date sort) with their rows.
struct PastFlightsSection: View {
    var flights: [PastFlight]
    var lookup: (String) -> Airport?
    @Binding var sort: TravelFacts.Sort
    @Environment(\.airportStaticControls) private var staticControls

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Past Flights")
                .scaledFont(22, weight: .bold)
                .foregroundStyle(Theme.primary)
                .scaledPadding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            HorizontalStrip(scrolls: !staticControls) {
                HStack(spacing: 2) {
                    ForEach(TravelFacts.Sort.allCases, id: \.self) { s in
                        Button { sort = s } label: {
                            Text(s == .date && sort == .date ? "Date \u{2193}" : s.title)
                                .scaledFont(15, weight: sort == s ? .semibold : .medium)
                                .foregroundStyle(sort == s ? Theme.primary : Theme.secondary)
                                .scaledPadding(.horizontal, 13)
                                .frame(minHeight: 32)
                                .background(Capsule().fill(sort == s ? Theme.pill : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(sort == s ? .isSelected : [])
                    }
                }
                .scaledPadding(.horizontal, 14)
            }
            .scaledPadding(.top, 12)
            .scaledPadding(.bottom, 10)

            ForEach(TravelFacts.groups(flights, by: sort, city: city)) { group in
                HStack {
                    Text(group.title).scaledFont(17, weight: .bold).foregroundStyle(Theme.primary)
                    Spacer()
                    Text((group.flights.count == 1 ? "1 flight" : "\(group.flights.count) flights").uppercased())
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                }
                .scaledPadding(.horizontal, 20)
                .scaledPadding(.top, 18)
                .scaledPadding(.bottom, 10)
                .accessibilityElement(children: .combine)
                ForEach(group.flights) { f in
                    Hairline()
                    PastFlightRow(flight: f, origin: lookup(f.originIcao), destination: lookup(f.destinationIcao))
                }
            }
        }
    }

    private func city(_ icao: String) -> String { lookup(icao)?.city ?? icao }
}

/// "UA 984  CDG → SFO", "Paris to San Francisco", the date on the right.
struct PastFlightRow: View {
    var flight: PastFlight
    var origin: Airport?
    var destination: Airport?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AirlineBadge(code: TravelFacts.airlineCode(ident: flight.ident), key: flight.airline ?? flight.ident)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Format.ident(flight.ident)).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
                    Text("\(origin?.iata ?? flight.originIcao) \u{2192} \(destination?.iata ?? flight.destinationIcao)")
                        .scaledFont(15)
                        .foregroundStyle(Theme.secondary.opacity(0.75))
                    Spacer(minLength: 6)
                    Text(ScreenFormat.day(flight.date, origin?.timeZone ?? TimeZone(identifier: flight.originTz ?? "UTC") ?? .gmt))
                        .scaledFont(15, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 8) {
                    RouteText(from: origin?.city ?? flight.originIcao, to: destination?.city ?? flight.destinationIcao)
                        .lineLimit(1)
                        .opacity(flight.status == .canceled ? 0.55 : 1)
                    if flight.status != .completed {
                        Text(flight.status == .canceled ? "CANCELED" : "DIVERTED")
                            .scaledFont(11, weight: .bold)
                            .foregroundStyle(flight.status == .canceled ? Theme.secondary : Theme.diverted)
                            .scaledPadding(.horizontal, 5)
                            .scaledPadding(.vertical, 2)
                            .background(Capsule().strokeBorder(flight.status == .canceled ? Theme.secondary : Theme.diverted,
                                                               lineWidth: 1))
                    }
                }
            }
        }
        .scaledPadding(.leading, 18)
        .scaledPadding(.trailing, 16)
        .scaledPadding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A row of chips that scrolls sideways, or sits flat and clipped where nothing can scroll
/// (snapshots: ImageRenderer cannot draw a ScrollView's content).
struct HorizontalStrip<Content: View>: View {
    var scrolls: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            ScrollView(.horizontal) { content }.scrollIndicators(.hidden)
        } else {
            // A 1 pt frame keeps the strip from widening its parent; the chips overflow to the right.
            content.fixedSize()
                .frame(width: 1, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }
}
