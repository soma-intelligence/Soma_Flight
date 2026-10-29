import SwiftUI

enum DailyScope: Hashable { case departures, arrivals, totals }

/// The whole day in one card: date, big flight count, a split bar and the three shares.
struct DailyPerformanceCard: View {
    var stats: DelayStats
    var scope: DailyScope
    var day: Date
    var timeZone: TimeZone

    private var noun: String {
        switch scope {
        case .departures: "Departures"
        case .arrivals: "Arrivals"
        case .totals: "Flights"
        }
    }

    private var dateLine: String {
        var style = AirportFacts.longDay
        style.timeZone = timeZone
        return day.formatted(style)
    }

    private func share(_ n: Int) -> Int {
        stats.total > 0 ? Int((Double(n) / Double(stats.total) * 100).rounded()) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateLine).scaledFont(15).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(stats.total)").scaledFont(33, weight: .bold)
                Text(noun).scaledFont(25, weight: .semibold)
            }
            .foregroundStyle(Theme.primary)
            .padding(.top, 1)
            SplitBar(parts: [(stats.onTime, Theme.splitGreen, false), (stats.delayed15, Theme.splitRed, false),
                             (stats.canceled, Theme.canceled, true)])
                .frame(height: 4.5)
                .padding(.top, 18)
                .padding(.bottom, 12)
            line("On Time", Theme.splitGreen, stats.onTime)
            line("Delayed 15m+", Theme.splitRed, stats.delayed15)
            line("Canceled", Theme.ifr, stats.canceled)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: String, _ color: Color, _ n: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2.5, height: 13)
            Text(label).scaledFont(15).foregroundStyle(Theme.primary)
            Spacer()
            Text("\(share(n))%").scaledFont(15).foregroundStyle(Theme.primary)
            Text("\(n)").scaledFont(15).foregroundStyle(Theme.secondary).frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.vertical, 3.5)
    }
}

/// Capsule segments sized by count, each at least a few points wide.
struct SplitBar: View {
    var parts: [(count: Int, color: Color, hatched: Bool)]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3, minWidth: CGFloat = 8
            let total = max(1, parts.reduce(0) { $0 + $1.count })
            let free = geo.size.width - gap * CGFloat(parts.count - 1) - minWidth * CGFloat(parts.count)
            HStack(spacing: gap) {
                ForEach(parts.indices, id: \.self) { i in
                    Group { if parts[i].hatched { Hatch(spacing: 3.5) } else { parts[i].color } }
                        .frame(width: minWidth + max(0, free) * CGFloat(parts[i].count) / CGFloat(total))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

/// Horizontal bars for the most disrupted routes or airlines: code and caption on the left,
/// red delayed then hatched canceled, a faint track to the right and the total.
struct DisruptionBars: View {
    struct Item: Identifiable {
        var id: String
        var code: String
        var caption: String?
        var delayed: Int
        var canceled: Int
    }

    var items: [Item]

    private var peak: Int { max(1, items.map { $0.delayed + $0.canceled }.max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                legend(Theme.splitRed, "Delayed", hatched: false)
                legend(Theme.canceled, "Canceled", hatched: true)
            }
            .padding(.bottom, 14)
            if items.isEmpty {
                Text("No disruption so far today.")
                    .scaledFont(15).foregroundStyle(Theme.secondary)
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .monospacedDigit()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func legend(_ color: Color, _ text: String, hatched: Bool) -> some View {
        HStack(spacing: 5) {
            Group { if hatched { Hatch(spacing: 3) } else { color } }
                .frame(width: 11, height: 11)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(text).scaledFont(12.5).foregroundStyle(Theme.secondary)
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.code).scaledFont(15, weight: .semibold).foregroundStyle(Theme.primary)
                if let caption = item.caption {
                    Text(caption).scaledFont(11.5).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .frame(width: 56, alignment: .leading)
            Rectangle().fill(Theme.separator).frame(width: 1, height: item.caption == nil ? 20 : 34)
                .padding(.trailing, 6)
            GeometryReader { geo in
                let w = geo.size.width
                let total = item.delayed + item.canceled
                let full = w * CGFloat(total) / CGFloat(peak)
                let red = total > 0 ? full * CGFloat(item.delayed) / CGFloat(total) : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.separator).frame(height: 1)
                    Circle().fill(Theme.separator).frame(width: 3, height: 3).offset(x: w - 3)
                    HStack(spacing: 0) {
                        Theme.splitRed.frame(width: red)
                        Hatch(spacing: 3.5).frame(width: full - red)
                    }
                    .frame(width: max(6, full), height: 15, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
                .frame(height: geo.size.height)
            }
            .frame(height: item.caption == nil ? 26 : 40)
            Text("\(item.delayed + item.canceled)")
                .scaledFont(13).foregroundStyle(Theme.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.code), \(item.delayed) delayed, \(item.canceled) canceled")
    }
}

/// Four big numbers about today's traffic.
struct AirportCountsGrid: View {
    var counts: AirportFacts.Counts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 26) {
            GridRow {
                cell(counts.departures, "Departures")
                cell(counts.airlines, "Airlines")
            }
            GridRow {
                cell(counts.airportsServed, "Airports Served")
                cell(counts.countries, "Countries Served")
            }
        }
        .monospacedDigit()
    }

    private func cell(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").scaledFont(22, weight: .semibold).foregroundStyle(Theme.primary)
            Text(label).scaledFont(13.5).foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
