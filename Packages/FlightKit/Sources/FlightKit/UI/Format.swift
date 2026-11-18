import Foundation

/// Small display formatters shared by the components.
enum Format {
    /// "18:25" in `tz`, or "6:25 PM" for `.h12`. Screens pass `Units.clock` from the environment.
    static func clock(_ date: Date, _ tz: TimeZone, _ style: TimeStyle = .h24) -> String {
        FlightActivityDisplay.clock(date, tz, twelveHour: style == .h12)
    }

    /// "2h 37m", "50m", "2h".
    static func minutes(_ total: Int) -> String { FlightActivityDisplay.duration(minutes: total) }

    /// The catalog's words for a format key ("Arrives in %@") in the app's language, the English key filled
    /// in when the catalog has none (tests run in English) (A1).
    static func words(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .main) }

    /// True while the app's text is English, where the compact spans ("6h 05m") stay as they are.
    static var englishUI: Bool { FlightActivityDisplay.uiLocale.language.languageCode?.identifier == "en" }

    /// Whole minutes, truncated toward zero. `DelayLevel` uses the same value, so a label and its
    /// colour always agree (14m 30s is "14m", on time).
    static func minutes(_ d: Duration) -> Int { DelayLevel.wholeMinutes(d) }

    /// "AA 2178", "B6 717", "EJM 444": airline code, space, number.
    static func ident(_ raw: String) -> String { FlightActivityDisplay.ident(raw) }

    /// "just now", "4 min. ago", "2 hr. ago", "3 days ago" in English, "à l'instant", "il y a 4 min" in
    /// French: `Date.AnchoredRelativeFormatStyle` in the app's language (A1). Under a minute is "just now".
    static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "just now", bundle: .main) }
        let style = Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .numeric, unitsStyle: .abbreviated,
                                                     locale: FlightActivityDisplay.uiLocale)
        return style.format(now)
    }

    /// "Updated 4 min. ago" ("Mis à jour il y a 4 min"), or "Last update 3 hr. ago" once `stale`.
    static func updated(_ date: Date, now: Date, stale: Bool = false) -> String {
        let ago = ago(date, now: now)
        return stale ? String(localized: "Last update \(ago)", bundle: .main)
            : String(localized: "Updated \(ago)", bundle: .main)
    }
}

extension Flight {
    var originCode: String { originIata ?? originIcao }
    var destinationCode: String { destinationIata ?? destinationIcao }

    /// The level that colours this flight: departure delay before take-off, arrival delay after.
    var level: DelayLevel {
        let delay: Duration? = switch status {
        case .landed, .arrived, .enRoute: arrivalDelay ?? departureDelay
        default: departureDelay
        }
        return DelayLevel.for(delay: delay, status: status)
    }
}
