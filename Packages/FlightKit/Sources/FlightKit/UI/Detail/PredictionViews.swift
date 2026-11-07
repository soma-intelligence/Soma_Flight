import SwiftUI

// MARK: - Wording

enum PredictionFacts {
    /// Good to Know's delay row: "Likely 25 min late" over "Inbound aircraft running late. High confidence,
    /// the airline has not changed its time yet."
    static func delayRow(_ p: DelayPrediction) -> (title: String, text: String) {
        (p.headline, "\(p.cause) \(p.confidence.title), the airline has not changed its time yet.")
    }

    /// Good to Know's gate row: "Likely gate B22" over "Used 6 of the last 7 days. Shown until the airline
    /// assigns the gate."
    static func gateRow(_ p: GatePrediction) -> (title: String, text: String) {
        let terminal = p.guess != .terminal ? p.terminal.map { " in terminal \($0)" } ?? "" : ""
        return (p.headline + terminal, "\(p.detail). Shown until the airline assigns the gate.")
    }

    /// The symbol of a delay's reason.
    static func symbol(_ r: DelayPrediction.Reason) -> String {
        switch r {
        case .lateInbound: "airplane.arrival"
        case .originWeather, .destinationWeather: "cloud.bolt.rain"
        case .congestion: "airplane.departure"
        case .history: "clock.arrow.circlepath"
        }
    }
}

// MARK: - Good to Know

/// Good to Know's prediction card: the likely delay with its reason, and the likely gate with how often it
/// was used. Shown only while there is something to predict; both rows go once the airline says more.
struct PredictionCard: View {
    var delay: DelayPrediction?
    var gate: GatePrediction?

    var body: some View {
        if delay != nil || gate != nil {
            DetailCard {
                if let delay {
                    let row = PredictionFacts.delayRow(delay)
                    InfoRow(symbol: PredictionFacts.symbol(delay.reason),
                            tint: delay.confidence == .low ? Theme.secondary : Theme.late,
                            title: row.title, titleTint: delay.confidence == .low ? Theme.primary : Theme.late,
                            text: row.text)
                        .accessibilityLabel("Prediction: \(delay.headline). \(row.text)")
                }
                if delay != nil, gate != nil {
                    Hairline().scaledPadding(.vertical, 14)
                }
                if let gate {
                    let row = PredictionFacts.gateRow(gate)
                    InfoRow(symbol: "door.left.hand.open", tint: Theme.secondary, title: row.title, text: row.text)
                        .accessibilityLabel("Prediction: \(row.title). \(row.text)")
                }
            }
        }
    }
}

// MARK: - Gate badge

/// The gate badge's guess, until the real gate arrives: the gate (or the concourse) in the badge's yellow
/// on a dashed outline, lighter than an assigned gate.
struct PredictedGateBadge: View {
    var label: String
    var arriving: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arriving ? "arrow.down.right" : "arrow.up.right")
                .scaledFont(14, weight: .bold)
            Text(ui: label).scaledFont(18, weight: .semibold)
        }
        .foregroundStyle(GateBadge.yellow.opacity(0.85))
        .scaledPadding(.horizontal, 10)
        .scaledPadding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(GateBadge.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gate not assigned, likely \(label)")
    }
}

#if DEBUG
#Preview("Predictions") {
    VStack(spacing: 16) {
        PredictionCard(
            delay: DelayPrediction(minutes: 25, reason: .lateInbound, confidence: .high,
                                   reasonTitle: "Late inbound aircraft",
                                   summary: "Likely 25 min late: inbound aircraft running late"),
            gate: GatePrediction(guess: .gate, gate: "B22", concourse: "B", terminal: "2", used: 6, of: 7,
                                 label: "B22", detail: "Used 6 of the last 7 days"))
        PredictionCard(
            delay: DelayPrediction(minutes: 45, reason: .originWeather, confidence: .medium,
                                   reasonTitle: "Weather at SFO", summary: "Likely 45 min late: weather at SFO"),
            gate: GatePrediction(guess: .concourse, concourse: "A", terminal: "International", used: 20, of: 24,
                                 fromAirline: true, label: "Concourse A", detail: "Where AF usually departs"))
        PredictionCard(
            delay: DelayPrediction(minutes: 30, reason: .history, confidence: .low, reasonTitle: "Often late",
                                   summary: "Likely 30 min late: this flight often leaves late"),
            gate: nil)
        HStack(spacing: 12) {
            GateBadge(gate: "B22", arriving: false)
            PredictedGateBadge(label: "B22", arriving: false)
            PredictedGateBadge(label: "A gates", arriving: false)
            GateBadge(gate: nil, arriving: false)
        }
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
