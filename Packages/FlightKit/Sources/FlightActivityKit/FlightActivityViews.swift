import SwiftUI

/// The app's dark tokens (FlightKit `Theme`, dark values) for the Live Activity and the widgets, which
/// are always drawn dark. `LiveActivityStateTests` checks they still match the theme.
public enum ActivityPalette {
    public static let background = Color(hex: 0x18181A)
    public static let track = Color(hex: 0x373738)
    public static let primary = Color(hex: 0xFFFFFF)
    public static let secondary = Color(hex: 0x96969D)
    public static let onTime = Color(hex: 0x12B76A)
    public static let late = Color(hex: 0xFDB022)
    public static let veryLate = Color(hex: 0xFF453A)
    public static let canceled = Color(hex: 0xFFFFFF)
    public static let diverted = Color(hex: 0xBF5AF2)
    /// The flight sheet's gate badge (FlightKit `GateBadge.yellow`), and the pill of a gate not assigned
    /// yet (`Theme.pill`). The widgets draw them.
    public static let gate = Color(hex: 0xF4C430)
    public static let pill = Color(hex: 0x2C2C2F)

    public static func color(_ level: DelayLevel) -> Color {
        switch level {
        case .onTime: onTime
        case .late: late
        case .veryLate: veryLate
        case .canceled: canceled
        case .diverted: diverted
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A fixed design size that still follows Dynamic Type (the system honours it on the lock screen and
/// in the island), as the app's `scaledFont` does.
struct ActivityFont: ViewModifier {
    @ScaledMetric var size: CGFloat
    var weight: Font.Weight
    var digits: Bool

    init(_ size: CGFloat, _ weight: Font.Weight, relativeTo style: Font.TextStyle, digits: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight; self.digits = digits
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: weight)
        return content.font(digits ? font.monospacedDigit() : font)
    }
}

extension View {
    func activityFont(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body,
                      digits: Bool = false) -> some View {
        modifier(ActivityFont(size, weight, relativeTo: style, digits: digits))
    }
}

extension FlightActivityDisplay {
    var levelColor: Color { ActivityPalette.color(level) }
    /// Status text: white when on time or canceled, as on the flight card, else the level colour.
    var statusColor: Color { level == .onTime || level == .canceled ? ActivityPalette.primary : levelColor }
    /// The bar: white when on time (the flight card's look), else the level colour.
    var barColor: Color { level == .onTime ? ActivityPalette.primary : levelColor }
}

// MARK: - Lock screen

/// The lock screen and notification banner: number and status, the two airports with their times,
/// the progress line with the plane, and the gates.
public struct FlightActivityLockScreenView: View {
    let display: FlightActivityDisplay

    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.ident)
                    .activityFont(17, .semibold, relativeTo: .headline)
                    .foregroundStyle(ActivityPalette.primary)
                Spacer(minLength: 8)
                FlightActivityStatus(display: display, size: 15)
            }
            HStack(alignment: .center, spacing: 12) {
                FlightActivityEnd(code: display.attributes.originIata, time: display.departureTime,
                                  scheduled: display.scheduledDeparture, alignment: .leading)
                    .accessibilityLabel(display.spokenEnd(departure: true))
                FlightActivityProgress(display: display)
                FlightActivityEnd(code: display.attributes.destinationIata, time: display.arrivalTime,
                                  scheduled: display.scheduledArrival, dayMark: display.arrivalDayMark,
                                  alignment: .trailing)
                    .accessibilityLabel(display.spokenEnd(departure: false))
            }
            HStack {
                Text(display.originGate)
                Spacer()
                Text(display.destinationGate)
            }
            .activityFont(13, relativeTo: .footnote)
            .foregroundStyle(ActivityPalette.secondary)
            .accessibilityHidden(true) // read with each end
        }
        .padding(16)
    }
}

/// Dot and status text.
public struct FlightActivityStatus: View {
    let display: FlightActivityDisplay
    var size: CGFloat

    public init(display: FlightActivityDisplay, size: CGFloat) { self.display = display; self.size = size }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(display.levelColor).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(display.statusText)
                .activityFont(size, .medium, relativeTo: .subheadline)
                .foregroundStyle(display.statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// An airport code over its best time, the schedule struck through beside it when the time moved.
public struct FlightActivityEnd: View {
    var code: String
    var time: String
    var scheduled: String?
    var dayMark: String?
    var alignment: HorizontalAlignment

    public init(code: String, time: String, scheduled: String?, dayMark: String? = nil, alignment: HorizontalAlignment) {
        self.code = code; self.time = time; self.scheduled = scheduled; self.dayMark = dayMark
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code)
                .activityFont(28, .semibold, relativeTo: .title)
                .foregroundStyle(ActivityPalette.primary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let scheduled {
                    Text(scheduled).strikethrough().foregroundStyle(ActivityPalette.secondary)
                }
                Text(time).foregroundStyle(ActivityPalette.primary)
                if let dayMark {
                    Text(dayMark).activityFont(11, .semibold, relativeTo: .caption2).foregroundStyle(ActivityPalette.secondary)
                }
            }
            .activityFont(15, relativeTo: .subheadline, digits: true)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
    }
}

/// The progress line with the plane where the flight is now, as on the flight card.
public struct FlightActivityProgress: View {
    let display: FlightActivityDisplay

    public init(display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        let p = display.progress
        let dimmed = display.state.status == .canceled
        GeometryReader { geo in
            let w = geo.size.width
            let plane: CGFloat = 16
            let x = min(max(plane / 2, w * p), w - plane / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(ActivityPalette.track).frame(height: 3)
                Capsule().fill(display.barColor.opacity(dimmed ? 0.4 : 1)).frame(width: max(0, w * p), height: 3)
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(dimmed ? ActivityPalette.secondary : display.barColor)
                    .accessibilityHidden(true)
                    .frame(width: plane, height: plane)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Progress \(Int((p * 100).rounded())) percent")
    }
}

// MARK: - Dynamic Island

/// Compact leading: the plane in the level colour and the destination.
public struct FlightActivityCompactLeading: View {
    let display: FlightActivityDisplay
    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane").foregroundStyle(display.levelColor)
            Text(display.attributes.destinationIata).foregroundStyle(ActivityPalette.primary)
        }
        .activityFont(15, .semibold, relativeTo: .subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

/// Compact trailing: departure time before take-off, arrival time after, the status once it is over.
public struct FlightActivityCompactTrailing: View {
    let display: FlightActivityDisplay
    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        Text(display.compactTime)
            .activityFont(15, .semibold, relativeTo: .subheadline, digits: true)
            .foregroundStyle(display.statusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(display.isPastDeparture ? "Arrives \(display.compactTime)" : "Departs \(display.compactTime)")
    }
}

/// Minimal: a ring of the progress around the plane.
public struct FlightActivityMinimal: View {
    let display: FlightActivityDisplay
    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        ZStack {
            Circle().stroke(ActivityPalette.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: display.progress)
                .stroke(display.levelColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "airplane")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(display.levelColor)
        }
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spokenSummary)
    }
}

/// Expanded leading and trailing: an airport code over its time.
public struct FlightActivityExpandedEnd: View {
    var code: String
    var time: String
    var alignment: HorizontalAlignment
    public init(code: String, time: String, alignment: HorizontalAlignment) {
        self.code = code; self.time = time; self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(code).activityFont(24, .semibold, relativeTo: .title2).foregroundStyle(ActivityPalette.primary)
            Text(time).activityFont(14, relativeTo: .subheadline, digits: true).foregroundStyle(ActivityPalette.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Expanded center: number and status.
public struct FlightActivityExpandedCenter: View {
    let display: FlightActivityDisplay
    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        VStack(spacing: 2) {
            Text(display.ident).activityFont(15, .semibold, relativeTo: .subheadline).foregroundStyle(ActivityPalette.primary)
            FlightActivityStatus(display: display, size: 13)
        }
    }
}

/// Expanded bottom: the progress line and the gates.
public struct FlightActivityExpandedBottom: View {
    let display: FlightActivityDisplay
    public init(_ display: FlightActivityDisplay) { self.display = display }

    public var body: some View {
        VStack(spacing: 6) {
            FlightActivityProgress(display: display)
            HStack {
                Text(display.originGate)
                Spacer()
                Text(display.destinationGate)
            }
            .activityFont(13, relativeTo: .footnote)
            .foregroundStyle(ActivityPalette.secondary)
        }
        .padding(.horizontal, 6)
    }
}
