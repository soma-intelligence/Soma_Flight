import SwiftUI

/// Year chips: All-Time then each year with flights, the chosen one in a grey capsule.
struct YearChips: View {
    var years: [Int]
    @Binding var selection: Int?
    @Environment(\.airportStaticControls) private var staticControls

    var body: some View {
        HorizontalStrip(scrolls: !staticControls) {
            HStack(spacing: 4) {
                chip(nil, "All-Time")
                ForEach(years, id: \.self) { chip($0, String($0)) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ year: Int?, _ label: String) -> some View {
        let on = year == selection
        return Button { selection = year } label: {
            Text(label)
                .scaledFont(17, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(on ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(Capsule().fill(on ? Theme.pill : .clear))
                .overlay(Capsule().strokeBorder(on ? Theme.primary.opacity(0.08) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The deep blue card with the totals for the chosen period.
struct PassportCard: View {
    var stats: PassportStats
    var year: Int?
    var since: Int?
    var units: Units

    private static let ink = Color.white
    private static let soft = Color(red: 0.80, green: 0.82, blue: 1.0).opacity(0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(year.map(String.init) ?? "All-Time") Soma Flight Passport".uppercased())
                .scaledFont(20, weight: .medium)
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle").scaledFont(11, weight: .semibold)
                Text(subtitle.uppercased()).scaledFont(12, weight: .semibold)
            }
            .foregroundStyle(Self.soft)
            .padding(.top, 3)

            HStack(alignment: .top, spacing: 0) {
                stat("Flights", "\(stats.flights)", big: true,
                     caption: stats.longHaul > 0 ? "\(stats.longHaul) Long Haul" : nil)
                    .frame(width: 112, alignment: .leading)
                stat("Distance", TravelFacts.distance(stats.distanceKm, units.distance), big: true,
                     caption: stats.distanceKm > 0 ? TravelFacts.aroundTheWorld(stats.distanceKm) : nil)
            }
            .padding(.top, 20)
            HStack(alignment: .top, spacing: 0) {
                stat("Flight Time", TravelFacts.flightTime(stats.flightTime))
                    .frame(width: 112, alignment: .leading)
                stat("Airports", "\(stats.airports)")
                    .frame(width: 84, alignment: .leading)
                stat("Airlines", "\(stats.airlines)")
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .monospacedDigit()
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let year { return "Travel record \u{00B7} \(year)" }
        guard let since else { return "Travel record" }
        return "Travel record \u{00B7} since \(since)"
    }

    private var background: some View {
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

/// The red card: time lost to delays and the average.
struct DelaysCard: View {
    var stats: PassportStats

    var body: some View {
        let lost = TravelFacts.delayLost(stats.delayLost)
        VStack(alignment: .leading, spacing: 0) {
            Text(lost.value)
                .scaledFont(64, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.bottom, -4)
            Text(lost.caption)
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(.white)
            Text(TravelFacts.averageDelayLine(stats.avgDelayMinutes))
                .scaledFont(17)
                .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.68))
                .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(colors: [Color(red: 0.62, green: 0.13, blue: 0.11), Color(red: 0.36, green: 0.07, blue: 0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.75, green: 0.30, blue: 0.24).opacity(0.5), .clear],
                               center: UnitPoint(x: 1.0, y: 1.1), startRadius: 0, endRadius: 240)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The pale card with the aircraft flown most.
struct AircraftCard: View {
    var type: String
    var count: Int

    private static let ink = Color(red: 0.11, green: 0.18, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Most flown aircraft")
                .scaledFont(20, weight: .semibold)
                .foregroundStyle(Self.ink)
            Text(TravelFacts.aircraftName(type))
                .scaledFont(32)
                .foregroundStyle(Self.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
            Text(count == 1 ? "1 flight" : "\(count) flights")
                .scaledFont(17)
                .foregroundStyle(Self.ink.opacity(0.6))
                .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "airplane")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Self.ink.opacity(0.12))
                .padding(.trailing, 22)
                .accessibilityHidden(true)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.87, green: 0.85, blue: 0.96), Color(red: 0.76, green: 0.85, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
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
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            HorizontalStrip(scrolls: !staticControls) {
                HStack(spacing: 2) {
                    ForEach(TravelFacts.Sort.allCases, id: \.self) { s in
                        Button { sort = s } label: {
                            Text(s == .date && sort == .date ? "Date \u{2193}" : s.title)
                                .scaledFont(15, weight: sort == s ? .semibold : .medium)
                                .foregroundStyle(sort == s ? Theme.primary : Theme.secondary)
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(Capsule().fill(sort == s ? Theme.pill : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(sort == s ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            ForEach(TravelFacts.groups(flights, by: sort, city: city)) { group in
                HStack {
                    Text(group.title).scaledFont(17, weight: .bold).foregroundStyle(Theme.primary)
                    Spacer()
                    Text((group.flights.count == 1 ? "1 flight" : "\(group.flights.count) flights").uppercased())
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
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
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().strokeBorder(flight.status == .canceled ? Theme.secondary : Theme.diverted,
                                                               lineWidth: 1))
                    }
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
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
