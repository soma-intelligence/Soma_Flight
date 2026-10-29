import Foundation

public enum TimeStyle: Sendable, Hashable {
    case h24, h12
}

/// Wall-clock time in `tz` with its abbreviation, e.g. `18:25 CDT`.
public func localTime(_ date: Date, in tz: TimeZone, style: TimeStyle) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = tz
    f.dateFormat = style == .h24 ? "HH:mm zzz" : "h:mm a zzz"
    return f.string(from: date)
}
