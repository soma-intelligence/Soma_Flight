import SwiftUI

// MARK: - Severity dot

/// A small filled circle in a delay or severity colour. Always paired with words (R9), so it is hidden from
/// VoiceOver.
/// Penpot: Status line/Dot
public struct SeverityDot: View {
    var color: Color
    var diameter: CGFloat
    @Environment(\.metricsScale) private var scale

    /// - Parameter diameter: in reference points (7 in a status line, 8 beside a cause row).
    public init(_ color: Color, diameter: CGFloat = 7) {
        self.color = color; self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: Theme.metric(diameter, scale), height: Theme.metric(diameter, scale))
            .accessibilityHidden(true)
    }
}

// MARK: - Status line

/// A coloured dot and the words of a status, in the same colour: "Departed 16m late · lands 05:28" (R1).
/// Penpot: Status line
public struct StatusLine: View {
    var text: String
    var tone: Color

    public init(_ text: String, tone: Color) {
        self.text = text; self.tone = tone
    }

    /// The line of a `FlightStatusSummary`.
    public init(_ status: FlightStatusSummary) {
        self.init(status.text, tone: status.tone)
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            SeverityDot(tone)
            Text(ui: text)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(tone)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status pill

/// The small glass capsule under a header: "Offline · positions estimated", "Refreshing".
/// Penpot: Status pill
public struct StatusPill: View {
    var text: String
    var systemImage: String
    var tone: Color

    /// - Parameter tone: the icon and text colour, secondary by default.
    public init(_ text: String, systemImage: String, tone: Color = Theme.secondary) {
        self.text = text; self.systemImage = systemImage; self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(ui: text)
                .lineLimit(1)
        }
        .scaledFont(13, weight: .semibold)
        .foregroundStyle(tone)
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Status lines") {
    VStack(alignment: .leading, spacing: 14) {
        StatusLine("On time · gate B22", tone: Theme.onTime)
        StatusLine("Departed 16m late · lands 05:28", tone: Theme.late)
        StatusLine("48m late · lands 06:00", tone: Theme.veryLate)
        StatusLine(FlightStatusSummary(text: "Canceled", level: .canceled))
        StatusLine("Diverted to OAK", tone: Theme.diverted)
        HStack(spacing: 8) {
            SeverityDot(Theme.late, diameter: 8)
            Text("Weather in Paris").scaledFont(15)
        }
        StatusPill("Offline · positions estimated", systemImage: "wifi.slash")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.background)
}
