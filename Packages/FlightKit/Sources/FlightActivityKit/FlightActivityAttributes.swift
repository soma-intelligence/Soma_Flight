import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The Live Activity of one followed flight. Shared by the app (which starts and updates it) and the
/// widget extension (which draws it).
///
/// The static part is set once, at start. Besides the ident and the two codes it keeps the flight id
/// (to find the activity of a flight again after a relaunch), the scheduled times (the content state
/// only has the best times, and the delay colour needs both) and the two airports' time zones (times
/// show in local time, as everywhere in the app).
public struct FlightActivityAttributes: Codable, Hashable, Sendable {
    public var flightId: UUID
    public var ident: String
    public var originIata: String
    public var destinationIata: String
    public var scheduledOut: Date?
    public var scheduledIn: Date?
    /// IANA identifiers; nil shows the device's zone.
    public var originTimeZone: String?
    public var destinationTimeZone: String?

    public init(flightId: UUID, ident: String, originIata: String, destinationIata: String,
                scheduledOut: Date? = nil, scheduledIn: Date? = nil,
                originTimeZone: String? = nil, destinationTimeZone: String? = nil) {
        self.flightId = flightId; self.ident = ident
        self.originIata = originIata; self.destinationIata = destinationIata
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn
        self.originTimeZone = originTimeZone; self.destinationTimeZone = destinationTimeZone
    }

    /// What changes during the flight. The keys and value formats are the backend's `content-state`
    /// (push-sender): `status` is the flights table's string, `estimatedOut` and `estimatedIn` are ISO 8601
    /// strings (best estimate, else schedule) or null, `progress` is 0...1.
    ///
    /// ActivityKit decodes a pushed state with its own decoder, whose date strategy is not ISO 8601, so
    /// the dates are read and written as strings here. The app's own updates encode the same strings, so
    /// a state started by the app and one pushed by the backend decode alike.
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: FlightStatus
        public var gateOrigin: String?
        public var gateDestination: String?
        public var estimatedOut: Date?
        public var estimatedIn: Date?
        public var progress: Double

        public init(status: FlightStatus, gateOrigin: String? = nil, gateDestination: String? = nil,
                    estimatedOut: Date? = nil, estimatedIn: Date? = nil, progress: Double = 0) {
            self.status = status; self.gateOrigin = gateOrigin; self.gateDestination = gateDestination
            self.estimatedOut = estimatedOut; self.estimatedIn = estimatedIn
            self.progress = Self.clamp(progress)
        }

        enum CodingKeys: String, CodingKey {
            case status, gateOrigin, gateDestination, estimatedOut, estimatedIn, progress
        }

        /// Never fails on a value it does not know: an unknown or missing status is `.unknown`, an
        /// unreadable date is nil, a missing progress is 0. A failed decode would drop the whole update.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try? c.decodeIfPresent(String.self, forKey: .status)
            status = raw.flatMap(FlightStatus.init(rawValue:)) ?? .unknown
            gateOrigin = try? c.decodeIfPresent(String.self, forKey: .gateOrigin)
            gateDestination = try? c.decodeIfPresent(String.self, forKey: .gateDestination)
            estimatedOut = Self.date(c, .estimatedOut)
            estimatedIn = Self.date(c, .estimatedIn)
            progress = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .progress)) ?? 0)
        }

        /// Every key is written, null included, as the backend sends them.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status.rawValue, forKey: .status)
            try c.encode(gateOrigin, forKey: .gateOrigin)
            try c.encode(gateDestination, forKey: .gateDestination)
            try c.encode(estimatedOut.map(ISODate.string), forKey: .estimatedOut)
            try c.encode(estimatedIn.map(ISODate.string), forKey: .estimatedIn)
            try c.encode(progress, forKey: .progress)
        }

        private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
            guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return ISODate.parse(s)
        }

        private static func clamp(_ p: Double) -> Double { p.isFinite ? min(1, max(0, p)) : 0 }

        /// The flight is over for the activity: the backend ends it on these too.
        public var isFinal: Bool { status == .arrived || status == .canceled }
    }
}

#if canImport(ActivityKit) && os(iOS)
extension FlightActivityAttributes: ActivityAttributes {}
#endif

/// ISO 8601 as the backend writes it (`2026-10-29T14:05:00+00:00`, `...05:00.123456Z`).
public enum ISODate {
    private static let style = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// With or without fractional seconds (any number of digits), `Z` or a numeric offset, `T` or a
    /// space between date and time. Nil when it is not a date.
    public static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replace(at: 10, with: "T")
        }
        // The format style reads the seconds' fraction inconsistently, so it is cut out and added back.
        var fraction = 0.0
        if let t = s.firstIndex(of: "T"), let dot = s[t...].firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
            s.removeSubrange(dot..<s.index(dot, offsetBy: digits.count + 1))
        }
        guard let base = try? style.parse(s) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    /// UTC, `Z`; fractional seconds (milliseconds) only when the date has some.
    public static func string(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        return t.rounded(.down) == t ? date.formatted(style) : date.formatted(fractional)
    }
}

private extension String {
    mutating func replace(at offset: Int, with c: Character) {
        let i = index(startIndex, offsetBy: offset)
        replaceSubrange(i...i, with: String(c))
    }
}
