import SwiftUI
import Charts
import ImageIO
import UniformTypeIdentifiers
import FlightCore

/// A capsule "Share" that hands over `content` as a PNG (phone width, dark, on the page colour). Nothing is
/// built or rendered until the share sheet asks for the file, so the image is the section as it is at that
/// moment (the chosen year and chart tab).
struct SectionShareButton<Content: View>: View {
    var title: String
    var content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }

    @Environment(\.units) private var units
    @Environment(\.displayScale) private var displayScale
    @Environment(\.reference) private var reference

    var body: some View {
        ShareLink(item: SectionSnapshot(source: SectionRenderer(page: { AnyView(page) }, scale: max(displayScale, 2))),
                  preview: SharePreview(title, image: Image(systemName: "square.and.arrow.up"))) { label }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(title)")
    }

    private var label: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.and.arrow.up").scaledFont(15, weight: .medium)
            Text("Share").scaledFont(16, weight: .semibold)
        }
        .foregroundStyle(Theme.primary)
        .scaledPadding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
        .contentShape(Capsule())
    }

    private var page: some View {
        Self.sharePage(title: title, units: units, reference: reference, content: content)
    }

    /// The shared image: title, the section and the app's name at phone width, always dark whatever the
    /// screen's own scheme (the scheme is set inside the rendered content, so it holds off screen too).
    static func sharePage(title: String, units: Units, reference: ReferenceData,
                          content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).scaledFont(22, weight: .semibold).foregroundStyle(Theme.primary)
            content()
            Text("Soma Flight Passport").scaledFont(13, weight: .medium).foregroundStyle(Theme.secondary)
        }
        .frame(width: 361, alignment: .leading)
        .padding(16)
        .background(Theme.background)
        .environment(\.units, units)
        .environment(\.reference, reference)
        .environment(\.colorScheme, .dark)
    }
}

/// Builds and renders a section to PNG on demand, on the main actor.
@MainActor final class SectionRenderer {
    let page: () -> AnyView
    let scale: CGFloat

    init(page: @escaping () -> AnyView, scale: CGFloat) { self.page = page; self.scale = scale }

    func png() -> Data? {
        let renderer = ImageRenderer(content: page())
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// What a section's Share hands over: a PNG made only when the receiver asks for it.
struct SectionSnapshot: Transferable {
    let source: SectionRenderer

    struct RenderFailed: Error {}

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { snapshot in
            guard let data = await snapshot.source.png() else { throw RenderFailed() }
            return data
        }
    }
}

/// One Passport section: title and Share on one line, then the body, with a full width hairline above.
struct PassportSection<Content: View>: View {
    var title: String
    /// Called for the page, and again only when Share asks for the image.
    var content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(title)
                        .scaledFont(20, weight: .semibold)
                        .foregroundStyle(Theme.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    SectionShareButton(title: title, content: content)
                }
                content().scaledPadding(.top, 6)
            }
            .scaledPadding(.horizontal, 16)
            .scaledPadding(.top, 28)
            .scaledPadding(.bottom, 28)
        }
    }
}

/// "359h 8m" or "280,017 km": numbers large, units smaller and grey.
/// Both sizes follow Dynamic Type (scaled like the large title) and the Mac's metrics scale; a line too long
/// for its width shrinks to fit.
struct UnitNumber: View {
    var parts: [(number: String, unit: String)]
    var weight: Font.Weight
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var unitSize: CGFloat
    @Environment(\.metricsScale) private var scale

    init(parts: [(number: String, unit: String)], size: CGFloat, unitSize: CGFloat, weight: Font.Weight = .bold) {
        self.parts = parts; self.weight = weight
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
        _unitSize = ScaledMetric(wrappedValue: unitSize, relativeTo: .largeTitle)
    }

    var body: some View {
        let size = Theme.fontSize(size, scale), unitSize = Theme.fontSize(unitSize, scale)
        return parts.enumerated().reduce(Text("")) { text, item in
            let (i, p) = item
            let number = Text((i > 0 ? " " : "") + p.number).font(.system(size: size, weight: weight))
                .foregroundStyle(Theme.primary)
            let unit = Text(p.unit).font(.system(size: unitSize, weight: .regular)).foregroundStyle(Theme.secondary)
            return Text("\(text)\(number)\(unit)")
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

// MARK: Flights

struct PassportFlightsSection: View {
    var detail: PassportDetail
    @State private var period: PassportFacts.Period = .weekday

    var body: some View {
        PassportSection(title: "Flights") { FlightsBody(detail: detail, period: $period) }
    }
}

private struct FlightsBody: View {
    var detail: PassportDetail
    @Binding var period: PassportFacts.Period

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PassportFacts.count(detail.flights))
                .scaledFont(46, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 2) {
                line(detail.domestic, "domestic")
                line(detail.international, "international")
                line(detail.longHaul, "long haul")
            }
            HStack(spacing: 4) {
                Text("FLIGHTS PER")
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .scaledPadding(.trailing, 10)
                ForEach(PassportFacts.Period.allCases) { p in
                    Button { period = p } label: {
                        Text(p.rawValue)
                            .scaledFont(15, weight: .medium)
                            .foregroundStyle(p == period ? Theme.primary : Theme.secondary)
                            .scaledPadding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(p == period ? Theme.pill : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(p == period ? .isSelected : [])
                }
            }
            .scaledPadding(.top, 22)
            chart.scaledPadding(.top, 22)
        }
    }

    private func line(_ n: UInt32, _ label: String) -> some View {
        let number = Text(PassportFacts.count(n)).fontWeight(.semibold).foregroundStyle(Theme.primary)
        return Text("\(number) \(Text(label).foregroundStyle(Theme.secondary))")
            .scaledFont(17)
            .monospacedDigit()
    }

    private var chart: some View {
        let bars = PassportFacts.bars(detail, period)
        let ticks = PassportFacts.ticks(max: bars.map(\.count).max() ?? 0)
        return Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
            BarMark(x: .value("Period", bar.label), y: .value("Flights", bar.count), width: .ratio(0.42))
                .foregroundStyle(Theme.passportAccent)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
        }
        .chartYScale(domain: 0...ticks.top)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks.values) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.grid)
                AxisValueLabel().font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        .chartXAxis {
            AxisMarks { AxisValueLabel().font(.system(size: 15)).foregroundStyle(Theme.primary) }
        }
        .frame(height: 180)
        .accessibilityLabel("Flights per \(period.rawValue.lowercased())")
        .accessibilityValue(bars.map { "\($0.label) \($0.count)" }.joined(separator: ", "))
    }
}

// MARK: Distance

struct PassportDistanceSection: View {
    var detail: PassportDetail
    var lookup: (String) -> Airport?
    @Environment(\.units) private var units

    var body: some View {
        PassportSection(title: "Flight distance") {
            VStack(alignment: .leading, spacing: 0) {
                totals
                VStack(spacing: 12) {
                    ForEach(Array(PassportFacts.ratios(detail).enumerated()), id: \.offset) { i, r in
                        RatioBar(symbol: r.symbol, tint: RatioBar.tints[i], value: r.value, label: r.label, fill: r.fill)
                    }
                }
                .scaledPadding(.top, 20)
                if PassportFacts.showsExtremes(detail) {
                    ExtremeBlock(title: "Shortest flight", flight: detail.shortestByDistance, lookup: lookup) {
                        TravelFacts.distance(Int($0.distanceKm), units.distance)
                    }
                    ExtremeBlock(title: "Longest flight", flight: detail.longestByDistance, lookup: lookup) {
                        TravelFacts.distance(Int($0.distanceKm), units.distance)
                    }
                }
            }
        }
    }

    private var totals: some View {
        let km = Int(detail.distanceKm)
        let other: DistanceUnit = units.distance == .km ? .mi : .km
        let main = TravelFacts.distanceParts(km, units.distance)
        return VStack(alignment: .leading, spacing: 2) {
            UnitNumber(parts: [(main.number, " " + main.unit)], size: 46, unitSize: 32)
            Text(TravelFacts.distance(km, other))
                .scaledFont(21)
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
            Text("Average distance: \(TravelFacts.distance(Int(detail.avgDistanceKm), units.distance))")
                .scaledFont(16)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 4)
        }
    }
}

/// A grey capsule filled in violet up to the multiple (full from 1x), the body's glyph at its left and
/// "7.0x around the Earth" at its right.
struct RatioBar: View {
    var symbol: String
    var tint: Color
    var value: String
    var label: String
    var fill: Double
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 40

    static let tints = [Color(red: 0.30, green: 0.62, blue: 0.95), Color(red: 0.80, green: 0.80, blue: 0.82),
                        Color(red: 0.98, green: 0.72, blue: 0.22)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let filled = fill <= 0 ? 0 : max(height, w * min(fill, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(red: 0x26 / 255, green: 0x27 / 255, blue: 0x2A / 255))
                Capsule().fill(Theme.passportAccent).frame(width: filled)
                Image(systemName: symbol)
                    .font(.system(size: height * 0.52))
                    .foregroundStyle(tint)
                    .frame(width: height - 6, height: height - 6)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .padding(.leading, 3)
                HStack(spacing: 0) {
                    Spacer()
                    Text("\(Text(value).fontWeight(.semibold)) \(Text(label).foregroundStyle(Theme.primary.opacity(0.85)))")
                        .foregroundStyle(Theme.primary)
                        .scaledFont(16)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.trailing, 16)
                .padding(.leading, height + 8)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(value) \(label)")
    }
}

/// "Shortest flight" and its row: airline badge, cities with an arrow, flight number and date, the figure.
struct ExtremeBlock: View {
    var title: String
    var flight: FlightRef?
    var lookup: (String) -> Airport?
    var figure: (FlightRef) -> String

    var body: some View {
        if let flight {
            VStack(alignment: .leading, spacing: 14) {
                Rectangle().fill(Theme.separator).frame(height: 1)
                Text(title).scaledFont(18).foregroundStyle(Theme.primary).scaledPadding(.top, 8)
                row(flight)
            }
            .scaledPadding(.top, 20)
        }
    }

    private func row(_ f: FlightRef) -> some View {
        let from = lookup(f.originIcao), to = lookup(f.destinationIcao)
        let code = TravelFacts.airlineCode(ident: f.ident)
        let date = PassportFacts.shortDate(f.departedAt, timeZone: from?.timeZone ?? .gmt)
        return HStack(spacing: 14) {
            AirlineMark(code: code, key: f.airline ?? code)
            VStack(alignment: .leading, spacing: 2) {
                let arrow = Text(Image(systemName: "arrow.right.circle.fill")).font(.system(size: 15))
                Text("\(from?.city ?? f.originIcao)  \(arrow)  \(to?.city ?? f.destinationIcao)")
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(PassportFacts.spacedIdent(f.ident)) \u{2022} \(date)")
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(figure(f))
                .scaledFont(18)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Time

struct PassportTimeSection: View {
    var detail: PassportDetail
    var lookup: (String) -> Airport?

    var body: some View {
        PassportSection(title: "Flight time") {
            VStack(alignment: .leading, spacing: 0) {
                UnitNumber(parts: PassportFacts.hoursMinutes(detail.flightMinutes), size: 46, unitSize: 36)
                grid.scaledPadding(.top, 18)
                if PassportFacts.showsExtremes(detail) {
                    ExtremeBlock(title: "Shortest flight", flight: detail.shortestByTime, lookup: lookup) {
                        Self.text($0.blockMinutes)
                    }
                    ExtremeBlock(title: "Longest flight", flight: detail.longestByTime, lookup: lookup) {
                        Self.text($0.blockMinutes)
                    }
                }
            }
        }
    }

    /// "1h 9m"; "-" when the flight has no block time.
    nonisolated static func text(_ minutes: UInt32?) -> String {
        guard let minutes else { return "-" }
        return PassportFacts.hoursMinutes(UInt64(minutes)).map { $0.number + $0.unit }.joined(separator: " ")
    }

    private var grid: some View {
        var cells: [(String, AnyView)] = PassportFacts.timeUnits(minutes: detail.flightMinutes).map { u in
            (u.label, AnyView(Text(u.value).scaledFont(22, weight: .semibold).monospacedDigit().foregroundStyle(Theme.primary)))
        }
        func hm(_ m: UInt64) -> AnyView { AnyView(UnitNumber(parts: PassportFacts.hoursMinutes(m), size: 22, unitSize: 19, weight: .semibold)) }
        cells.append(("Avg. flight time", hm(detail.avgFlightMinutes)))
        if detail.airMinutes + detail.taxiMinutes > 0 {
            cells.append(("In air", hm(detail.airMinutes)))
            cells.append(("Taxiing", hm(detail.taxiMinutes)))
        }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { i in
                GridRow {
                    cell(cells[i])
                    if i + 1 < cells.count { cell(cells[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func cell(_ c: (String, AnyView)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.0).scaledFont(14).foregroundStyle(Theme.secondary)
            c.1
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
