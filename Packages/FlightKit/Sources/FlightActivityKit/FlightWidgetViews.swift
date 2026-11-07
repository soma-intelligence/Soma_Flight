#if canImport(WidgetKit)
import SwiftUI
import WidgetKit

// The home screen and lock screen widgets. The views live here, beside the Live Activity's, so the
// extension only declares the widgets and their timelines. Always dark, in the flight sheet's colours.

extension FlightWidgetDisplay {
    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: ActivityPalette.primary
        case .onTime: ActivityPalette.onTime
        case .late: ActivityPalette.veryLate
        }
    }

    var headlineColor: Color { Self.color(headlineTone) }
    var levelColor: Color { activity.levelColor }
    var statusColor: Color { activity.statusColor }
    /// The countdown's word when it has no figure: red for canceled, purple for diverted, else grey,
    /// as in My Flights.
    var unitColor: Color {
        switch flight.status {
        case .canceled: ActivityPalette.veryLate
        case .diverted: ActivityPalette.diverted
        default: ActivityPalette.secondary
        }
    }
}

// MARK: - Pieces

/// My Flights' countdown: a big figure over its unit, or the unit alone in its colour.
struct WidgetCountdown: View {
    let display: FlightWidgetDisplay
    var size: CGFloat = 34
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let c = display.countdown
        VStack(alignment: alignment, spacing: 0) {
            if !c.value.isEmpty {
                Text(ui: c.value)
                    .activityFont(size, .semibold, relativeTo: .largeTitle, digits: true)
                    .foregroundStyle(ActivityPalette.primary)
                    .widgetAccentable()
            }
            Text(ui: c.unit)
                .activityFont(c.value.isEmpty ? 15 : 12, .semibold, relativeTo: .caption)
                .foregroundStyle(c.value.isEmpty ? display.unitColor : ActivityPalette.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.value.isEmpty ? c.unit.capitalized : "\(c.value) \(c.unit.lowercased())")
    }
}

/// The flight sheet's gate badge: yellow with an arrow once assigned, grey "Gate --" until then.
struct WidgetGateBadge: View {
    var gate: String?
    var arriving: Bool

    var body: some View {
        Group {
            if let gate {
                HStack(spacing: 2) {
                    Image(systemName: arriving ? "arrow.down.right" : "arrow.up.right")
                        .font(.system(size: 10, weight: .heavy))
                    Text(ui: gate).activityFont(13, .bold, relativeTo: .footnote)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ActivityPalette.gate))
            } else {
                Text("Gate --")
                    .activityFont(12, .semibold, relativeTo: .footnote)
                    .foregroundStyle(ActivityPalette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ActivityPalette.pill))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gate.map { "Gate \($0)" } ?? "Gate not assigned")
    }
}

/// An airport code over its best time in the flight sheet's colour, the schedule struck through
/// beside it once the time moved.
struct WidgetEnd: View {
    var code: String
    var time: String
    var scheduled: String?
    var dayMark: String?
    var tone: FlightWidgetDisplay.Tone
    var alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(ui: code)
                .activityFont(22, .semibold, relativeTo: .title2)
                .foregroundStyle(ActivityPalette.primary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let scheduled, alignment == .trailing {
                    Text(ui: scheduled).strikethrough().foregroundStyle(ActivityPalette.secondary)
                        .activityFont(11, relativeTo: .caption2, digits: true)
                }
                Text(ui: time).foregroundStyle(FlightWidgetDisplay.color(tone))
                    .activityFont(15, .semibold, relativeTo: .subheadline, digits: true)
                if let dayMark {
                    Text(ui: dayMark).activityFont(10, .semibold, relativeTo: .caption2)
                        .foregroundStyle(FlightWidgetDisplay.color(tone))
                }
                if let scheduled, alignment == .leading {
                    Text(ui: scheduled).strikethrough().foregroundStyle(ActivityPalette.secondary)
                        .activityFont(11, relativeTo: .caption2, digits: true)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The flight number with a small plane, in grey.
struct WidgetIdent: View {
    var ident: String
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane").font(.system(size: size - 2, weight: .semibold))
            Text(ui: ident).activityFont(size, .semibold, relativeTo: .footnote)
        }
        .foregroundStyle(ActivityPalette.secondary)
        .lineLimit(1)
    }
}

// MARK: - Next Flight, small

/// The next flight in a small square: number and status dot, the route, the countdown, and the time
/// that leads (departure before take-off, arrival after) in red or green.
public struct NextFlightSmallView: View {
    let display: FlightWidgetDisplay

    public init(_ display: FlightWidgetDisplay) { self.display = display }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WidgetIdent(ident: display.ident)
                Spacer(minLength: 4)
                Circle().fill(display.levelColor).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(ui: display.routeCodes)
                .activityFont(19, .semibold, relativeTo: .headline)
                .foregroundStyle(ActivityPalette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
            Spacer(minLength: 2)
            WidgetCountdown(display: display, size: 32)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(display.isPastDeparture ? "Arrives" : "Departs")
                    .activityFont(12, relativeTo: .caption)
                    .foregroundStyle(ActivityPalette.secondary)
                Text(ui: display.headlineTime)
                    .activityFont(15, .semibold, relativeTo: .subheadline, digits: true)
                    .foregroundStyle(display.headlineColor)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

// MARK: - Next Flight, medium

/// The next flight across: number, day and status; the two airports with their times (the schedule
/// struck through when it moved) and, in the air, the progress line between them; the gate and terminal
/// that matter now and the countdown.
public struct NextFlightMediumView: View {
    let display: FlightWidgetDisplay

    public init(_ display: FlightWidgetDisplay) { self.display = display }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                WidgetIdent(ident: display.ident)
                if let day = display.day {
                    Text(ui: day).activityFont(13, relativeTo: .footnote).foregroundStyle(ActivityPalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                FlightActivityStatus(display: display.activity, size: 13)
            }
            HStack(alignment: .center, spacing: 10) {
                WidgetEnd(code: display.flight.origin.code, time: display.departureTime,
                          scheduled: display.scheduledDeparture, tone: display.departureTone, alignment: .leading)
                if display.isAirborne {
                    FlightActivityProgress(display: display.activity)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "airplane")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ActivityPalette.secondary)
                        Rectangle().fill(ActivityPalette.track).frame(height: 1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
                WidgetEnd(code: display.flight.destination.code, time: display.arrivalTime,
                          scheduled: display.scheduledArrival, dayMark: display.arrivalDayMark,
                          tone: display.arrivalTone, alignment: .trailing)
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 6) {
                WidgetGateBadge(gate: display.gate, arriving: display.isPastDeparture)
                Text("Terminal \(display.terminal ?? "--")")
                    .activityFont(12, relativeTo: .caption)
                    .foregroundStyle(ActivityPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let c = display.countdown
                Text([c.value, c.unit].filter { !$0.isEmpty }.joined(separator: " "))
                    .activityFont(13, .semibold, relativeTo: .footnote, digits: true)
                    .foregroundStyle(c.value.isEmpty ? display.unitColor : ActivityPalette.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

// MARK: - Upcoming Flights, large

/// The next flights as rows like My Flights: the countdown column, then the number and day, the route
/// by city, and the two codes with their times. Each row opens its flight.
public struct UpcomingFlightsLargeView: View {
    let displays: [FlightWidgetDisplay]
    /// False draws the rows without their links: `ImageRenderer` (the snapshot tests) cannot draw a `Link`.
    var linked = true

    public init(_ displays: [FlightWidgetDisplay]) { self.displays = displays }

    public init(_ displays: [FlightWidgetDisplay], linked: Bool) { self.displays = displays; self.linked = linked }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("My Flights")
                    .activityFont(17, .bold, relativeTo: .headline)
                    .foregroundStyle(ActivityPalette.primary)
                Spacer()
                Image(systemName: "airplane")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ActivityPalette.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 4)
            ForEach(Array(displays.prefix(WidgetTimeline.listed).enumerated()), id: \.element.flight.id) { i, d in
                let row = UpcomingFlightRow(display: d, last: i == min(displays.count, WidgetTimeline.listed) - 1)
                if linked {
                    Link(destination: FlightLink.url(for: d.flight.id)) { row }
                } else {
                    row
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One row of the large widget.
struct UpcomingFlightRow: View {
    let display: FlightWidgetDisplay
    var last: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            WidgetCountdown(display: display, size: 24, alignment: .center)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    WidgetIdent(ident: display.ident, size: 12)
                    Spacer(minLength: 4)
                    if let day = display.day {
                        Text(ui: day).activityFont(12, relativeTo: .caption).foregroundStyle(ActivityPalette.secondary)
                    }
                }
                Text(ui: display.routeCities)
                    .activityFont(14, .semibold, relativeTo: .subheadline)
                    .foregroundStyle(ActivityPalette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 10) {
                    end(icon: "arrow.up.right", code: display.flight.origin.code, time: display.departureTime,
                        tone: display.departureTone, mark: nil)
                    end(icon: "arrow.down.right", code: display.flight.destination.code, time: display.arrivalTime,
                        tone: display.arrivalTone, mark: display.arrivalDayMark)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(ActivityPalette.track).frame(height: 0.5) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }

    private func end(icon: String, code: String, time: String, tone: FlightWidgetDisplay.Tone, mark: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ActivityPalette.background)
                .padding(3)
                .background(Circle().fill(ActivityPalette.secondary.opacity(0.75)))
            Text(ui: code).foregroundStyle(ActivityPalette.secondary)
            Text(time + (mark ?? "")).foregroundStyle(FlightWidgetDisplay.color(tone))
        }
        .activityFont(13, .medium, relativeTo: .footnote, digits: true)
        .lineLimit(1)
    }
}

// MARK: - Lock screen

/// Rectangular: number and route, the status line, the gate.
public struct NextFlightRectangularView: View {
    let display: FlightWidgetDisplay

    public init(_ display: FlightWidgetDisplay) { self.display = display }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "airplane")
                Text(ui: display.ident).fontWeight(.bold)
                Text(ui: display.routeCodes)
            }
            .font(.headline)
            .widgetAccentable()
            Text(ui: display.statusLine)
                .font(.subheadline)
            Text(ui: gateLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }

    private var gateLine: String {
        let gate = "Gate \(display.gate ?? "--")"
        guard let terminal = display.terminal else { return gate }
        return "\(gate) · Terminal \(terminal)"
    }
}

/// Circular: the progress ring around the plane while in the air, else the countdown under the plane.
public struct NextFlightCircularView: View {
    let display: FlightWidgetDisplay

    public init(_ display: FlightWidgetDisplay) { self.display = display }

    public var body: some View {
        Group {
            if display.isAirborne {
                Gauge(value: display.progress) {
                    Image(systemName: "airplane")
                } currentValueLabel: {
                    Image(systemName: "airplane").font(.system(size: 14, weight: .semibold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: display.flight.status == .canceled ? "xmark" : "airplane")
                            .font(.system(size: 12, weight: .semibold))
                            .widgetAccentable()
                        Text(display.shortCountdown ?? display.flight.destination.code)
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

/// Inline: "AF 84 · Gate G91 · 25m late".
public struct NextFlightInlineView: View {
    let display: FlightWidgetDisplay

    public init(_ display: FlightWidgetDisplay) { self.display = display }

    public var body: some View {
        Label(display.inlineText, systemImage: "airplane")
    }
}

// MARK: - Empty

/// Nothing followed. The lock screen families say it in a word; the home screen ones invite a follow.
public struct FlightWidgetEmptyView: View {
    public enum Size: Sendable { case small, medium, large, rectangular, circular, inline }
    let size: Size

    public init(_ size: Size) { self.size = size }

    public var body: some View {
        switch size {
        case .inline:
            Label("No upcoming flights", systemImage: "airplane")
        case .circular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "airplane").font(.system(size: 18, weight: .semibold)).widgetAccentable()
            }
            .accessibilityLabel("No upcoming flights")
        case .rectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Soma Flight", systemImage: "airplane").font(.headline).widgetAccentable()
                Text("No upcoming flights").font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .small, .medium, .large:
            VStack(alignment: size == .small ? .leading : .center, spacing: 6) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: size == .small ? 22 : 28, weight: .semibold))
                    .foregroundStyle(ActivityPalette.secondary)
                    .accessibilityHidden(true)
                Text("No upcoming flights")
                    .activityFont(size == .small ? 15 : 17, .semibold, relativeTo: .headline)
                    .foregroundStyle(ActivityPalette.primary)
                Text("Add a flight in Soma Flight to see it here.")
                    .activityFont(13, relativeTo: .footnote)
                    .foregroundStyle(ActivityPalette.secondary)
                    .multilineTextAlignment(size == .small ? .leading : .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size == .small ? .bottomLeading : .center)
        }
    }
}
#endif
