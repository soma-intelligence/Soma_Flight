import SwiftUI

/// The flight sheet's estimate, under the freshness line while the app cannot hear about a flight in
/// the air (offline, or no live update for `FlightEstimate.staleAfter`): "Estimated, last update 14:02",
/// a dashed bar at the estimated share of the trip and what it rests on. Nothing when the flight is live.
struct EstimatedProgressCard: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var now: Date
    @Environment(\.connectivity) private var connectivity
    @Environment(\.units) private var units

    var body: some View {
        if let e = FlightEstimate.make(for: flight, origin: origin?.coordinate, destination: destination?.coordinate,
                                       online: connectivity?.isOnline ?? true, now: now) {
            EstimatedProgressView(estimate: e, from: flight.originCode, to: flight.destinationCode, clock: units.clock)
        }
    }
}

struct EstimatedProgressView: View {
    var estimate: FlightEstimate
    var from: String
    var to: String
    var clock: TimeStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: estimate.reason == .offline ? "wifi.slash" : "clock.badge.questionmark")
                    .scaledFont(13, weight: .semibold)
                    .accessibilityHidden(true)
                Text(estimate.label(style: clock))
                    .scaledFont(13, weight: .semibold)
            }
            .foregroundStyle(Theme.late)
            HStack(spacing: 10) {
                Text(from).scaledFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
                GeometryReader { geo in
                    let w = geo.size.width, p = CGFloat(estimate.progress)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.pill).frame(height: 3)
                        Line().stroke(Theme.primary.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [4, 5]))
                            .frame(width: max(0, w * p), height: 3)
                        Image(systemName: "airplane")
                            .scaledFont(13, weight: .semibold)
                            .foregroundStyle(Theme.primary.opacity(0.7))
                            .position(x: min(max(8, w * p), w - 8), y: geo.size.height / 2)
                    }
                    .frame(height: geo.size.height)
                }
                .frame(height: 18)
                Text(to).scaledFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
            }
            Text(estimate.detail)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledPadding(.all, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.late.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.late.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(estimate.label(style: clock)). About \(Int((estimate.progress * 100).rounded())) percent of the way from \(from) to \(to). \(estimate.detail)")
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
        }
    }
}

#if DEBUG
#Preview("Estimate, offline") {
    EstimatedProgressView(estimate: FlightEstimate(reason: .offline, progress: 0.42, coordinate: nil, heading: nil,
                                                   lastUpdate: .now.addingTimeInterval(-3000), probablyLanded: false),
                          from: "SFO", to: "CDG", clock: .h24)
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
#endif
