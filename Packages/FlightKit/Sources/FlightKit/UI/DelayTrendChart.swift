import Charts
import SwiftUI

/// Average delay over time from a board's flights, drawn by `DelayTrendPlot`: the current average big
/// over one amber curve up to now, a dashed estimate after it, and a "Now" dot on the curve.
public struct DelayTrendChart: View {
    var flights: [Flight]
    var kind: BoardKind
    var timeZone: TimeZone
    var now: Date
    var binMinutes: Int
    var windowMinutes: Int

    /// - Parameters:
    ///   - binMinutes: one point per this many minutes.
    ///   - windowMinutes: each point averages the flights scheduled within this window centred on
    ///     it (a rolling mean, so thin boards still read as a trend). Defaults to the bin itself.
    public init(flights: [Flight], kind: BoardKind, timeZone: TimeZone = .current, now: Date = .now,
                binMinutes: Int = 60, windowMinutes: Int? = nil) {
        self.flights = flights; self.kind = kind; self.timeZone = timeZone; self.now = now
        self.binMinutes = max(5, binMinutes)
        self.windowMinutes = max(self.binMinutes, windowMinutes ?? binMinutes)
    }

    struct Bin: Identifiable {
        var id: Date { start }
        var start: Date
        var minutes: Double?
    }

    private var binLength: TimeInterval { TimeInterval(binMinutes * 60) }

    private func binStart(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / binLength).rounded(.down) * binLength)
    }

    /// Contiguous bins from the first to the last scheduled flight, each the mean delay of the
    /// flights in its window (nil when the window holds none).
    var bins: [Bin] {
        let points: [(at: Date, minutes: Double)] = flights.compactMap { f in
            guard f.status != .canceled else { return nil }
            let scheduled = kind == .arrivals ? f.scheduledIn : f.scheduledOut
            let delay = kind == .arrivals ? f.arrivalDelay : f.departureDelay
            guard let scheduled, let delay else { return nil }
            return (scheduled, max(0, Double(delay.components.seconds) / 60))
        }
        guard let lo = points.map({ binStart($0.at) }).min(), let hi = points.map({ binStart($0.at) }).max() else { return [] }
        let half = TimeInterval(windowMinutes * 60) / 2
        return stride(from: lo.timeIntervalSince1970, through: hi.timeIntervalSince1970, by: binLength).map {
            let d = Date(timeIntervalSince1970: $0)
            let mid = d.addingTimeInterval(binLength / 2)
            let inside = points.filter { $0.at >= mid.addingTimeInterval(-half) && $0.at < mid.addingTimeInterval(half) }
            return Bin(start: d, minutes: inside.isEmpty ? nil : inside.reduce(0) { $0 + $1.minutes } / Double(inside.count))
        }
    }

    /// One point per bin with data, placed at the bin's middle.
    var samples: [DelayTrendPlot.Sample] {
        bins.compactMap { b in
            b.minutes.map { DelayTrendPlot.Sample(at: b.start.addingTimeInterval(binLength / 2), minutes: $0) }
        }
    }

    public var body: some View {
        DelayTrendPlot(samples: samples, timeZone: timeZone, now: now)
    }

    /// "18" on the 24-hour clock, "6 PM" on the 12-hour one.
    static func hourLabel(_ hour: Int, _ style: TimeStyle) -> String {
        guard style == .h12 else { return "\(hour)" }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }
}

/// The delay trend drawing shared by `DelayTrendChart` (own board) and `LiveTrendChart` (provider):
/// the current average big with its direction, one amber area and line up to now, a dashed estimate
/// after now, faint 15m and 45m rules, a "Now" rule with a dot on the curve, hour labels every two
/// hours in the airport's time zone, and an Actual / Estimated legend. No y axis.
struct DelayTrendPlot: View {
    struct Sample: Hashable {
        var at: Date
        var minutes: Double
    }

    private struct Point: Identifiable {
        var id: String { "\(series)-\(at.timeIntervalSince1970)" }
        var at: Date
        var minutes: Double
        var series: String
    }

    @Environment(\.units) private var units
    var samples: [Sample]
    var timeZone: TimeZone
    var now: Date

    /// Change over the last hour, in minutes, under which the trend reads as steady.
    static let steadyBand: Double = 3

    private var sorted: [Sample] { samples.sorted { $0.at < $1.at } }

    /// The value at `t` on the polyline through the samples (nil outside their span). The curve is
    /// drawn through the same point, so the "Now" dot sits on it.
    static func value(at t: Date, in s: [Sample]) -> Double? {
        guard let first = s.first, let last = s.last, t >= first.at, t <= last.at else { return nil }
        guard let j = s.firstIndex(where: { $0.at >= t }) else { return last.minutes }
        if s[j].at == t || j == 0 { return s[j].minutes }
        let a = s[j - 1], b = s[j]
        let f = t.timeIntervalSince(a.at) / b.at.timeIntervalSince(a.at)
        return a.minutes + (b.minutes - a.minutes) * f
    }

    /// The current value on the curve, or the last flown point when now is past the data.
    static func current(_ s: [Sample], now: Date) -> Double? {
        value(at: now, in: s) ?? s.last(where: { $0.at <= now })?.minutes
    }

    enum Direction { case rising, falling, steady }

    static func direction(_ s: [Sample], now: Date) -> Direction {
        guard let cur = current(s, now: now) else { return .steady }
        let t = min(now, s.last?.at ?? now)
        let earlier = value(at: t.addingTimeInterval(-3600), in: s) ?? s.first?.minutes ?? cur
        let delta = cur - earlier
        if delta >= steadyBand { return .rising }
        if delta <= -steadyBand { return .falling }
        return .steady
    }

    /// Actual points up to now, estimated points from now on; both carry the point at now.
    private func points(_ s: [Sample], nowValue: Double?) -> [Point] {
        var actual = s.filter { $0.at < now }.map { Point(at: $0.at, minutes: $0.minutes, series: "actual") }
        var estimated = s.filter { $0.at > now }.map { Point(at: $0.at, minutes: $0.minutes, series: "estimated") }
        if let nowValue {
            actual.append(Point(at: now, minutes: nowValue, series: "actual"))
            estimated.insert(Point(at: now, minutes: nowValue, series: "estimated"), at: 0)
        }
        return actual + estimated
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Whole even hours in the airport's time zone inside the span.
    private func ticks(_ lo: Date, _ hi: Date) -> [Date] {
        guard var t = calendar.dateInterval(of: .hour, for: lo)?.start else { return [] }
        var out: [Date] = []
        while t <= hi {
            if t >= lo, calendar.component(.hour, from: t) % 2 == 0 { out.append(t) }
            t = t.addingTimeInterval(3600)
        }
        return out
    }

    private func tickLabel(_ d: Date) -> String {
        let h = calendar.component(.hour, from: d)
        return units.clock == .h12 ? DelayTrendChart.hourLabel(h, .h12) : "\(h):00"
    }

    private func directionText(_ d: Direction) -> Text {
        switch d {
        case .rising: return Text("average now, rising")
        case .falling: return Text("average now, falling")
        case .steady: return Text("average now, steady")
        }
    }

    var body: some View {
        let s = sorted
        let nowValue = Self.value(at: now, in: s)
        let current = Self.current(s, now: now)
        let pts = points(s, nowValue: nowValue)
        let lo = s.first?.at ?? now, hi = s.last?.at ?? now
        let peak = s.map(\.minutes).max() ?? 0
        let yTop = max(Double(AirportStatus.majorDelay) + 8, peak * 1.12)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(current.map { Format.minutes(Int($0.rounded())) } ?? "--")
                    .scaledFont(28, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)
                directionText(Self.direction(s, now: now))
                    .scaledFont(15)
                    .foregroundStyle(Theme.secondary)
            }
            Chart {
                RuleMark(y: .value("Late", AirportStatus.minorDelay))
                    .foregroundStyle(Theme.trendAmber.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: "\(AirportStatus.minorDelay)m").scaledFont(11).foregroundStyle(Theme.secondary)
                    }
                RuleMark(y: .value("Major", AirportStatus.majorDelay))
                    .foregroundStyle(Theme.splitRed.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: "\(AirportStatus.majorDelay)m").scaledFont(11).foregroundStyle(Theme.secondary)
                    }
                ForEach(pts.filter { $0.series == "actual" }) { p in
                    AreaMark(x: .value("Time", p.at), y: .value("Delay", p.minutes), series: .value("Series", p.series))
                        .foregroundStyle(LinearGradient(colors: [Theme.trendAmber.opacity(0.35), Theme.trendAmber.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.at), y: .value("Delay", p.minutes), series: .value("Series", p.series))
                        .foregroundStyle(Theme.trendAmber)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(pts.filter { $0.series == "estimated" }) { p in
                    LineMark(x: .value("Time", p.at), y: .value("Delay", p.minutes), series: .value("Series", p.series))
                        .foregroundStyle(Theme.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                        .interpolationMethod(.monotone)
                }
                if let nowValue {
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(Theme.primary.opacity(0.35))
                    PointMark(x: .value("Now", now), y: .value("Delay", nowValue))
                        .symbolSize(70)
                        .foregroundStyle(Theme.trendAmber)
                        .annotation(position: .top, spacing: 4) {
                            Text("Now").scaledFont(12, weight: .semibold).foregroundStyle(Theme.primary)
                        }
                }
            }
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...yTop)
            .chartXScale(domain: lo...max(hi, lo.addingTimeInterval(60)))
            .chartXAxis {
                AxisMarks(values: ticks(lo, hi)) { value in
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(verbatim: tickLabel(d)).scaledFont(12).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .frame(height: 170)
            .scaledPadding(.top, 10)
            HStack(spacing: 14) {
                legend("Actual", Theme.trendAmber)
                legend("Estimated", Theme.secondary)
            }
            .scaledPadding(.top, 4)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Average delay over time")
        .accessibilityValue(accessibilitySummary(s))
    }

    private func legend(_ title: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(title).scaledFont(12).foregroundStyle(Theme.secondary)
        }
    }

    /// "Now 30m on average, rising. Worst 1h 5m at 09:00."
    func accessibilitySummary(_ s: [Sample]) -> String {
        guard let worst = s.max(by: { $0.minutes < $1.minutes }) else { return "No delay data" }
        let dir: String
        switch Self.direction(s, now: now) {
        case .rising: dir = "rising"
        case .falling: dir = "falling"
        case .steady: dir = "steady"
        }
        let nowPart = Self.current(s, now: now).map { "Now \(Format.minutes(Int($0.rounded()))) on average, \(dir). " } ?? ""
        return nowPart + "Worst \(Format.minutes(Int(worst.minutes.rounded()))) at \(Format.clock(worst.at, timeZone, units.clock))."
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 18) {
        SectionHeader("Departure delays", subtitle: "Average, actual then estimated")
        DelayTrendChart(flights: PreviewData.board("KAUS", .departures).flights, kind: .departures,
                        timeZone: PreviewData.kaus.timeZone, now: PreviewData.now)
    }
    .scaledPadding(.all, 16)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
