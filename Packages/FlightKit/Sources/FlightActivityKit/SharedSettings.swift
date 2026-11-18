import Foundation
import os

/// Settings the app shares with its widget extension through the App Group. Only the clock today: the
/// Live Activity shows times the way Settings asks (24 or 12 hour).
public enum SharedSettings {
    /// The App Group both the iOS app and the widget extension carry in their entitlements.
    public static let appGroup = "group.me.somalabs.flight"
    /// True (or absent) for 24 hour times, false for 12 hour.
    public static let clock24Key = "units.clock24"

    /// The group's defaults on iOS, where the extension reads them, and on the watch, where the
    /// complications read the watch app's snapshot (the watch has its own container, so the same group
    /// name holds the watch's copy); the app's own on the Mac, which has no extension and no App Group.
    /// Falls back to the app's own when the group cannot be opened.
    public static var defaults: UserDefaults {
        #if os(iOS) || os(watchOS)
        if let group = UserDefaults(suiteName: appGroup) { return group }
        Logger(subsystem: "me.somalabs.flight", category: "settings")
            .error("App Group \(appGroup, privacy: .public) unavailable: the Live Activity will not see the clock setting")
        return .standard
        #else
        .standard
        #endif
    }

    /// Whether times read as "6:25 PM" rather than "18:25": the user's choice in Settings, else the
    /// device's region (A11).
    public static func twelveHour(in defaults: UserDefaults = SharedSettings.defaults, locale: Locale = .current) -> Bool {
        if let clock24 = defaults.object(forKey: clock24Key) as? Bool { return !clock24 }
        return !localeUses24Hour(locale)
    }

    /// The device's own clock, for a user who never chose one: 24 hour unless the region writes 12.
    public static func localeUses24Hour(_ locale: Locale = .current) -> Bool {
        switch locale.hourCycle {
        case .oneToTwelve, .zeroToEleven: false
        default: true
        }
    }

    /// The device's own distance unit, for a user who never chose one: miles where the region measures in
    /// miles (US, UK), else kilometres (A11).
    public static func localeUsesMiles(_ locale: Locale = .current) -> Bool {
        locale.measurementSystem == .us || locale.measurementSystem == .uk
    }
}
