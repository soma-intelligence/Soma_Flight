import Foundation

/// How many times the traveller has flown the aircraft on screen, by its registration (tail number).
public enum TailVisits {
    /// The flight's place among the traveller's flights on its tail, counting it: 3 for the third time.
    /// Only earlier flights in the history count (a Passport flight opened later is not counted after
    /// itself), canceled ones do not, and the flight's own history row is skipped. nil when the registration
    /// is unknown or the history has no earlier flight on it.
    public static func ordinal(_ flight: Flight, past: [PastFlight]) -> Int? {
        guard let reg = PassportStore.registrationKey(flight.registration) else { return nil }
        let when = flight.actualOut ?? flight.estimatedOut ?? flight.scheduledOut
        let earlier = past.filter { p in
            guard p.status != .canceled, PassportStore.registrationKey(p.registration) == reg,
                  !isSame(p, flight, when: when) else { return false }
            return when.map { p.date < $0 } ?? true
        }
        return earlier.isEmpty ? nil : earlier.count + 1
    }

    /// The history row of the flight itself: same id (a Passport flight), or same number leaving within a day.
    private static func isSame(_ p: PastFlight, _ f: Flight, when: Date?) -> Bool {
        if p.id == f.id { return true }
        guard let when, p.ident.uppercased() == f.ident.uppercased() else { return false }
        return abs(p.date.timeIntervalSince(when)) < 86_400
    }
}

/// What the flight sheet says about the tail.
enum TailVisitFacts {
    /// "3rd" in English, "3e" in French: in the language the app runs in.
    static func ordinal(_ n: Int, locale: Locale = appLocale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "Your 3rd flight on F-GSQA".
    static func badge(_ n: Int, registration: String, locale: Locale = appLocale) -> String {
        let nth = ordinal(n, locale: locale)
        let reg = registration.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return String(localized: "Your \(nth) flight on \(reg)", bundle: .main)
    }

    /// The app's own language (the catalog's), so the ordinal matches the sentence around it.
    static var appLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }
}
