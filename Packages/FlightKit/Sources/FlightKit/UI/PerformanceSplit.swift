import SwiftUI

/// On time / delayed 15 min+ / canceled shares with counts, over one segmented bar.
public struct PerformanceSplit: View {
    var stats: DelayStats

    public init(stats: DelayStats) { self.stats = stats }

    private struct Part: Identifiable {
        var id: String { label }
        var label: String
        var count: Int
        var color: Color
        var hatched: Bool = false
    }

    private var parts: [Part] {
        [
            Part(label: "On Time", count: stats.onTime, color: Theme.splitGreen),
            Part(label: "Delayed 15m+", count: stats.delayed15, color: Theme.splitRed),
            Part(label: "Canceled", count: stats.canceled, color: Theme.ifr, hatched: true),
        ]
    }

    private func share(_ n: Int) -> Int {
        stats.total > 0 ? Int((Double(n) / Double(stats.total) * 100).rounded()) : 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                    if i > 0 { Spacer(minLength: 12) }
                    column(part)
                }
            }
            bar
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Performance")
        .accessibilityValue(parts.map { "\($0.label) \(share($0.count)) percent, \($0.count) flights" }.joined(separator: ", "))
    }

    private func column(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(part.color).frame(width: 2.5, height: 12)
                Text(part.label).scaledFont(13).foregroundStyle(Theme.primary)
            }
            .padding(.bottom, 4)
            Text("\(share(part.count))%")
                .scaledFont(22, weight: .semibold)
                .foregroundStyle(Theme.primary)
            Text("\(part.count)")
                .scaledFont(14.5)
                .foregroundStyle(Theme.secondary)
        }
        .monospacedDigit()
    }

    private var bar: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2.5
            let minWidth: CGFloat = 10
            let total = max(1, parts.reduce(0) { $0 + $1.count })
            let free = geo.size.width - gap * CGFloat(parts.count - 1) - minWidth * CGFloat(parts.count)
            HStack(spacing: gap) {
                ForEach(parts) { part in
                    let w = minWidth + max(0, free) * CGFloat(part.count) / CGFloat(total)
                    Group {
                        if part.hatched { Hatch(spacing: 3.5) } else { part.color }
                    }
                    .frame(width: w)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 6)
    }
}

#Preview {
    PerformanceSplit(stats: PreviewData.stats("KAUS"))
        .padding(20)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
