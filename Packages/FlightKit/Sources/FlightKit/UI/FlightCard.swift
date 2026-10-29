import SwiftUI

/// A followed flight at a glance: number and status, the two airports with their best times,
/// and a progress line with the plane where it is now.
public struct FlightCard: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var now: Date

    public init(flight: Flight, origin: Airport?, destination: Airport?, now: Date = .now) {
        self.flight = flight; self.origin = origin; self.destination = destination; self.now = now
    }

    private var level: DelayLevel { flight.level }

    private var statusText: String {
        switch flight.status {
        case .canceled: return "Canceled"
        case .diverted: return "Diverted"
        case .landed: return "Landed"
        case .arrived: return "Arrived"
        case .departed, .enRoute:
            if let d = flight.arrivalDelay, Format.minutes(d) >= 15 { return "In the Air, \(Format.minutes(Format.minutes(d))) Late" }
            return "In the Air"
        case .scheduled, .unknown:
            if let d = flight.departureDelay, Format.minutes(d) >= 15 { return "\(Format.minutes(Format.minutes(d))) Late" }
            return flight.estimatedOut == nil && flight.actualOut == nil ? "Scheduled" : "On Time"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.ident(flight.ident))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if let type = flight.aircraftType {
                    Text(type).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(level.color).frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(level == .onTime || level == .canceled ? Theme.primary : level.color)
                }
            }
            HStack(alignment: .top) {
                end(code: flight.originCode, city: origin?.city, scheduled: flight.scheduledOut,
                    best: flight.actualOut ?? flight.estimatedOut, tz: origin?.timeZone, alignment: .leading)
                Spacer()
                end(code: flight.destinationCode, city: destination?.city, scheduled: flight.scheduledIn,
                    best: flight.actualIn ?? flight.estimatedIn, tz: destination?.timeZone, alignment: .trailing)
            }
            ProgressLine(progress: flight.progress(at: now), color: level == .onTime ? Theme.primary : level.color,
                         dimmed: flight.status == .canceled)
            if let info = gateInfo {
                Text(info).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        .monospacedDigit()
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
        .accessibilityElement(children: .combine)
    }

    private var gateInfo: String? {
        var parts: [String] = []
        if let t = flight.terminalOrigin { parts.append("Terminal \(t)") }
        if let g = flight.gateOrigin { parts.append("Gate \(g)") }
        if let b = flight.baggageBelt { parts.append("Belt \(b)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func end(code: String, city: String?, scheduled: Date?, best: Date?, tz: TimeZone?,
                     alignment: HorizontalAlignment) -> some View {
        let zone = tz ?? .current
        let changed = scheduled != nil && best != nil && abs(best!.timeIntervalSince(scheduled!)) >= 60
        return VStack(alignment: alignment, spacing: 2) {
            Text(code)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.primary)
            Text(city ?? " ")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let scheduled {
                    Text(Format.clock(scheduled, zone))
                        .strikethrough(changed, color: Theme.secondary)
                        .foregroundStyle(changed ? Theme.secondary : Theme.primary)
                }
                if changed, let best {
                    Text(Format.clock(best, zone)).foregroundStyle(level == .onTime ? Theme.onTime : level.color)
                }
            }
            .font(.system(size: 17, weight: .medium))
            .padding(.top, 4)
        }
    }
}

/// Dotted remaining track, solid flown track, plane glyph at the split.
struct ProgressLine: View {
    var progress: Double
    var color: Color
    var dimmed: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = 10 + (w - 20) * progress
            ZStack(alignment: .leading) {
                Path { p in p.move(to: CGPoint(x: 0, y: 9)); p.addLine(to: CGPoint(x: w, y: 9)) }
                    .stroke(Theme.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4]))
                Capsule().fill(color).frame(width: max(0, x), height: 2.5).offset(y: 0)
                    .frame(height: 18)
                Image(systemName: "airplane")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dimmed ? Theme.secondary : color)
                    .offset(x: x - 8)
            }
        }
        .frame(height: 18)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(PreviewData.followed) { f in
                FlightCard(flight: f, origin: PreviewData.airport(f.originIcao),
                           destination: PreviewData.airport(f.destinationIcao), now: PreviewData.now)
            }
            FlightCard(flight: PreviewData.sparse, origin: nil, destination: nil)
        }
        .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
