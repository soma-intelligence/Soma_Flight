import SwiftUI

/// The flight sheet's estimate, under the freshness line while the app cannot hear about a flight in
/// the air (offline, or no live update for `FlightEstimate.staleAfter`): an "Estimated, offline" badge with
/// the last update, a dashed bar at the estimated share of the trip, the region under the estimated
/// position ("Over the North Atlantic", `RegionNamer`) and what it rests on. Nothing when the flight is live.
struct EstimatedProgressCard: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var now: Date
    @Environment(\.connectivity) private var connectivity
    @Environment(\.units) private var units
    @Environment(\.reference) private var reference

    var body: some View {
        if let e = FlightEstimate.make(for: flight, origin: origin?.coordinate, destination: destination?.coordinate,
                                       online: connectivity?.isOnline ?? true, now: now,
                                       aircraft: flight.aircraftType.flatMap { reference.type($0) }) {
            EstimatedProgressView(estimate: e, from: flight.originCode, to: flight.destinationCode, clock: units.clock,
                                  region: e.regionLine())
        }
    }
}

struct EstimatedProgressView: View {
    var estimate: FlightEstimate
    var from: String
    var to: String
    var clock: TimeStyle
    /// "Over the North Atlantic"; nil hides the line.
    var region: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: estimate.reason == .offline ? "wifi.slash" : "clock.badge.questionmark")
                        .scaledFont(12, weight: .semibold)
                        .accessibilityHidden(true)
                    Group {
                        if estimate.reason == .offline { Text("Estimated, offline") } else { Text("Estimated, no live update") }
                    }
                    .scaledFont(13, weight: .semibold)
                }
                .scaledPadding(.horizontal, 8)
                .scaledPadding(.vertical, 3)
                .background(Capsule().fill(Theme.late.opacity(0.16)))
                .foregroundStyle(Theme.late)
                Spacer(minLength: 4)
                Text(ui: estimate.lastUpdateLine(style: clock))
                    .scaledFont(13)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 10) {
                Text(ui: from).scaledFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
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
                Text(ui: to).scaledFont(13, weight: .semibold).foregroundStyle(Theme.secondary)
            }
            if let region {
                Text(ui: region)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(Theme.primary)
            }
            Text(ui: estimate.detail)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledPadding(.all, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.late.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.late.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(estimate.label(style: clock)). About \(Int((estimate.progress * 100).rounded())) percent of the way from \(from) to \(to). \(region.map { "\($0). " } ?? "")\(estimate.detail)")
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
                          from: "SFO", to: "CDG", clock: .h24, region: "Over the North Atlantic")
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
#endif
