import SwiftUI

/// Gate out, take-off, landing, gate in: one row each with the schedule struck when it moved.
public struct FlightTimeline: View {
    @Environment(\.units) private var units
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var now: Date

    public init(flight: Flight, origin: Airport?, destination: Airport?, now: Date = .now) {
        self.flight = flight; self.origin = origin; self.destination = destination; self.now = now
    }

    struct Step: Identifiable {
        var id: String { title }
        var title: String
        var place: String
        var scheduled: Date?
        var actual: Date?
        var estimated: Date?
        var tz: TimeZone
        var done: Bool { actual != nil }
    }

    var steps: [Step] {
        let o = origin?.timeZone ?? .current, d = destination?.timeZone ?? .current
        let from = origin.map { "\($0.city), gate \(flight.gateOrigin ?? "TBA")" } ?? flight.originCode
        let to = destination.map { "\($0.city), gate \(flight.gateDestination ?? "TBA")" } ?? flight.destinationCode
        return [
            Step(title: "Gate departure", place: from, scheduled: flight.scheduledOut, actual: flight.actualOut,
                 estimated: flight.estimatedOut, tz: o),
            Step(title: "Take-off", place: flight.originCode, scheduled: nil, actual: flight.actualOff, estimated: nil, tz: o),
            Step(title: "Landing", place: flight.destinationCode, scheduled: nil, actual: flight.actualOn, estimated: nil, tz: d),
            Step(title: "Gate arrival", place: to, scheduled: flight.scheduledIn, actual: flight.actualIn,
                 estimated: flight.estimatedIn, tz: d),
        ]
    }

    public var body: some View {
        let steps = self.steps
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .strokeBorder(step.done ? Color.clear : Theme.secondary, lineWidth: 1.5)
                            .background(Circle().fill(step.done ? dotColor : Color.clear))
                            .frame(width: 12, height: 12)
                            .scaledPadding(.top, 4)
                        if i < steps.count - 1 {
                            Rectangle()
                                .fill(steps[i + 1].done ? dotColor : Theme.grid)
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).scaledFont(16, weight: .semibold).foregroundStyle(Theme.primary)
                        Text(step.place).scaledFont(13).foregroundStyle(Theme.secondary)
                    }
                    .scaledPadding(.bottom, 18)
                    Spacer()
                    times(step)
                }
            }
        }
        .monospacedDigit()
    }

    private var dotColor: Color { flight.level == .onTime ? Theme.onTime : flight.level.color }

    @ViewBuilder private func times(_ step: Step) -> some View {
        let best = step.actual ?? step.estimated
        let moved = step.scheduled != nil && best != nil && abs(best!.timeIntervalSince(step.scheduled!)) >= 60
        VStack(alignment: .trailing, spacing: 1) {
            if let s = step.scheduled {
                Text(Format.clock(s, step.tz, units.clock))
                    .strikethrough(moved, color: Theme.secondary)
                    .foregroundStyle(moved ? Theme.secondary : Theme.primary)
            }
            if let best, moved || step.scheduled == nil {
                Text(Format.clock(best, step.tz, units.clock))
                    .foregroundStyle(moved ? DelayLevel.for(delay: .seconds(best.timeIntervalSince(step.scheduled!)), status: flight.status).color : Theme.primary)
            }
            if step.scheduled == nil && best == nil {
                Text("--:--").foregroundStyle(Theme.secondary)
            }
            if step.actual == nil, best != nil || step.scheduled != nil {
                Text(step.estimated != nil ? "Estimated" : "Scheduled")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .scaledFont(16, weight: .medium)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 30) {
            FlightTimeline(flight: PreviewData.enRoute, origin: PreviewData.airport("LFPG"),
                           destination: PreviewData.airport("KSFO"), now: PreviewData.now)
            FlightTimeline(flight: PreviewData.sparse, origin: nil, destination: nil)
        }
        .scaledPadding(.all, 20)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
