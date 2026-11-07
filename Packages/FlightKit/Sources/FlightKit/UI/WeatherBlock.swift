import SwiftUI

/// Current conditions from a METAR: big temperature and sky, the flight category card with
/// ceiling and visibility scales, wind and gusts, and how old the report is.
public struct WeatherBlock: View {
    var weather: Weather
    var timeZone: TimeZone
    var now: Date
    @Environment(\.metricsScale) private var scale

    public init(weather: Weather, timeZone: TimeZone = .current, now: Date = .now) {
        self.weather = weather; self.timeZone = timeZone; self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .scaledPadding(.bottom, 20)
            categoryCard
                .scaledPadding(.bottom, 18)
            windRow
                .scaledPadding(.horizontal, 12)
                .scaledPadding(.bottom, 14)
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack(spacing: 6) {
                Text("METAR OBSERVED \(Format.ago(weather.observedAt, now: now).uppercased())")
                Image(systemName: "chevron.right").scaledFont(11, weight: .semibold)
            }
            .scaledFont(12, design: .monospaced)
            .foregroundStyle(Theme.secondary)
            .scaledPadding(.top, 14)
        }
        .monospacedDigit()
    }

    // MARK: Temperature and sky

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 2) {
                    Text(weather.tempC.map { "\(Int($0.rounded()))" } ?? "--")
                        .scaledFont(67, weight: .regular)
                        .foregroundStyle(Theme.primary)
                    Text("°C")
                        .scaledFont(31, weight: .regular)
                        .foregroundStyle(Theme.primary)
                        .scaledPadding(.top, 8)
                }
                .scaledPadding(.bottom, -4)
                Text(Sky(metar: weather.metarRaw).description)
                    .scaledFont(16, weight: .semibold)
                    .foregroundStyle(Theme.primary)
            }
            Spacer()
            Image(systemName: Sky(metar: weather.metarRaw).symbol(night: isNight))
                .accessibilityHidden(true)
                .symbolRenderingMode(.multicolor)
                .scaledFont(62)
                .scaledPadding(.top, 4)
                .scaledPadding(.trailing, 8)
        }
    }

    private var isNight: Bool {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let h = c.component(.hour, from: weather.observedAt)
        return h < 6 || h >= 19
    }

    // MARK: Category card

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(ui: weather.category.rawValue)
                    .scaledFont(13.5, weight: .semibold)
                    .foregroundStyle(.white)
                    .scaledPadding(.horizontal, 7)
                    .scaledPadding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(weather.category.color))
                Text(ui: weather.category.name)
                    .scaledFont(16, weight: .medium)
                    .foregroundStyle(weather.category.color)
            }
            Text("\(weather.category.summary) \(Text(Image(systemName: "info.circle")).font(.system(size: Theme.fontSize(11, scale))))")
                .scaledFont(13.5)
                .foregroundStyle(Theme.secondary)
                .scaledPadding(.top, 6)
            HStack(alignment: .top, spacing: 16) {
                ScaleColumn(icon: "cloud", label: "Cloud Ceiling", value: ceilingText,
                            category: ceilingCategory, position: ceilingPosition)
                ScaleColumn(icon: "eye", label: "Visibility", value: visibilityText,
                            category: visibilityCategory, position: visibilityPosition)
            }
            .scaledPadding(.top, 16)
        }
        .scaledPadding(.all, 10)
        .scaledPadding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
    }

    private var ceilingText: (String, String?) {
        guard let ft = weather.ceilingFt else { return ("None", nil) }
        return (ft.formatted(.number.grouping(.automatic)), "FT")
    }

    private var visibilityText: (String, String?) {
        guard let sm = weather.visibilitySm else { return ("--", nil) }
        let km = sm * 1.609
        if sm >= 10 { return ("16+", "KM") }
        return (km < 10 ? String(format: "%.1f", km) : "\(Int(km.rounded()))", "KM")
    }

    private var ceilingCategory: FlightCategory {
        guard let ft = weather.ceilingFt else { return .VFR }
        return ft < 500 ? .LIFR : ft < 1000 ? .IFR : ft <= 3000 ? .MVFR : .VFR
    }

    private var visibilityCategory: FlightCategory {
        guard let sm = weather.visibilitySm else { return .VFR }
        return sm < 1 ? .LIFR : sm < 3 ? .IFR : sm <= 5 ? .MVFR : .VFR
    }

    /// 0...1 along the four equal segments (LIFR, IFR, MVFR, VFR).
    private var ceilingPosition: Double {
        guard let ft = weather.ceilingFt else { return 1 }
        return ScaleColumn.position(Double(ft), edges: [0, 500, 1000, 3000, 12000])
    }

    private var visibilityPosition: Double {
        guard let sm = weather.visibilitySm else { return 1 }
        return ScaleColumn.position(sm, edges: [0, 1, 3, 5, 10])
    }

    // MARK: Wind

    private var windRow: some View {
        HStack(alignment: .top, spacing: 16) {
            WindColumn(label: "Wind", knots: weather.windKt, compassDeg: weather.windDirDeg)
            WindColumn(label: "Gusts", knots: weather.gustKt, compassDeg: nil)
        }
    }
}

// MARK: - Pieces

private struct ScaleColumn: View {
    var icon: String
    var label: String
    var value: (String, String?)
    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var unitSize: CGFloat = 14
    @Environment(\.metricsScale) private var scale
    var category: FlightCategory
    var position: Double

    static func position(_ v: Double, edges: [Double]) -> Double {
        for i in 0..<(edges.count - 1) where v < edges[i + 1] {
            let t = (v - edges[i]) / (edges[i + 1] - edges[i])
            return (Double(i) + max(0, min(1, t))) / Double(edges.count - 1)
        }
        return 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon).scaledFont(12)
                Text(ui: label).scaledFont(13.5)
            }
            .foregroundStyle(Theme.secondary)
            Group {
                if let unit = value.1 {
                    Text("\(Text("\(value.0) ").font(.system(size: Theme.fontSize(valueSize, scale), weight: .semibold)))\(Text(ui: unit).font(.system(size: Theme.fontSize(unitSize, scale), weight: .semibold)))")
                } else {
                    Text(ui: value.0).font(.system(size: Theme.fontSize(valueSize, scale), weight: .semibold))
                }
            }
                .foregroundStyle(Theme.primary)
                .scaledPadding(.top, 1)
            GeometryReader { geo in
                let gap: CGFloat = 2.5
                let seg = (geo.size.width - gap * 3) / 4
                let knobX = min(geo.size.width - 4, max(4, geo.size.width * position))
                ZStack(alignment: .leading) {
                    HStack(spacing: gap) {
                        ForEach(FlightCategory.scale, id: \.self) { c in
                            Capsule().fill(c.color).frame(width: seg, height: 3)
                        }
                    }
                    Circle()
                        .strokeBorder(category.color, lineWidth: 2)
                        .background(Circle().fill(Theme.card))
                        .frame(width: 8, height: 8)
                        .offset(x: knobX - 4)
                    let idx = CGFloat(FlightCategory.scale.firstIndex(of: category) ?? 3)
                    Text(ui: category.rawValue)
                        .scaledFont(12, weight: .medium)
                        .foregroundStyle(category.color)
                        .frame(width: seg, alignment: .trailing)
                        .offset(x: idx * (seg + gap), y: 14)
                }
            }
            .frame(height: 8)
            .scaledPadding(.top, 8)
            .scaledPadding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WindColumn: View {
    var label: String
    var knots: Int?
    var compassDeg: Int?

    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var unitSize: CGFloat = 14
    @Environment(\.metricsScale) private var scale

    private var kmh: Int? { knots.map { Int((Double($0) * 1.852).rounded()) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "wind").scaledFont(12)
                        Text(ui: label).scaledFont(13.5)
                    }
                    .foregroundStyle(Theme.secondary)
                    if let kmh {
                        Text("\(Text("\(kmh) ").font(.system(size: Theme.fontSize(valueSize, scale), weight: .semibold)))\(Text("KM/H").font(.system(size: Theme.fontSize(unitSize, scale), weight: .semibold)))")
                            .foregroundStyle(Theme.primary)
                    } else {
                        Text("None").scaledFont(17, weight: .semibold).foregroundStyle(Theme.primary)
                    }
                }
                Spacer(minLength: 0)
                if let compassDeg { Compass(degrees: Double(compassDeg)).frame(width: 30, height: 30).scaledPadding(.top, 2) }
            }
            Ticks(fraction: Double(kmh ?? 0) / 100)
                .frame(height: 6)
                .scaledPadding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of thin ticks, the first `fraction` of them lit.
private struct Ticks: View {
    var fraction: Double

    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 1.5, gap: CGFloat = 1.3
            let n = Int((size.width + gap) / (w + gap))
            let lit = Int((Double(n) * min(1, max(0, fraction))).rounded())
            for i in 0..<n {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 0.5), with: .color(i < lit ? Theme.wind : Theme.tickOff))
            }
        }
    }
}

/// Ring of ticks with an arrow showing where the wind blows from.
private struct Compass: View {
    var degrees: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            for i in 0..<36 {
                let a = Double(i) * .pi / 18
                var p = Path()
                p.move(to: CGPoint(x: c.x + (r - 3) * sin(a), y: c.y - (r - 3) * cos(a)))
                p.addLine(to: CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a)))
                ctx.stroke(p, with: .color(Theme.secondary.opacity(0.6)), lineWidth: 0.8)
            }
            // Arrow from the windward side towards the centre and through.
            let a = degrees * .pi / 180
            let from = CGPoint(x: c.x + (r - 6) * sin(a), y: c.y - (r - 6) * cos(a))
            let to = CGPoint(x: c.x - (r - 6) * sin(a), y: c.y + (r - 6) * cos(a))
            var shaft = Path()
            shaft.move(to: from); shaft.addLine(to: to)
            ctx.stroke(shaft, with: .color(Theme.wind), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let head: CGFloat = 4
            var tip = Path()
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x + head * sin(a + 0.5), y: to.y - head * cos(a + 0.5)))
            tip.move(to: to)
            tip.addLine(to: CGPoint(x: to.x + head * sin(a - 0.5), y: to.y - head * cos(a - 0.5)))
            ctx.stroke(tip, with: .color(Theme.wind), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}

// MARK: - METAR sky reading

/// Plain-language sky from the METAR body: weather phenomena first, else the densest cloud layer.
struct Sky {
    enum Kind { case clear, few, scattered, broken, overcast, rain, drizzle, snow, thunder, fog, mist }
    var kind: Kind

    init(metar: String) {
        // Station and time come first; weather groups look like "-RA", "+TSRA", "VCSH", "BR".
        let tokens = metar.split(separator: " ").dropFirst(2).map(String.init)
        var codes = ""
        for t in tokens {
            if let m = t.wholeMatch(of: /(?:\+|-|VC)?(MI|PR|BC|DR|BL|SH|TS|FZ)?((?:DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ)*)/),
               !(m.1 == nil && m.2.isEmpty) {
                codes += (m.1.map(String.init) ?? "") + String(m.2)
            }
        }
        func has(_ c: String) -> Bool { codes.contains(c) }
        if has("TS") { kind = .thunder }
        else if has("SN") || has("SG") || has("PL") { kind = .snow }
        else if has("RA") || has("SH") { kind = .rain }
        else if has("DZ") { kind = .drizzle }
        else if has("FG") { kind = .fog }
        else if has("BR") || has("HZ") || has("FU") { kind = .mist }
        else {
            let order: [(String, Kind)] = [("OVC", .overcast), ("VV", .overcast), ("BKN", .broken), ("SCT", .scattered), ("FEW", .few)]
            kind = order.first { code, _ in
                tokens.contains { $0.hasPrefix(code) && $0.dropFirst(code.count).first?.isNumber == true }
            }?.1 ?? .clear
        }
    }

    var description: String {
        switch kind {
        case .clear: "Clear Sky"
        case .few: "Few Clouds"
        case .scattered: "Scattered Clouds"
        case .broken: "Mostly Cloudy"
        case .overcast: "Overcast"
        case .rain: "Rain"
        case .drizzle: "Drizzle"
        case .snow: "Snow"
        case .thunder: "Thunderstorms"
        case .fog: "Fog"
        case .mist: "Mist"
        }
    }

    func symbol(night: Bool) -> String {
        switch kind {
        case .clear: night ? "moon.stars.fill" : "sun.max.fill"
        case .few, .scattered: night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .broken, .overcast: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        case .fog, .mist: "cloud.fog.fill"
        }
    }
}

extension FlightCategory {
    static let scale: [FlightCategory] = [.LIFR, .IFR, .MVFR, .VFR]

    var color: Color {
        switch self {
        case .VFR: Theme.vfr
        case .MVFR: Theme.mvfr
        case .IFR: Theme.ifr
        case .LIFR: Theme.lifr
        }
    }

    var name: String {
        switch self {
        case .VFR: "Visual Flight Rules"
        case .MVFR: "Marginal VFR"
        case .IFR: "Instrument Flight Rules"
        case .LIFR: "Low IFR"
        }
    }

    var summary: String {
        switch self {
        case .VFR: "Good ceiling and visibility. Normal flows."
        case .MVFR: "Lower clouds or haze. Short delays are possible."
        case .IFR: "Low clouds or poor visibility. Expect slower flows."
        case .LIFR: "Very low clouds or visibility. Delays are likely."
        }
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader("Current Weather", subtitle: "Observed at AUS", large: true)
            WeatherBlock(weather: PreviewData.weather["KAUS"]!, timeZone: PreviewData.kaus.timeZone, now: PreviewData.now)
        }
        .scaledPadding(.all, 20)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
