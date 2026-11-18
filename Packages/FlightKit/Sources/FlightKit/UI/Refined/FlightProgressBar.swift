import SwiftUI

/// A thin trip progress bar (R1, R3): a `tickOff` track, the flown part in the delay colour, and an optional
/// head dot ringed in the card colour so it reads as a plane on the line.
/// Penpot: Progress
public struct FlightProgressBar: View {
    var progress: Double
    var tone: Color
    var height: CGFloat
    var showsHead: Bool
    @Environment(\.metricsScale) private var scale

    /// - Parameters:
    ///   - progress: fraction flown, clamped to 0...1.
    ///   - tone: the flown part's colour (`FlightStatusSummary.tone`).
    ///   - height: the track's thickness in reference points.
    ///   - showsHead: draws the 10 pt head dot with its 2 pt card ring.
    public init(progress: Double, tone: Color, height: CGFloat = 3, showsHead: Bool = true) {
        self.progress = min(1, max(0, progress.isFinite ? progress : 0))
        self.tone = tone; self.height = height; self.showsHead = showsHead
    }

    public var body: some View {
        let h = Theme.metric(height, scale)
        let head = Theme.metric(10, scale), ring = Theme.metric(2, scale)
        let frameH = showsHead ? head + 2 * ring : h
        GeometryReader { geo in
            let w = geo.size.width, x = w * progress
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tickOff).frame(height: h)
                Capsule().fill(tone).frame(width: x, height: h)
                if showsHead {
                    Circle()
                        .fill(tone)
                        .frame(width: head, height: head)
                        .padding(ring)
                        .background(Circle().fill(Theme.card))
                        .offset(x: min(max(x - head / 2 - ring, 0), max(w - head - 2 * ring, 0)))
                }
            }
            .frame(width: w, height: frameH)
        }
        .frame(height: frameH)
        .accessibilityElement()
        .accessibilityLabel("Flight progress")
        .accessibilityValue(Self.spokenProgress(progress))
    }

    /// "45%" in the app's language ("45 %" in French), for VoiceOver (A11).
    static func spokenProgress(_ progress: Double) -> String {
        min(1, max(0, progress.isFinite ? progress : 0))
            .formatted(.percent.precision(.fractionLength(0)).locale(FlightActivityDisplay.uiLocale))
    }
}

#Preview("Progress bars") {
    VStack(spacing: 20) {
        FlightProgressBar(progress: 0.45, tone: Theme.late)
        FlightProgressBar(progress: 0.1, tone: Theme.onTime)
        FlightProgressBar(progress: 0.9, tone: Theme.veryLate)
        FlightProgressBar(progress: 0.6, tone: Theme.onTime, showsHead: false)
    }
    .padding(20)
    .background(Theme.card)
}
