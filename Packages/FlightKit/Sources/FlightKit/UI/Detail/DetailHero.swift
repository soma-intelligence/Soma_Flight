import SwiftUI

// MARK: - Wording

/// The words of the flight sheet's hero status card (R3). No SwiftUI here, so the tests read the exact text.
///
/// One card says what the old countdown banner, the canceled or diverted notice and the "At a glance" outlook
/// said apart: the headline, the airline with where the flight stands and the time left, the line the outlook
/// rested on (or the notice's sentence), and the progress along the route. Its colour is the level of
/// `FlightStatusSummary`, so the hero and the home row always agree.
struct HeroFacts: Equatable, Sendable {
    /// "Landing 11m late", "Canceled", "Diverted to OAK".
    var headline: String
    /// "Air France · in the air · arrives in 6h 49m".
    var subline: String?
    /// What the headline rests on ("Airline estimate", "Predicted. ..."), or the canceled or diverted sentence.
    var note: String?
    /// The delay level behind the bar, the headline and the progress colour.
    var level: DelayLevel
    /// Fraction of the trip flown, 0...1; nil hides the progress bar (canceled, diverted).
    var progress: Double?
    /// The gate grid shows for every flight but a canceled or diverted one (`GlanceFacts.isShown`).
    var showsGrid: Bool

    /// The bar and headline colour (red for canceled, the delay colour otherwise).
    var tone: Color { FlightStatusSummary.tone(for: level) }

    static let canceledNote = "The airline canceled this flight. Check with them for a new booking."

    /// - Parameters:
    ///   - planned: the planned destination (nil once diverted elsewhere), for the distance once down.
    ///   - actual: where the flight actually goes (the diversion target when diverted).
    static func make(_ f: Flight, airline: Airline?, origin: Airport?, planned: Airport?, actual: Airport?,
                     prediction: DelayPrediction?, unit: DistanceUnit, clock: TimeStyle, now: Date) -> HeroFacts {
        let summary = FlightStatusSummary.make(for: f, now: now, origin: origin, destination: actual, clock: clock)
        let outlook = GlanceFacts.outlook(f, prediction: prediction)
        let countdown = DetailFacts.countdown(f, destination: actual, now: now)

        let headline: String, note: String?
        switch f.status {
        case .canceled:
            headline = "Canceled"; note = canceledNote
        case .diverted:
            headline = summary.text
            let to = actual.flatMap { $0.id == f.destinationIcao ? nil : "\($0.city) (\($0.iata ?? $0.id))" }
            note = to.map { "Landing at \($0) instead of \(f.destinationCode)." }
                ?? "Not landing at \(f.destinationCode). The new airport is not known yet."
        default:
            headline = outlook?.title ?? countdown; note = outlook?.text
        }

        // The airline, where the flight stands, then the time left or how the trip went.
        var parts: [String] = []
        if let name = airline?.name { parts.append(name) }
        switch f.status {
        case .canceled, .diverted:
            break
        case .landed, .arrived:
            parts.append(stateWord(f.status))
            if let total = DetailFacts.landedCaption(f, origin: origin, destination: planned, unit: unit) {
                parts.append(lowerFirst(total))
            }
        case .departed, .enRoute:
            parts.append(stateWord(f.status))
            if countdown != "In the air" { parts.append(lowerFirst(countdown)) }
        case .scheduled, .unknown:
            parts.append(stateWord(f.status))
            if countdown != "Scheduled" { parts.append(lowerFirst(countdown)) }
        }

        let progress: Double? = switch f.status {
        case .canceled, .diverted: nil
        case .landed, .arrived: 1
        case .departed, .enRoute: summary.progress ?? f.progress(at: now)
        case .scheduled, .unknown: 0
        }
        return HeroFacts(headline: headline, subline: parts.isEmpty ? nil : parts.joined(separator: " · "),
                         note: note, level: summary.level, progress: progress, showsGrid: GlanceFacts.isShown(f))
    }

    /// "in the air", "left the gate", "at the gate": where the flight stands, in the middle of a line.
    static func stateWord(_ s: FlightStatus) -> String {
        switch s {
        case .scheduled, .unknown: "scheduled"
        case .departed: "left the gate"
        case .enRoute: "in the air"
        case .landed: "landed"
        case .arrived: "at the gate"
        case .canceled: "canceled"
        case .diverted: "diverted"
        }
    }

    /// "Departs in 1 day" as "departs in 1 day", for the middle of a line.
    static func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// "4 min ago", "just now": how old the last known data is, for the refresh error and the hero's stamp.
    static func age(since: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(DetailFacts.span(minutes: minutes)) ago"
    }
}

// MARK: - Card

/// The flight sheet's hero (R3): one white card with a 4 pt delay-colour bar on its leading edge. The headline
/// in the delay colour, the subline, the line it rests on, a progress bar with the two airport codes at its
/// ends, then the gate grid (departure gate, boarding, arrival gate, baggage belt). Replaces the countdown
/// banner, the canceled or diverted notice and the "At a glance" card, and keeps all they said.
/// Penpot: Card/Status
struct DetailHeroCard: View {
    var facts: HeroFacts
    var flight: Flight
    var origin: Airport?
    var aircraft: AircraftType?
    var pass: BoardingPass?
    var predictedGate: GatePrediction?
    /// "4 min ago" beside the headline while a refresh failed (R8); nil hides it.
    var stamp: String? = nil
    var now: Date
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        RefinedCard(severity: facts.tone, padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                if let progress = facts.progress {
                    route(progress)
                        .scaledPadding(.top, 12)
                }
                if facts.showsGrid {
                    Hairline().scaledPadding(.top, 14).scaledPadding(.bottom, 14)
                    grid
                }
            }
        }
        .id("glance")
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ui: facts.headline)
                    .scaledFont(19, weight: .semibold)
                    .foregroundStyle(facts.tone)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let stamp {
                    Label { Text(ui: stamp) } icon: { Image(systemName: "clock") }
                        .scaledFont(12, weight: .medium)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Last updated \(stamp)")
                }
            }
            if let subline = facts.subline {
                Text(ui: subline)
                    .themeFont(.sectionSubtitle)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = facts.note {
                Text(ui: note)
                    .themeFont(.sectionSubtitle)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func route(_ progress: Double) -> some View {
        HStack(spacing: 12) {
            Text(flight.originCode)
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Theme.primary)
            FlightProgressBar(progress: progress, tone: facts.tone, showsHead: flight.status == .departed
                              || flight.status == .enRoute)
            Text(flight.destinationCode)
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Theme.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flight.originCode) to \(flight.destinationCode)")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent of the trip")
    }

    @ViewBuilder private var grid: some View {
        let tz = origin?.timeZone ?? .current
        let cells = [GlanceFacts.departureGate(flight, predicted: predictedGate),
                     GlanceFacts.boarding(flight, pass: pass, aircraft: aircraft, tz: tz, clock: units.clock),
                     GlanceFacts.arrivalGate(flight),
                     GlanceFacts.belt(flight, now: now)]
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(cells.enumerated()), id: \.offset) { i, c in cell(c, badge: i == 0) }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) { cell(cells[0], badge: true); cell(cells[1], badge: false) }
                HStack(alignment: .top, spacing: 16) { cell(cells[2], badge: false); cell(cells[3], badge: false) }
            }
        }
    }

    /// One grid cell: the small caps label, the value (a yellow gate badge for the posted departure gate),
    /// and its caption ("Terminal 2E", "Left at 03:12", "Predicted" in amber).
    private func cell(_ c: GlanceFacts.Cell, badge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: UIText.localized(c.label).uppercased())
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.secondary)
            if badge && c.kind == .known {
                Text(ui: c.value)
                    .scaledFont(18, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(Theme.gateInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .scaledPadding(.horizontal, 8)
                    .scaledPadding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.gateBadge))
            } else {
                Text(ui: c.value)
                    .scaledFont(20, weight: c.kind == .placeholder ? .medium : .bold)
                    .monospacedDigit()
                    .foregroundStyle(c.kind == .placeholder ? Theme.secondary : Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let caption = c.caption {
                Text(ui: caption)
                    .scaledFont(13, weight: c.kind == .known ? .regular : .medium)
                    .foregroundStyle(c.kind == .predicted || c.kind == .estimated ? Theme.late : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
