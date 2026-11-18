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

    /// "Fri, 30 Oct" in `tz` ("ven. 30 oct." in French), in the app's language.
    static func headerDay(_ date: Date, _ tz: TimeZone) -> String {
        let english = FlightActivityDisplay.uiLocale.language.languageCode?.identifier == "en"
        guard !english else { return dayFormatter("EEE, d MMM", tz).string(from: date) }
        var style = Date.FormatStyle(locale: FlightActivityDisplay.uiLocale, timeZone: tz)
        style = style.weekday(.abbreviated).day().month(.abbreviated)
        return date.formatted(style)
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
        // Other languages get their own units ("6 h 50 min"), from the same formatter as the rows.
        guard Format.englishUI else { return Format.minutes(m) }
        let h = m / 60, r = m % 60
        return h == 0 ? "\(r)m" : "\(h)h \(r < 10 ? "0" : "")\(r)m"
    }

    /// The countdown card's line: time to the gate departure, time to arrival in the air, or how it ended.
    /// `destination` is where the flight actually goes (the diversion target when diverted).
    static func countdown(_ f: Flight, destination: Airport?, now: Date) -> String {
        switch f.status {
        case .canceled:
            return Format.words("Canceled")
        case .diverted:
            guard let d = destination, d.id != f.destinationIcao else { return Format.words("Diverted") }
            let code = d.iata ?? d.id
            return Format.words("Diverted to \(code)")
        case .landed, .arrived:
            return Format.words("Landed")
        case .departed, .enRoute:
            guard let end = f.actualIn ?? f.estimatedIn ?? f.scheduledIn else { return Format.words("In the air") }
            let m = Int(end.timeIntervalSince(now) / 60)
            let left = span(minutes: m)
            return m < 1 ? Format.words("Arriving now") : Format.words("Arrives in \(left)")
        case .scheduled, .unknown:
            guard let out = f.actualOut ?? f.estimatedOut ?? f.scheduledOut else { return Format.words("Scheduled") }
            let seconds = out.timeIntervalSince(now)
            if seconds >= 86_400 {
                let days = Int(seconds / 86_400)
                return days == 1 ? Format.words("Departs in 1 day") : Format.words("Departs in \(days) days")
            }
            let m = Int(seconds / 60)
            let left = span(minutes: m)
            return m < 1 ? Format.words("Departing now") : Format.words("Departs in \(left)")
        }
    }

    /// The card's second line: the airline and where the flight stands.
    static func countdownCaption(_ f: Flight, airline: Airline?) -> String {
        let status: String = switch f.status {
        case .scheduled, .unknown: Format.words("Scheduled")
        case .departed: Format.words("Left the gate")
        case .enRoute: Format.words("In the air")
        case .landed: Format.words("Landed")
        case .arrived: Format.words("At the gate")
        case .canceled: Format.words("Canceled")
        case .diverted: Format.words("Diverted")
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
            let total = span(minutes: Int(arr.timeIntervalSince(out) / 60))
            parts.append(Format.words("Total \(total)"))
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

/// The pinned top of the flight sheet, as the Detail header (R5): the airline's logo, "UA 990 · FRI, 30 OCT"
/// in small caps, the route as the 20 pt title, and the 44 pt glass close button. On the Mac the bar's
/// buttons sit here too (`actions`).
struct DetailHeader: View {
    var flight: Flight
    var origin: Airport?
    var destination: Airport?
    var airline: Airline?
    var onClose: (() -> Void)?
    /// Drawn between the title and the close button (the Mac panel's share, bell and menu).
    var actions: AnyView?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var overline: String { DetailFacts.headerLine(flight, origin: origin) }
    private var title: String {
        ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            // A12: at accessibility sizes the route wraps instead of "Paris to S...": the mark, actions and
            // close sit on their own row above the words.
            WrappingDetailHeader(overline: overline, title: title, actions: actions, onClose: onClose) { logo }
        } else {
            SheetHeader.detail(overline: overline, title: title, onClose: onClose) {
                logo
            } actions: {
                if let actions { actions }
            }
        }
    }

    private var logo: some View {
        AirlineLogo(airline: airline, code: airline?.iata ?? TravelFacts.airlineCode(ident: flight.ident),
                    size: 36, decorative: true)
    }
}

/// The Detail header at accessibility text sizes (A12): the mark, the actions and the close button on one
/// row, then the overline and the title on as many lines as they need. Shared by the flight and airport sheets.
struct WrappingDetailHeader<Mark: View>: View {
    var overline: String
    var title: String
    var actions: AnyView?
    var onClose: (() -> Void)?
    @ViewBuilder var mark: () -> Mark
    @Environment(\.metricsScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.metric(Theme.Space.xs, scale)) {
            HStack(spacing: Theme.metric(Theme.Space.sm, scale)) {
                mark()
                    .frame(width: Theme.metric(36, scale), height: Theme.metric(36, scale))
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                if let actions { HStack(spacing: Theme.metric(Theme.Space.xs, scale)) { actions } }
                if let onClose { CloseButton(inset: false, action: onClose) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: overline)
                    .scaledFont(11, weight: .semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ui: title)
                    .themeFont(.sheetTitle)
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .scaledPadding(.horizontal, Theme.gutter)
        .scaledPadding(.vertical, 6)
    }
}

// MARK: - Bottom bar

/// The Mac panel's flight actions: share, the alert bell (followed flights only) and the menu of rarer
/// actions as small circles in the header. The phone shows them in the glass action bar
/// (`FlightDetailView.actionBar`, R4).
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
        HStack(spacing: 6) {
            ShareLink(item: share, preview: SharePreview(share.title)) { icon("square.and.arrow.up") }
                .accessibilityLabel("Share Flight")
            bell
            more
        }
        .buttonStyle(.plain)
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
