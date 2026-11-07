import SwiftUI

/// What the flight sheet's security row needs: the wait at the departure airport, the passenger's
/// terminal (nil when unknown) and that airport's clock for the time stamp.
struct SecurityRowData {
    var wait: SecurityWait
    var terminal: String?
    var timeZone: TimeZone
}

/// Good to Know's security row: the shortest wait for the passenger's terminal, PreCheck too, and whether
/// it is live or an estimate. Tapping it opens every checkpoint (`SecurityWaitSheet`).
struct SecurityWaitRow: View {
    var data: SecurityRowData
    @Environment(\.units) private var units
    @State private var showing = false

    var body: some View {
        if let row = SecurityWaitFacts.row(data.wait, terminal: data.terminal, timeZone: data.timeZone,
                                           clock: units.clock) {
            DetailCard(padded: false) {
                Button { showing = true } label: {
                    InfoRow(symbol: "person.badge.shield.checkmark", title: row.title, text: row.text, chevron: true)
                        .scaledPadding(.all, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows every security checkpoint")
            }
            .sheet(isPresented: $showing) {
                SecurityWaitSheet(data: data, onClose: { showing = false })
                    .environment(\.units, units)
                    .presentationDetents([.medium, .large])
                    #if os(macOS)
                    .frame(minWidth: 380, minHeight: 420)
                    #endif
            }
        }
    }
}

/// Every checkpoint of the departure airport, the passenger's terminal first.
struct SecurityWaitSheet: View {
    var data: SecurityRowData
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle("Security", subtitle: data.wait.iata ?? data.wait.airportIcao)
                    .scaledPadding(.trailing, 44)
                    .scaledPadding(.bottom, 16)
                SecurityCheckpointList(wait: data.wait, terminal: data.terminal, timeZone: data.timeZone)
            }
            .scaledPadding(.horizontal, Theme.gutter)
            .scaledPadding(.vertical, 24)
        }
        .background(Theme.background)
        .overlay(alignment: .topTrailing) { CloseButton(action: onClose) }
    }
}

/// The Live or Estimate tag with its time, the checkpoints (those of `terminal` first and marked), and
/// where the figures come from. Shared by the flight's sheet and the airport's Security section.
struct SecurityCheckpointList: View {
    var wait: SecurityWait
    var terminal: String?
    var timeZone: TimeZone
    @Environment(\.units) private var units

    /// The passenger's checkpoints first, each group in the backend's order.
    var ordered: [(checkpoint: SecurityCheckpoint, yours: Bool)] {
        let mine = SecurityWaitFacts.candidates(wait, terminal: terminal)
        guard mine.matched else { return wait.checkpoints.map { ($0, false) } }
        let ids = Set(mine.checkpoints.map(\.id))
        return mine.checkpoints.map { ($0, true) } + wait.checkpoints.filter { !ids.contains($0.id) }.map { ($0, false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(wait.isLive ? "Live" : "Estimate")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(wait.isLive ? Theme.onTime : Theme.secondary)
                    .scaledPadding(.horizontal, 8)
                    .scaledPadding(.vertical, 3)
                    .background(Capsule().strokeBorder(wait.isLive ? Theme.onTime : Theme.separator, lineWidth: 1))
                Text(SecurityWaitFacts.stamp(wait, timeZone: timeZone, clock: units.clock))
                    .scaledFont(14)
                    .foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
            .scaledPadding(.bottom, 12)
            ForEach(Array(ordered.enumerated()), id: \.element.checkpoint.id) { i, item in
                if i > 0 { Hairline() }
                row(item.checkpoint, yours: item.yours)
            }
            Text(SecurityWaitFacts.footnote(wait))
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.top, 14)
        }
    }

    private func row(_ c: SecurityCheckpoint, yours: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: c.name).scaledFont(17, weight: .medium).foregroundStyle(Theme.primary)
                let caption = [SecurityWaitFacts.terminalCaption(c), yours ? "Your terminal" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                if !caption.isEmpty {
                    Text(ui: caption).scaledFont(14).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(SecurityWaitFacts.checkpointText(c, live: wait.isLive))
                .scaledFont(15, weight: .medium)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.trailing)
        }
        .scaledPadding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
// MARK: - Previews

private let previewWait = SecurityWaitPreviews.sfo

enum SecurityWaitPreviews {
    /// SFO at 07:30 on a Tuesday, from the fakes.
    static let sfo: SecurityWait = {
        let sfo = Airport(id: "KSFO", iata: "SFO", name: "San Francisco International Airport", city: "San Francisco",
                          country: "US", lat: 37.62, lon: -122.37, tz: "America/Los_Angeles")
        return FakeSecurityWaitService.wait(sfo, at: ISO8601DateFormatter().date(from: "2026-11-03T15:30:00Z")!)!
    }()

    /// The same figures, as a live source would send them.
    static var live: SecurityWait {
        var w = sfo
        w.isLive = true
        w.source = .init(id: "airport_feed", name: "the airport's checkpoint sensors")
        return w
    }
}

#Preview("Row, estimate") {
    SecurityWaitRow(data: .init(wait: previewWait, terminal: "3", timeZone: TimeZone(identifier: "America/Los_Angeles")!))
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}

#Preview("Row, live") {
    SecurityWaitRow(data: .init(wait: SecurityWaitPreviews.live, terminal: "1",
                                timeZone: TimeZone(identifier: "America/Los_Angeles")!))
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.light)
}

#Preview("Sheet") {
    SecurityWaitSheet(data: .init(wait: previewWait, terminal: "3", timeZone: TimeZone(identifier: "America/Los_Angeles")!),
                      onClose: {})
        .preferredColorScheme(.dark)
}
#endif
