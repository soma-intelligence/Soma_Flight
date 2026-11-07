import SwiftUI

/// Flights per hour across the local day, stacked by delay level (canceled at the base, then
/// diverted, 45 min late, 15 min late, on time on top), with a right-hand count axis and a
/// "NOW" marker over the current hour.
public struct DelayChart: View {
    var perHour: [HourBucket]
    var timeZone: TimeZone
    var now: Date

    public init(perHour: [HourBucket], timeZone: TimeZone = .current, now: Date = .now) {
        self.perHour = perHour; self.timeZone = timeZone; self.now = now
    }

    static let plotHeight: CGFloat = 198
    static let axisWidth: CGFloat = 30
    static let barWidth: CGFloat = 8

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// 24 hourly slots of the local day that holds `now` (or the first bucket if `now` is outside them).
    private var slots: [(start: Date, bucket: HourBucket?)] {
        let anchor = perHour.contains { calendar.isDate($0.hour, inSameDayAs: now) } ? now : (perHour.first?.hour ?? now)
        let day = calendar.startOfDay(for: anchor)
        return (0..<24).map { h in
            let start = calendar.date(byAdding: .hour, value: h, to: day)!
            return (start, perHour.first { abs($0.hour.timeIntervalSince(start)) < 1 })
        }
    }

    private func total(_ b: HourBucket) -> Int { b.onTime + b.late15 + b.late45 + b.canceled + b.diverted }

    private var peak: Int { max(1, perHour.map(total).max() ?? 1) }
    /// Grid step: 2, 5 or 10 flights, so the axis has three to five lines.
    private var step: Int { peak <= 6 ? 2 : (peak <= 15 ? 5 : 10) }
    private var axisMax: Int { Int((Double(peak) / Double(step)).rounded(.up)) * step }
    private var gridValues: [Int] { Array(stride(from: 0, through: axisMax, by: step)) }

    private var nowIndex: Int? {
        slots.firstIndex { now >= $0.start && now < $0.start.addingTimeInterval(3600) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            plot
        }
        // Bars, grid and labels are laid out by hand; cap growth so labels keep their slots.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flights per hour by delay")
        .accessibilityValue(accessibilitySummary)
    }

    private var legend: some View {
        HStack(spacing: 9) {
            item("On Time", Theme.onTime)
            item("15m Late", Theme.late)
            item("45m Late", Theme.veryLate)
            HStack(spacing: 4) {
                Hatch(spacing: 3).frame(width: 8, height: 8).clipShape(RoundedRectangle(cornerRadius: 2.5))
                Text("Canceled")
            }
            item("Diverted", Theme.diverted)
        }
        .scaledFont(11.5)
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func item(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 8, height: 8)
            Text(ui: label)
        }
    }

    private var plot: some View {
        let h = Self.plotHeight
        let top = CGFloat(axisMax)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let plotWidth = geo.size.width - Self.axisWidth
                let slot = plotWidth / 24
                ZStack(alignment: .topLeading) {
                    // Grid and right axis.
                    ForEach(gridValues, id: \.self) { v in
                        let y = 34 + h - h * CGFloat(v) / top
                        Rectangle().fill(Theme.grid).frame(width: plotWidth, height: 1)
                            .offset(y: y)
                        Text("\(v)")
                            .scaledFont(11)
                            .foregroundStyle(Theme.secondary.opacity(0.7))
                            .frame(width: Self.axisWidth - 4, alignment: .leading)
                            .offset(x: plotWidth + 4, y: y - 8)
                    }
                    // Now marker: outlined capsule and a dotted line down to the bar.
                    if let i = nowIndex {
                        let x = slot * (CGFloat(i) + 0.5)
                        let barTop = 34 + h - h * CGFloat(slots[i].bucket.map(total) ?? 0) / top
                        Path { p in
                            p.move(to: CGPoint(x: x, y: 26))
                            p.addLine(to: CGPoint(x: x, y: barTop - 2))
                        }
                        .stroke(Theme.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Text("NOW")
                            .scaledFont(12, weight: .medium)
                            .foregroundStyle(Theme.secondary)
                            .scaledPadding(.horizontal, 8).scaledPadding(.vertical, 3)
                            .background(Capsule().strokeBorder(Theme.grid, lineWidth: 1.5))
                            .fixedSize()
                            .frame(width: 60)
                            .offset(x: x - 30, y: 4)
                    }
                    // Bars.
                    ForEach(Array(slots.enumerated()), id: \.offset) { i, s in
                        if let b = s.bucket, total(b) > 0 {
                            bar(b, unit: h / top)
                                .offset(x: slot * (CGFloat(i) + 0.5) - Self.barWidth / 2,
                                        y: 34 + h - h * CGFloat(total(b)) / top)
                        }
                    }
                }
            }
            .frame(height: h + 35)
            // Hour labels every two hours, 12-hour clock without suffix.
            GeometryReader { geo in
                let slot = (geo.size.width - Self.axisWidth) / 24
                ForEach(Array(stride(from: 0, to: 24, by: 2)), id: \.self) { i in
                    let hour = calendar.component(.hour, from: slots[i].start)
                    Text("\(hour % 12 == 0 ? 12 : hour % 12)")
                        .scaledFont(11)
                        .foregroundStyle(Theme.secondary.opacity(0.7))
                        .frame(width: 30)
                        .offset(x: slot * (CGFloat(i) + 0.5) - 15)
                }
            }
            .frame(height: 16)
        }
        .monospacedDigit()
    }

    private func bar(_ b: HourBucket, unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            Theme.onTime.frame(height: unit * CGFloat(b.onTime))
            Theme.late.frame(height: unit * CGFloat(b.late15))
            Theme.veryLate.frame(height: unit * CGFloat(b.late45))
            Theme.diverted.frame(height: unit * CGFloat(b.diverted))
            Hatch(spacing: 3.5).frame(height: unit * CGFloat(b.canceled))
        }
        .frame(width: Self.barWidth)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader("Departures per hour")
        DelayChart(perHour: PreviewData.stats("KAUS").perHour, timeZone: PreviewData.kaus.timeZone, now: PreviewData.now)
    }
    .scaledPadding(.all, 16)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif

extension DelayChart {
    /// "Busiest hour 8 AM with 3 flights. 40 percent on time, 44 percent late, 16 percent canceled."
    var accessibilitySummary: String {
        let all = perHour.reduce(into: (on: 0, late: 0, canceled: 0, total: 0)) { acc, b in
            acc.on += b.onTime; acc.late += b.late15 + b.late45; acc.canceled += b.canceled
            acc.total += b.onTime + b.late15 + b.late45 + b.canceled + b.diverted
        }
        guard all.total > 0, let peak = perHour.max(by: { total($0) < total($1) }) else { return "No flights" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US"); f.timeZone = timeZone; f.dateFormat = "h a"
        func pct(_ n: Int) -> Int { Int((Double(n) / Double(all.total) * 100).rounded()) }
        return "Busiest hour \(f.string(from: peak.hour)) with \(total(peak)) flights. "
            + "\(pct(all.on)) percent on time, \(pct(all.late)) percent late, \(pct(all.canceled)) percent canceled."
    }
}
