import SwiftUI

// MARK: - Wording

/// The words of the "Leave by" row and its breakdown. No SwiftUI here, so the tests read the exact text.
enum LeaveTimeFacts {
    /// "Leave by 14:20", or "Time to leave" once that time has passed.
    static func title(_ t: LeaveTime, tz: TimeZone, clock: TimeStyle, now: Date) -> String {
        t.leaveAt <= now ? "Time to leave" : "Leave by \(Format.clock(t.leaveAt, tz, clock))"
    }

    /// The row's grey line: "35m drive · about 20m security · 45m bag drop", or the rule it follows.
    static func summary(_ t: LeaveTime) -> String {
        guard let b = t.breakdown else { return rule(t) }
        return ["\(Format.minutes(Int(b.drive / 60))) drive",
                "\(SecurityWaitFacts.amount(b.securityMinutes, live: b.securityIsLive, capital: false)) security",
                "\(Format.minutes(Int(b.bagDrop / 60))) bag drop"].joined(separator: " · ")
    }

    /// "3 hours before an international flight".
    static func rule(_ t: LeaveTime) -> String {
        t.international ? "3 hours before an international flight" : "2 hours before a domestic flight"
    }

    /// The breakdown's lines for a computed time, from the road to the gate: (symbol, title, text).
    static func lines(_ b: LeaveTime.Breakdown, departure: Date, international: Bool, tz: TimeZone,
                      clock: TimeStyle) -> [(symbol: String, title: String, text: String)] {
        let lane = b.precheck ? "PreCheck lane" : "Standard lane"
        let queue = SecurityWaitFacts.amount(b.securityMinutes, live: b.securityIsLive)
        return [
            ("car.fill", "\(Format.minutes(Int(b.drive / 60))) drive",
             "From where you were at \(Format.clock(b.measuredAt, tz, clock)), by car"),
            ("suitcase.rolling.fill", "\(Format.minutes(Int(b.bagDrop / 60))) bag drop",
             international ? "For an international flight" : "For a domestic flight"),
            ("person.badge.shield.checkmark", "\(queue) at security",
             "\(lane), \(b.securityIsLive ? "live" : "an estimate") at \(Format.clock(b.measuredAt, tz, clock))"),
            ("figure.walk.departure", "Boarding at \(Format.clock(b.boardingAt, tz, clock))",
             "\(Format.minutes(Int(b.boardingLead / 60))) before departure on a \(b.wideBody ? "wide-body" : "narrow-body")"),
            ("airplane.departure", "Departs at \(Format.clock(departure, tz, clock))", "As scheduled"),
        ]
    }

    static let computedNote = "Soma Flight aims to have you at the gate when boarding starts. Whether you check bags isn't known, so the bag drop always counts. The drive and the queue update each time you open the flight."

    /// Why the usual rule applies, from what the estimator last found; nil when nothing is known yet.
    static func gapText(_ gap: LeaveTimeGap?) -> String? {
        switch gap {
        case .location(.denied): "Location is off for Soma Flight. Allow it while using the app, in Settings, to time this from where you are."
        case .location: "Allow your location while using the app and Soma Flight times this from where you are: the drive, the security queue, the bag drop and boarding."
        case .notYet: "In the 12 hours before the flight, Soma Flight times this from where you are."
        case .aircraft: "The aircraft isn't known yet, so neither is boarding. This updates once it is."
        case .security: "There's no security wait for this airport, so the usual rule applies."
        case .route: "Couldn't get a driving time just now. This updates the next time you open the flight."
        case .airport: "This airport isn't in Soma Flight's list, so the usual rule applies."
        case nil: nil
        }
    }
}

// MARK: - Row

/// Good to Know's "Leave by 14:20" row on the departure side: computed from the drive, the queue, the
/// bag drop and boarding when the estimator has them, else the usual rule. Opening the flight measures
/// again (foreground only); tapping shows the breakdown. Hidden without an estimator or once the flight
/// has left.
struct LeaveByRow: View {
    var flight: Flight
    var now: Date
    @Environment(\.leaveTimes) private var estimator
    @Environment(\.units) private var units
    /// Read so the row redraws when the PreCheck switch changes.
    @AppStorage(LeaveTimeSettings.precheckKey) private var precheck = false
    @State private var showing = false

    var body: some View {
        if let estimator, let t = estimator.leaveTime(for: flight), t.departure > now {
            let tz = estimator.timeZone(for: flight)
            let _ = precheck
            DetailCard(padded: false) {
                Button { showing = true } label: {
                    InfoRow(symbol: "car.fill", tint: t.leaveAt <= now ? Theme.late : Theme.primary,
                            title: LeaveTimeFacts.title(t, tz: tz, clock: units.clock, now: now),
                            text: LeaveTimeFacts.summary(t), chevron: true)
                        .scaledPadding(.all, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows how this time is worked out")
            }
            .task(id: flight.id) { await estimator.measure(flight) }
            .sheet(isPresented: $showing) {
                LeaveTimeSheet(flight: flight, estimator: estimator, now: now, onClose: { showing = false })
                    .environment(\.units, units)
                    .presentationDetents([.medium, .large])
                    #if os(macOS)
                    .frame(minWidth: 380, minHeight: 460)
                    #endif
            }
        }
    }
}

/// How the leave time is reached: each part from the road to the gate, or the usual rule with why and,
/// when location has not been asked yet, the button that asks.
struct LeaveTimeSheet: View {
    var flight: Flight
    var estimator: LeaveTimeEstimator
    var now: Date
    var onClose: () -> Void
    @Environment(\.units) private var units
    @Environment(\.openURL) private var openURL
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let t = estimator.leaveTime(for: flight) {
                    let tz = estimator.timeZone(for: flight)
                    CardTitle(LeaveTimeFacts.title(t, tz: tz, clock: units.clock, now: now),
                              subtitle: "\(Format.ident(flight.ident)) from \(flight.originCode)")
                        .scaledPadding(.trailing, 44)
                        .scaledPadding(.bottom, 16)
                    if let b = t.breakdown {
                        DetailCard {
                            let lines = LeaveTimeFacts.lines(b, departure: t.departure, international: t.international,
                                                             tz: tz, clock: units.clock)
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                if i > 0 { Hairline().scaledPadding(.vertical, 12) }
                                InfoRow(symbol: line.symbol, title: line.title, text: line.text)
                            }
                        }
                        note(LeaveTimeFacts.computedNote)
                    } else {
                        DetailCard {
                            InfoRow(symbol: "clock.fill", title: "The usual rule", text: LeaveTimeFacts.rule(t))
                        }
                        if let text = LeaveTimeFacts.gapText(estimator.gaps[flight.id]) { note(text) }
                        locationButton
                    }
                }
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.vertical, 24)
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
    }

    @ViewBuilder private var locationButton: some View {
        switch estimator.locationAccess {
        case .notDetermined:
            button(asking ? "Asking…" : "Use My Location") {
                asking = true
                Task {
                    await estimator.requestLocation(for: flight)
                    asking = false
                }
            }
        case .denied:
            button("Open Settings", action: openSystemSettings)
        case .allowed:
            EmptyView()
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .scaledPadding(.vertical, 14)
                .background(Capsule().fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(asking)
        .scaledPadding(.top, 20)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .scaledFont(13)
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .scaledPadding(.top, 14)
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { openURL(url) }
        #endif
    }
}
