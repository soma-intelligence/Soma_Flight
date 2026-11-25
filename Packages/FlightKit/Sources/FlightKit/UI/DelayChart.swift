import Charts
import SwiftUI

/// Flights per hour across the local day as two stacks: on time at the base, late 15 min or more
/// above it with a small gap. Hours after now are faded (scheduled, not flown yet), a dashed "Now"
/// rule marks the current hour, and tapping a bar shows that hour's canceled and diverted counts.
public struct DelayChart: View {
    var perHour: [HourBucket]
    var timeZone: TimeZone
    var now: Date
    @State private var selected: Int?

    public init(perHour: [HourBucket], timeZone: TimeZone = .current, now: Date = .now) {
        self.perHour = perHour; self.timeZone = timeZone; self.now = now
    }

    static let plotHeight: CGFloat = 160
    static let barWidth: CGFloat = 11
    /// Space between the on time and late stacks, in points.
    static let stackGap: CGFloat = 3
    /// Opacity of the hours that have not been flown yet.
    static let scheduledOpacity: Double = 0.45

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
            // The buckets sit on UTC hours: in a zone offset by 30 or 45 minutes they start inside the local
            // hour, not on it.
            return (start, perHour.first { $0.hour >= start.addingTimeInterval(-1) && $0.hour < start.addingTimeInterval(3599) })
        }
    }

    private func total(_ b: HourBucket) -> Int { b.onTime + b.late15 + b.late45 + b.canceled + b.diverted }
    private func late(_ b: HourBucket) -> Int { b.late15 + b.late45 }

    /// The tallest drawn bar: on time plus late (canceled and diverted only show on tap).
    private var peak: Int { max(1, perHour.map { $0.onTime + late($0) }.max() ?? 1) }
    /// Grid step: 2, 5 or 10 flights, so the axis has three to five lines.
    private var step: Int { peak <= 6 ? 2 : (peak <= 15 ? 5 : 10) }
    private var axisMax: Int { Int((Double(peak) / Double(step)).rounded(.up)) * step }
    private var gridValues: [Int] { Array(stride(from: 0, through: axisMax, by: step)) }
    /// The stack gap in flights, so it stays a fixed number of points whatever the scale.
    private var gapUnits: Double { Double(axisMax) * Double(Self.stackGap) / Double(Self.plotHeight) }

    private var nowIndex: Int? {
        slots.firstIndex { now >= $0.start && now < $0.start.addingTimeInterval(3600) }
    }

    /// Hours after the current one have not been flown yet.
    private func isScheduled(_ i: Int, start: Date) -> Bool {
        if let n = nowIndex { return i > n }
        return start > now
    }

    public var body: some View {
        let slots = self.slots
        VStack(alignment: .leading, spacing: 8) {
            legend
            chart(slots)
            Text(ui: "Faded bars are scheduled, not flown yet. Tap a bar for canceled and diverted.")
                .scaledFont(12)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flights per hour by delay")
        .accessibilityValue(accessibilitySummary)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            item("On time", Theme.splitGreen)
            item("Late 15m+", Theme.splitRed)
        }
        .scaledFont(12)
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }

    private func item(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(ui: label)
        }
    }

    private func chart(_ slots: [(start: Date, bucket: HourBucket?)]) -> some View {
        let gap = gapUnits
        return Chart {
            ForEach(Array(slots.enumerated()), id: \.offset) { i, s in
                if let b = s.bucket {
                    let faded = isScheduled(i, start: s.start)
                    let dim = selected.map { $0 != i } ?? false
                    let opacity = (faded ? Self.scheduledOpacity : 1) * (dim ? 0.5 : 1)
                    if b.onTime > 0 {
                        BarMark(x: .value("Hour", i), yStart: .value("Start", 0), yEnd: .value("On time", b.onTime),
                                width: .fixed(Self.barWidth))
                            .foregroundStyle(Theme.splitGreen.opacity(opacity))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if late(b) > 0 {
                        let base = b.onTime > 0 ? Double(b.onTime) + gap : 0
                        BarMark(x: .value("Hour", i), yStart: .value("Start", base), yEnd: .value("Late", base + Double(late(b))),
                                width: .fixed(Self.barWidth))
                            .foregroundStyle(Theme.splitRed.opacity(opacity))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            if let n = nowIndex {
                RuleMark(x: .value("Now", Double(n) + 0.5))
                    .foregroundStyle(Theme.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4) {
                        if selected == nil {
                            Text(ui: "Now").scaledFont(12, weight: .semibold).foregroundStyle(Theme.primary)
                        }
                    }
            }
            if let i = selected, i < slots.count {
                RuleMark(x: .value("Selected", i))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(slots[i])
                    }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...(Double(axisMax) + gap))
        .chartYAxis {
            AxisMarks(position: .trailing, values: gridValues) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.primary.opacity(0.08))
                AxisValueLabel().font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { v in
                AxisValueLabel {
                    Text(ui: "\(calendar.component(.hour, from: slots[v.as(Int.self) ?? 0].start))h")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard let frame = proxy.plotFrame else { return }
                        let x = tap.location.x - geo[frame].origin.x
                        guard let value: Double = proxy.value(atX: x) else { return }
                        let i = Int(value.rounded())
                        withAnimation(.snappy(duration: 0.2)) {
                            selected = (0..<24).contains(i) && slots[i].bucket != nil && selected != i ? i : nil
                        }
                    })
            }
        }
        .frame(height: Self.plotHeight)
        .scaledPadding(.top, 18)
        .monospacedDigit()
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US"); f.timeZone = timeZone; f.dateFormat = "h a"
        return f.string(from: d)
    }

    /// The tapped hour: its time, then every count including canceled and diverted.
    private func callout(_ s: (start: Date, bucket: HourBucket?)) -> some View {
        let b = s.bucket
        return VStack(alignment: .leading, spacing: 2) {
            Text(ui: hourLabel(s.start))
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Theme.primary)
            Text(ui: "\(b?.onTime ?? 0) on time, \(b.map(late) ?? 0) late")
            Text(ui: "\(b?.canceled ?? 0) canceled, \(b?.diverted ?? 0) diverted")
        }
        .scaledFont(11)
        .foregroundStyle(Theme.secondary)
        .monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.grid, lineWidth: 1))
        .fixedSize()
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
