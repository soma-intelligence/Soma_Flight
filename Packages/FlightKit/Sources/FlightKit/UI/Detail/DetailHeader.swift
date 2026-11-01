import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Wording

extension DetailFacts {
    /// "UA 990 · FRI, 30 OCT": the flight number, then the day it leaves in the origin's zone.
    static func headerLine(_ f: Flight, origin: Airport?) -> String {
        let ident = Format.ident(f.ident)
        guard let out = f.scheduledOut ?? f.estimatedOut ?? f.actualOut else { return ident }
        return "\(ident) · \(headerDay(out, origin?.timeZone ?? .current).uppercased())"
    }

    /// "Fri, 30 Oct" in `tz`, in English like the rest of the app.
    static func headerDay(_ date: Date, _ tz: TimeZone) -> String {
        dayFormatter("EEE, d MMM", tz).string(from: date)
    }

    private static func dayFormatter(_ format: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }

    /// "10h 55m", "3h 05m", "12m": hours and zero-padded minutes, minutes alone under an hour.
    static func span(minutes total: Int) -> String {
        let m = max(total, 0)
        let h = m / 60, r = m % 60
        return h == 0 ? "\(r)m" : "\(h)h \(r < 10 ? "0" : "")\(r)m"
    }

    /// The countdown card's line: time to the gate departure, time to arrival in the air, or how it ended.
    /// `destination` is where the flight actually goes (the diversion target when diverted).
    static func countdown(_ f: Flight, destination: Airport?, now: Date) -> String {
        switch f.status {
        case .canceled:
            return "Canceled"
        case .diverted:
            guard let d = destination, d.id != f.destinationIcao else { return "Diverted" }
            return "Diverted to \(d.iata ?? d.id)"
        case .landed, .arrived:
            return "Landed"
        case .departed, .enRoute:
            guard let end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn else { return "In the air" }
            let m = Int(end.timeIntervalSince(now) / 60)
            return m < 1 ? "Arriving now" : "Arrives in \(span(minutes: m))"
        case .scheduled, .unknown:
            guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut else { return "Scheduled" }
            let seconds = out.timeIntervalSince(now)
            if seconds >= 86_400 {
                let days = Int(seconds / 86_400)
                return "Departs in \(days) \(days == 1 ? "day" : "days")"
            }
            let m = Int(seconds / 60)
            return m < 1 ? "Departing now" : "Departs in \(span(minutes: m))"
        }
    }

    /// The card's second line: the airline and where the flight stands.
    static func countdownCaption(_ f: Flight, airline: Airline?) -> String {
        let status: String = switch f.status {
        case .scheduled, .unknown: "Scheduled"
        case .departed: "Left the gate"
        case .enRoute: "In the air"
        case .landed: "Landed"
        case .arrived: "At the gate"
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        }
        guard let name = airline?.name else { return status }
        return "\(name) · \(status)"
    }

    /// The status card once the flight is down: "Arrived 32m Early", "Landed 3m Late", "Arrived On Time";
    /// nil before landing, or when the arrival cannot be set against its schedule.
    static func landedTitle(_ f: Flight) -> String? {
        guard f.status == .landed || f.status == .arrived,
              let offset = offsetMinutes(scheduled: f.scheduledIn, estimated: f.estimatedIn,
                                         actual: f.actualIn ?? f.actualOn),
              let word = offsetWord(offset) else { return nil }
        return "\(f.status == .arrived ? "Arrived" : "Landed") \(word)"
    }

    /// "Total 10h 50m · 8,965 km": gate to gate and the distance, for a flight that is down.
    static func landedCaption(_ f: Flight, origin: Airport?, destination: Airport?, unit: DistanceUnit) -> String? {
        var parts: [String] = []
        if let out = bestOut(f), let arr = bestIn(f), arr > out {
            parts.append("Total \(span(minutes: Int(arr.timeIntervalSince(out) / 60)))")
        }
        if let km = distanceKm(origin: origin, destination: destination) { parts.append(TravelFacts.distance(km, unit)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The status card's tint: green early or on time, red late, none until there is an estimate or
    /// an actual arrival, and none before departure or when canceled or diverted.
    static func statusTone(_ f: Flight) -> Color? {
        guard [.departed, .enRoute, .landed, .arrived].contains(f.status),
              let offset = offsetMinutes(scheduled: f.scheduledIn, estimated: f.estimatedIn,
                                         actual: f.actualIn ?? f.actualOn) else { return nil }
        return offset >= 1 ? Theme.veryLate : Theme.onTime
    }

    /// "UA 990 San Francisco to Paris, departs Fri 30 Oct 15:20 SFO".
    static func shareText(_ f: Flight, origin: Airport?, destination: Airport?, clock: TimeStyle = .h24) -> String {
        let route = ScreenFormat.route(origin?.city ?? f.originCode, destination?.city ?? f.destinationCode)
        var text = "\(Format.ident(f.ident)) \(route)"
        if let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut {
            let tz = origin?.timeZone ?? .current
            let day = dayFormatter("EEE d MMM", tz).string(from: out)
            text += ", departs \(day) \(Format.clock(out, tz, clock)) \(f.originCode)"
        }
        return text
    }
}

// MARK: - Header

/// The pinned top of the flight sheet: the airline's logo, "UA 990 · FRI, 30 OCT", the route as the
/// title, and the close button. On the Mac the bottom bar's buttons sit here too (`actions`).
struct DetailHeader: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var onClose: (() -> Void)?
    /// Drawn between the title and the close button (the Mac panel's share, bell and menu).
    var actions: AnyView?
    @ScaledMetric(relativeTo: .title3) private var logo: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AirlineLogo(airline: airline, code: airline?.iata ?? TravelFacts.airlineCode(ident: flight.ident),
                        size: logo, decorative: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(DetailFacts.headerLine(flight, origin: origin))
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode))
                    .themeFont(.sheetTitle)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let actions { actions }
            if let onClose {
                RoundButton(systemImage: "xmark", label: "Close", action: onClose)
            }
        }
    }
}

/// The rounded card under the header: "Departs in 1 day" and the airline with the flight's state.
struct CountdownCard: View {
    var title: String
    var caption: String
    /// Green or red once the arrival can be set against its schedule; nil keeps the grey card.
    var tone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(tone ?? Theme.primary)
            Text(caption)
                .scaledFont(15, weight: tone == nil ? .regular : .medium)
                .foregroundStyle(tone.map { $0.opacity(0.85) } ?? Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tone.map { $0.opacity(0.16) } ?? Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(tone.map { $0.opacity(0.35) } ?? Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom bar

/// The floating controls at the bottom of the flight sheet: the menu of rarer actions and the flight's
/// alert bell (followed flights only) as glass circles on the left, a blue Share capsule on the right.
/// `compact` is the Mac panel's form: share, bell and menu as small circles in the header.
struct DetailBottomBar<Menu: View>: View {
    /// The live link and the flight in words (`FlightShareItem`).
    var share: FlightShareItem
    /// Alerts on or off; nil hides the bell (the flight is not followed or sends no more alerts).
    var notify: Bool?
    var onNotify: (Bool) -> Void
    var compact = false
    @ViewBuilder var menu: () -> Menu
    @Environment(\.metricsScale) private var scale

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                ShareLink(item: share, preview: SharePreview(share.title)) { icon("square.and.arrow.up") }
                    .accessibilityLabel("Share Flight")
                bell
                more
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                more
                    .glassEffect(.regular.tint(HomeTabPill.tint).interactive(), in: .circle)
                if notify != nil {
                    bell
                        .glassEffect(.regular.tint(HomeTabPill.tint).interactive(), in: .circle)
                }
                Spacer(minLength: 12)
                ShareLink(item: share, preview: SharePreview(share.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: Theme.fontSize(18, scale), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.metric(22, scale))
                        .frame(height: Theme.metric(52, scale))
                        .contentShape(Capsule())
                }
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                .accessibilityLabel("Share Flight")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var bell: some View {
        if let notify {
            Button { onNotify(!notify) } label: {
                icon(notify ? "bell.fill" : "bell.slash")
            }
            .accessibilityLabel(notify ? "Turn Off Alerts" : "Turn On Alerts")
            .accessibilityValue(notify ? "On" : "Off")
        }
    }

    private var more: some View {
        SwiftUI.Menu {
            menu()
        } label: {
            icon("ellipsis")
        }
        .menuIndicator(.hidden)
        // Share stays on top even when the menu opens upward from the bottom bar.
        .menuOrder(.fixed)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        // The borderless menu drops its label's background: the circle goes behind the menu instead.
        .frame(width: compact ? Theme.metric(34, scale) : nil, height: compact ? Theme.metric(34, scale) : nil)
        .background { if compact { Circle().fill(Theme.pill) } }
        #endif
        .accessibilityLabel("More")
    }

    private func icon(_ name: String) -> some View {
        let side = Theme.metric(compact ? 34 : 52, scale)
        return Image(systemName: name)
            .font(.system(size: Theme.fontSize(compact ? 15 : 19, scale), weight: .semibold))
            .foregroundStyle(Theme.primary)
            .frame(width: side, height: side)
            .contentShape(Circle())
            .modifier(CompactCircle(on: compact))
            .help(name == "ellipsis" ? "More" : name == "square.and.arrow.up" ? "Share Flight" : "Alerts")
    }
}

/// The circle behind a header action beside the close X: the same glass as the X on the phone; on the
/// Mac the flat pill colour, which its borderless menu also draws behind "More".
private struct CompactCircle: ViewModifier {
    var on: Bool

    func body(content: Content) -> some View {
        if on {
            #if os(iOS)
            content.roundGlass()
            #else
            content.background(Circle().fill(Theme.pill))
            #endif
        } else {
            content
        }
    }
}

enum Pasteboard {
    /// Puts plain text on the system pasteboard.
    /// With `sensitive`, it stays on this device (no Universal Clipboard) and expires after two minutes.
    @MainActor static func copy(_ text: String, sensitive: Bool = false) {
        #if canImport(UIKit)
        if sensitive {
            UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                          options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
        } else {
            UIPasteboard.general.string = text
        }
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
