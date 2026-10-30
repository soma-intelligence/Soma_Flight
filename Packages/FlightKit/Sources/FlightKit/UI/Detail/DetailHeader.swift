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
/// title, and the close button.
struct DetailHeader: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var onClose: (() -> Void)?
    @ScaledMetric(relativeTo: .title3) private var logo: CGFloat = 32

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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(18, weight: .semibold)
                .foregroundStyle(Theme.primary)
            Text(caption)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledPadding(.horizontal, 16)
        .scaledPadding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom bar

/// The floating bar at the bottom of the flight sheet: share, the flight's alert bell (followed flights
/// only) and a menu of the rarer actions.
struct DetailBottomBar<Menu: View>: View {
    var shareText: String
    /// Alerts on or off; nil hides the bell (the flight is not followed or sends no more alerts).
    var notify: Bool?
    var onNotify: (Bool) -> Void
    @ViewBuilder var menu: () -> Menu
    @Environment(\.metricsScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            ShareLink(item: shareText) {
                icon("square.and.arrow.up")
            }
            .accessibilityLabel("Share Flight")
            if let notify {
                Button { onNotify(!notify) } label: {
                    icon(notify ? "bell.fill" : "bell.slash")
                }
                .accessibilityLabel(notify ? "Turn Off Alerts" : "Turn On Alerts")
                .accessibilityValue(notify ? "On" : "Off")
            }
            SwiftUI.Menu {
                menu()
            } label: {
                icon("ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .scaledPadding(.horizontal, 8)
        .glassEffect(.regular.tint(HomeTabPill.tint), in: .capsule)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: Theme.fontSize(19, scale), weight: .medium))
            .foregroundStyle(Theme.primary)
            .frame(width: Theme.metric(54, scale), height: Theme.metric(50, scale))
            .contentShape(Rectangle())
    }
}

enum Pasteboard {
    /// Puts plain text on the system pasteboard.
    @MainActor static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
