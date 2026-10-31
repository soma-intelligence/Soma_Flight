import SwiftUI

/// The airport sheet's Security section: every checkpoint's standard and PreCheck wait, live or an
/// estimate, with where the figures come from. US airports only (the store has no wait elsewhere).
struct AirportSecuritySection: View {
    var wait: SecurityWait
    var timeZone: TimeZone

    /// "Checkpoint waits at this hour", "Checkpoint waits right now" when live, or "Typical wait at this
    /// hour" for the one whole-airport row.
    static func subtitle(_ w: SecurityWait) -> String {
        if w.checkpoints.allSatisfy(\.isWholeAirport) { return "Typical wait at this hour" }
        return w.isLive ? "Checkpoint waits right now" : "Checkpoint waits at this hour"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Security", subtitle: Self.subtitle(wait), large: true)
                .scaledPadding(.bottom, 14)
            SecurityCheckpointList(wait: wait, terminal: nil, timeZone: timeZone)
        }
    }
}

#if DEBUG
#Preview("Security, SFO") {
    ScrollView {
        AirportSecuritySection(wait: SecurityWaitPreviews.sfo, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
            .padding(20)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
#endif
