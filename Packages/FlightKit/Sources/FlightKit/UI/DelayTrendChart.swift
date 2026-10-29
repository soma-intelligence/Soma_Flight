import SwiftUI

/// Average delay over time from a board's flights: actual delays up to now in amber or red,
/// estimated delays after now dimmed, a "Now" rule with the current value above it, and a
/// right-hand duration axis.
public struct DelayTrendChart: View {
    @Environment(\.units) private var units
    var flights: [Flight]
    var kind: BoardKind
    var timeZone: TimeZone
    var now: Date
    var binMinutes: Int
    var windowMinutes: Int

    /// - Parameters:
    ///   - binMinutes: one bar per this many minutes.
    ///   - windowMinutes: each bar averages the flights scheduled within this window centred on
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

    static let plotHeight: CGFloat = 166
    static let axisWidth: CGFloat = 52
    static let top: CGFloat = 26

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

    private var nowBin: Date { binStart(now) }

    private var step: Int {
        let peak = bins.compactMap(\.minutes).max() ?? 0
        return peak <= 100 ? 20 : (peak <= 180 ? 30 : 60)
    }

    private var axisMax: Int {
        let peak = bins.compactMap(\.minutes).max() ?? 0
        return max(step * 3, Int((peak / Double(step)).rounded(.up)) * step)
    }

    /// Bars after now are dimmed; before, the scale starts at amber like the reference
    /// (under 15 min is a quiet neutral, not green).
    private func color(_ bin: Bin) -> Color {
        bin.start > nowBin ? Theme.trendFuture : level(bin.minutes ?? 0)
    }

    private func level(_ m: Double) -> Color {
        if m >= 45 { return Theme.splitRed }
        if m >= 15 { return Theme.trendAmber }
        return Theme.trendCalm
    }

    private func axisLabel(_ m: Int) -> String {
        m == 0 ? "0m" : Format.minutes(m)
    }

    public var body: some View {
        let bins = self.bins
        let h = Self.plotHeight
        let topValue = CGFloat(axisMax)
        GeometryReader { geo in
            let plotWidth = geo.size.width - Self.axisWidth
            let slot = plotWidth / CGFloat(max(1, bins.count))
            let barWidth = min(8, slot * 0.6)
            let base = Self.top + h
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: 0, through: axisMax, by: step)), id: \.self) { v in
                    let y = base - h * CGFloat(v) / topValue
                    Rectangle().fill(Theme.grid).frame(width: plotWidth + 4, height: 1).offset(x: -4, y: y)
                    Text(axisLabel(v))
                        .scaledFont(11)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .offset(x: plotWidth + 8, y: y - 8)
                }
                ForEach(Array(bins.enumerated()), id: \.element.id) { i, bin in
                    if let m = bin.minutes {
                        let bh = max(2, h * CGFloat(m) / topValue)
                        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                            .fill(color(bin))
                            .frame(width: barWidth, height: bh)
                            .offset(x: slot * (CGFloat(i) + 0.5) - barWidth / 2, y: base - bh)
                    }
                }
                if let i = bins.firstIndex(where: { $0.start == nowBin }) {
                    let x = slot * (CGFloat(i) + 0.5)
                    let m = Int((bins[i].minutes ?? 0).rounded())
                    let marker = level(bins[i].minutes ?? 0)
                    Rectangle().fill(Theme.secondary.opacity(0.6)).frame(width: 1, height: h)
                        .offset(x: x - 0.5, y: Self.top)
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(marker.opacity(0.25)).frame(width: 14, height: 14)
                            Circle().fill(marker).frame(width: 6, height: 6)
                        }
                        Text(axisLabel(m))
                            .scaledFont(14.5, weight: .semibold)
                            .foregroundStyle(marker == Theme.trendCalm ? Theme.secondary : marker)
                    }
                    .fixedSize()
                    .frame(width: 120)
                    .offset(x: x - 60 - 10, y: Self.top - 24)
                }
                // Hour labels under the axis; "Now" replaces the label of the current bin.
                ForEach(Array(bins.enumerated()), id: \.element.id) { i, bin in
                    let isNow = bin.start == nowBin
                    if isNow || labelled(bin.start) {
                        Text(isNow ? "Now" : hourLabel(bin.start))
                            .scaledFont(12, weight: isNow ? .bold : .regular)
                            .foregroundStyle(isNow ? Theme.primary : Theme.secondary)
                            .fixedSize()
                            .frame(width: 44)
                            .offset(x: slot * (CGFloat(i) + 0.5) - 22, y: base + 7)
                    }
                }
            }
        }
        .frame(height: Self.top + h + 28)
        .monospacedDigit()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Average delay over time")
        .accessibilityValue(accessibilitySummary)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Whole hours get a label, every other one when bins are hourly and many.
    private func labelled(_ d: Date) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        guard c.minute == 0 else { return false }
        // Keep clear of the "Now" label, whatever the bin size.
        if abs(d.timeIntervalSince(nowBin)) < max(binLength * 1.5, 45 * 60) { return false }
        if binMinutes >= 60 && bins.count > 8 { return (c.hour ?? 0) % 2 == 0 && abs(d.timeIntervalSince(nowBin)) > binLength * 1.5 }
        return abs(d.timeIntervalSince(nowBin)) > binLength * 1.5 || binMinutes < 60
    }

    private func hourLabel(_ d: Date) -> String { "\(calendar.component(.hour, from: d))" }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 18) {
        SectionHeader("Departure delays", subtitle: "Average, actual then estimated")
        DelayTrendChart(flights: PreviewData.board("KAUS", .departures).flights, kind: .departures,
                        timeZone: PreviewData.kaus.timeZone, now: PreviewData.now)
    }
    .padding(16)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif

extension DelayTrendChart {
    /// "Now 30 minutes on average. Worst 1h 5m at 9:00."
    var accessibilitySummary: String {
        let bins = self.bins
        guard let worst = bins.filter({ $0.minutes != nil }).max(by: { ($0.minutes ?? 0) < ($1.minutes ?? 0) }) else {
            return "No delay data"
        }
        let current = bins.first { $0.start == nowBin }?.minutes
        let nowPart = current.map { "Now \(Format.minutes(Int($0.rounded()))) on average. " } ?? ""
        return nowPart + "Worst \(Format.minutes(Int((worst.minutes ?? 0).rounded()))) at \(Format.clock(worst.start, timeZone, units.clock))."
    }
}
