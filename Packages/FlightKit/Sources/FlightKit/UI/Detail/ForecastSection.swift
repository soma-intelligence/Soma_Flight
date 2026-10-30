import SwiftUI

/// The arrival forecast card: how this flight number arrived over the last 60 days, three figures and a
/// bar per bucket. Paid data, so only screenshot runs on the fakes have it; nothing draws without one.
struct ForecastSection: View {
    var forecast: ArrivalForecast?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var labelWidth = 92
    @ScaledMetric(relativeTo: .body) private var barHeight = 22

    static let title = "Arrival forecast"

    /// "UA 990 over the last 60 days".
    static func subtitle(_ f: ArrivalForecast) -> String { "\(Format.ident(f.ident)) over the last \(f.days) days" }

    var body: some View {
        if let forecast { card(forecast) }
    }

    private func card(_ f: ArrivalForecast) -> some View {
        DetailCard {
            CardTitle(Self.title, subtitle: Self.subtitle(f))
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                figure("Late", symbol: "clock.badge.exclamationmark", value: "\(f.latePercent)%")
                figure("Average late", symbol: "timer", value: Format.minutes(f.averageLateMinutes))
                figure("Observed", symbol: "airplane", value: "\(f.observed) flights")
            }
            .scaledPadding(.top, 20)
            VStack(spacing: 10) {
                ForEach(ForecastBucket.allCases, id: \.self) { b in
                    bar(b, percent: f.percents[b, default: 0])
                }
            }
            .scaledPadding(.top, 22)
        }
    }

    private func figure(_ label: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaledFont(15, weight: .medium).foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                Image(systemName: symbol).scaledFont(16, weight: .semibold).accessibilityHidden(true)
                Text(value).scaledFont(19, weight: .semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bar(_ b: ForecastBucket, percent: Int) -> some View {
        HStack(spacing: 12) {
            Text(b.title)
                .scaledFont(15, weight: .medium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.pill)
                    Self.fill(b)
                        .frame(width: max(percent > 0 ? 6 : 0, geo.size.width * CGFloat(percent) / 100))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .frame(height: barHeight)
            Text("\(percent)%")
                .scaledFont(15, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(b.title)
        .accessibilityValue("\(percent) percent")
    }

    /// Green for early and on time, amber for 15 and 30 minutes, red for 45 and more, the white hatch for
    /// canceled, purple for diverted.
    @ViewBuilder static func fill(_ b: ForecastBucket) -> some View {
        switch b {
        case .early: Theme.splitGreen
        case .onTime: Theme.onTime
        case .late15: Theme.late
        case .late30: Theme.trendAmber
        case .late45: Theme.veryLate
        case .canceled: Hatch()
        case .diverted: Theme.diverted
        }
    }
}
