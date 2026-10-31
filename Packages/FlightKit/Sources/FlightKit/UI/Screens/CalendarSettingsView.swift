import SwiftUI

/// Settings > Calendar: one switch that puts every followed flight in a calendar on this device, the
/// calendar to use (the app's own "Soma Flight" one by default), and what each event holds. Full calendar
/// access is asked for only when the switch is turned on; a refusal shows a row to the system settings.
public struct CalendarSettingsView: View {
    var sync: CalendarSync
    var onDone: (() -> Void)?
    var scrolls: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var working = false

    /// - Parameter onDone: shows a Done button in the header row (the Mac sheet); nil leaves it out.
    public init(sync: CalendarSync, onDone: (() -> Void)? = nil) {
        self.init(sync: sync, onDone: onDone, scrolls: true)
    }

    init(sync: CalendarSync, onDone: (() -> Void)?, scrolls: Bool) {
        self.sync = sync; self.onDone = onDone; self.scrolls = scrolls
    }

    static let intro = "Put the flights you follow in your calendar. Each flight is one event from gate to gate, updated when its times, gate or status change, and removed when you stop following it."
    static let deniedTitle = "Calendar Access Is Off"
    static let deniedText = "Allow full access for Soma Flight in Settings so it can add and update its events."
    static let footnote = "Events are written on this device, into the calendar you pick. Soma Flight never sends your calendar anywhere."

    /// What each event holds, for the last group.
    static let contents: [(icon: String, title: String, text: String)] = [
        ("airplane", "Flight and route", "\"AF 84 Paris to San Francisco\", from departure to arrival in each airport's time"),
        ("mappin.and.ellipse", "Departure airport", "As the event's place, with its map"),
        ("note.text", "Terminal, gate, seat and booking code", "In the notes, when known"),
        ("link", "A link to the flight", "Opens it in Soma Flight"),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onDone {
                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, 8)
            }
            ScreenTitle("Calendar")
                .scaledPadding(.horizontal, Theme.gutter)
                .scaledPadding(.top, onDone == nil ? 22 : 0)
                .scaledPadding(.bottom, 16)
            ScreenScroll(scrolls: scrolls) { content }
        }
        .background(Theme.background)
        .onAppear { sync.refresh() }
        // Back from the system settings with access granted or taken away.
        .onChange(of: phase) { _, new in if new == .active { sync.refresh() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.intro)
                .scaledFont(15)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
            group("Sync") {
                SettingsRow(icon: "calendar.badge.plus", title: "Add Flights to Calendar", subtitle: status, last: true) {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("Add Flights to Calendar", isOn: Binding(get: { sync.isEnabled }, set: setEnabled))
                            .labelsHidden()
                            .tint(Theme.accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if sync.access == .denied || sync.access == .writeOnly {
                group("Access") {
                    SettingsRow(icon: "exclamationmark.triangle.fill", title: Self.deniedTitle, subtitle: Self.deniedText,
                                tint: Theme.late, last: true, action: openSystemSettings) { RowChevron() }
                }
            }
            if sync.isEnabled, sync.access == .full {
                group("Calendar") {
                    if sync.calendarMissing {
                        Text("The calendar Soma Flight was using is gone. Pick another one.")
                            .scaledFont(15)
                            .foregroundStyle(Theme.late)
                            .scaledPadding(.horizontal, 16)
                            .scaledPadding(.vertical, 12)
                    }
                    ForEach(sync.calendars) { c in
                        CalendarChoiceRow(calendar: c, selected: c.id == sync.calendarId,
                                          madeByApp: c.id == sync.appCalendarId, last: c.id == sync.calendars.last?.id) {
                            sync.choose(calendar: c.id)
                        }
                    }
                }
            }
            if let failure = sync.failure {
                Text(failure)
                    .scaledFont(13)
                    .foregroundStyle(Theme.late)
                    .scaledPadding(.horizontal, 16)
                    .scaledPadding(.top, 8)
            }
            group("In Each Event") {
                ForEach(Array(Self.contents.enumerated()), id: \.offset) { i, item in
                    SettingsRow(icon: item.icon, title: item.title, subtitle: item.text,
                                last: i == Self.contents.count - 1) { EmptyView() }
                        .accessibilityElement(children: .combine)
                }
            }
            Text(Self.footnote)
                .scaledFont(13)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 8)
        }
        .scaledPadding(.bottom, 32)
    }

    /// The switch's grey line: what it does now.
    private var status: String {
        guard sync.isEnabled else { return "Off" }
        let name = sync.calendars.first { $0.id == sync.calendarId }?.title ?? CalendarSync.appCalendarTitle
        let n = sync.eventCount
        return n == 0 ? "On, in \(name)" : "\(n) \(n == 1 ? "flight" : "flights") in \(name)"
    }

    private func setEnabled(_ on: Bool) {
        working = true
        Task {
            await sync.setEnabled(on)
            working = false
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsHeader(title)
                .scaledPadding(.horizontal, 16)
                .scaledPadding(.top, 34)
                .scaledPadding(.bottom, 8)
            Hairline().scaledPadding(.horizontal, 16)
            rows()
            Hairline().scaledPadding(.horizontal, 16)
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { openURL(url) }
        #endif
    }
}

/// A calendar to pick: its colour, its name and account, a checkmark on the one in use.
struct CalendarChoiceRow: View {
    var calendar: CalendarInfo
    var selected: Bool
    var madeByApp: Bool
    var last: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 16) {
                    Circle()
                        .fill(Color(.sRGB, red: calendar.red, green: calendar.green, blue: calendar.blue))
                        .frame(width: 14, height: 14)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calendar.title).scaledFont(17).foregroundStyle(Theme.primary)
                        let caption = [calendar.source.isEmpty ? nil : calendar.source, madeByApp ? "Made by Soma Flight" : nil]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !caption.isEmpty {
                            Text(caption).scaledFont(13).foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark")
                            .scaledFont(16, weight: .semibold)
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .scaledPadding(.horizontal, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if !last { Hairline().scaledPadding(.leading, 60).scaledPadding(.trailing, 16) }
        }
    }
}

#if DEBUG
// MARK: - Previews

struct CalendarSettingsPreview: View {
    var on = true
    var access: CalendarAccess = .notDetermined
    @State private var sync: CalendarSync?

    var body: some View {
        Group {
            if let sync { CalendarSettingsView(sync: sync, onDone: {}) } else { ProgressView() }
        }
        .task {
            let s = CalendarSync(store: FakeCalendarStore(access: access, grant: .full), lookup: { _ in nil }, defaults: nil)
            if on { await s.setEnabled(true) }
            sync = s
        }
    }
}

#Preview("Calendar, on") { CalendarSettingsPreview().preferredColorScheme(.dark) }
#Preview("Calendar, denied") { CalendarSettingsPreview(on: false, access: .denied).preferredColorScheme(.dark) }
#endif
