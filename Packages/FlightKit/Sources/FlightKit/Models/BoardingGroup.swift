import Foundation

/// The traveller's boarding group as the pass prints it ("5", "Group 5", "Zone 3", "B"), read into a
/// position in the call order.
public struct BoardingGroup: Equatable, Sendable {
    /// What the airline calls it: "Group" or "Zone".
    public enum Word: String, Sendable { case group = "Group", zone = "Zone" }

    public var word: Word
    /// The group as written on the pass, upper case: "5", "B".
    public var name: String
    /// Its place in the call order, from 1 (a letter counts A = 1). 0 for a pre-boarding group.
    public var position: Int
    /// The place in the line inside a lettered group, from passes that print both ("A15": group A, 15th).
    public var place: Int?

    public init(word: Word, name: String, position: Int, place: Int? = nil) {
        self.word = word; self.name = name; self.position = position; self.place = place
    }

    /// "Group 5", "Zone 3".
    public var title: String { "\(word.rawValue) \(name)" }

    /// The group in a pass's group or zone field: its first number ("Group 5", "05"), else a single
    /// letter ("B", "Group C"). A letter right before the number ("A15", Southwest style) is the group, the
    /// number its place in the line. nil for an empty field or text with neither ("Priority", "SKY").
    public static func read(group: String?, zone: String?) -> BoardingGroup? {
        for (raw, field) in [(group, Word.group), (zone, Word.zone)] {
            guard let raw, let parsed = parse(raw, field: field) else { continue }
            return parsed
        }
        return nil
    }

    static func parse(_ raw: String, field: Word) -> BoardingGroup? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.isEmpty else { return nil }
        let word: Word = text.contains("ZONE") ? .zone : text.contains("GROUP") ? .group : field
        // The first run of digits.
        if let start = text.firstIndex(where: \.isASCIINumber) {
            let digits = text[start...].prefix(while: \.isASCIINumber)
            guard let n = Int(digits) else { return nil }
            // One letter glued before it ("A15", "GROUP B32"): the letter is the group.
            if start > text.startIndex {
                let before = text.index(before: start)
                let letter = text[before]
                let alone = before == text.startIndex || !text[text.index(before: before)].isLetter
                if alone, let position = letterPosition(letter) {
                    return BoardingGroup(word: word, name: String(letter), position: position, place: n)
                }
            }
            guard n <= 99 else { return nil }
            return BoardingGroup(word: word, name: String(n), position: n)
        }
        // A single letter, alone or after the word "Group" or "Zone".
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0 != "GROUP" && $0 != "ZONE" && $0 != "BOARDING" }
        guard words.count == 1, let only = words.first, only.count == 1,
              let position = letterPosition(Character(only)) else { return nil }
        return BoardingGroup(word: word, name: only, position: position)
    }

    /// A = 1, B = 2...; nil for anything but a plain capital letter.
    private static func letterPosition(_ c: Character) -> Int? {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1, ("A"..."Z").contains(scalar)
        else { return nil }
        return Int(scalar.value) - Int(UnicodeScalar("A").value) + 1
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}

/// When the traveller's boarding group is likely called: boarding opens (the time on the pass, else the
/// departure less the usual lead), a few minutes go to pre-boarding, then the groups are called one after
/// the other at an even pace until about 15 minutes before departure. A rough guide for the gate, always
/// shown as approximate.
public enum BoardingGroupTiming {
    /// Pre-boarding (help needed, families, top status) before the first numbered group.
    public static let preBoarding: TimeInterval = 5 * 60
    /// The last group is usually called about this long before departure, before the door closes.
    public static let lastCallBeforeDeparture: TimeInterval = 15 * 60
    /// Groups an airline outside the table calls, when the traveller's group is not higher.
    public static let defaultGroups = 6

    /// Numbered groups after pre-boarding, by ICAO code, for the airlines whose own boarding page says so
    /// (checked 2026-11-08). Others use `defaultGroups`.
    /// - United: Groups 1 to 6 (united.com/en/us/fly/travel/airport/boarding-process.html).
    /// - American: Groups 1 to 9 (aa.com/web/i18n/travel-info/boarding-process.html).
    /// - Delta: Zones 1 to 8 (delta.com/us/en/check-in-security/boarding-priority).
    /// - Southwest: Groups 1 to 8 since assigned seating, 2026-01-27 (southwest.com/customer-enhancements/assigned-seating/).
    /// - Alaska: Groups A to F (alaskaair.com/content/travel-info/flight-experience/our-boarding-process).
    public static let groupsByAirline: [String: Int] = ["UAL": 6, "AAL": 9, "DAL": 8, "SWA": 8, "ASA": 6]

    /// How many groups the airline calls, at least the traveller's own.
    public static func groups(airline icao: String?, atLeast position: Int) -> Int {
        let known = icao.flatMap { groupsByAirline[$0.uppercased()] } ?? defaultGroups
        return max(known, position, 1)
    }

    public struct Estimate: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// Boarding has not opened yet.
            case beforeBoarding
            /// Boarding is open; the traveller's group comes later.
            case boarding
            /// The group's estimated call is past.
            case called
        }

        public var group: BoardingGroup
        /// About when the group is called.
        public var calledAt: Date
        /// When boarding opens.
        public var boardingStarts: Date
        /// True when the boarding time comes from the pass, false when it is the usual lead.
        public var fromPass: Bool
        public var groups: Int
        public var phase: Phase
    }

    /// The estimate for the traveller's group on `flight`, nil when there is nothing useful to say: no group
    /// on the pass, no boarding or departure time, a canceled or diverted flight, or the plane already gone
    /// (left the gate, or the departure time is past).
    public static func estimate(_ flight: Flight, pass: BoardingPass?, aircraft: AircraftType?,
                                originTimeZone: TimeZone?, now: Date) -> Estimate? {
        guard let pass, let group = BoardingGroup.read(group: pass.group, zone: pass.zone) else { return nil }
        guard flight.status != .canceled, flight.status != .diverted, flight.actualOut == nil,
              ![.departed, .enRoute, .landed, .arrived].contains(flight.status) else { return nil }
        let departure = flight.estimatedOut ?? flight.scheduledOut
        if let departure, now >= departure { return nil }
        let wide = aircraft?.family.isWidebody == true
        let lead = wide ? LeaveTimePlanner.boardingLeadWideBody : LeaveTimePlanner.boardingLeadNarrowBody

        let passStart = pass.boardingTime
            ?? departure.flatMap { passClock(pass.boardingText, before: $0, timeZone: originTimeZone) }
        guard let start = passStart ?? departure?.addingTimeInterval(-lead) else { return nil }
        let end = departure ?? start.addingTimeInterval(lead)

        let first = start.addingTimeInterval(preBoarding)
        let last = max(first, end.addingTimeInterval(-lastCallBeforeDeparture))
        let n = groups(airline: flight.operator ?? pass.carrierICAO, atLeast: group.position)
        let at: Date
        if group.position <= 0 {
            at = start
        } else if n <= 1 {
            at = first
        } else {
            let step = last.timeIntervalSince(first) / Double(n - 1)
            at = first.addingTimeInterval(step * Double(group.position - 1))
        }
        let phase: Estimate.Phase = now < start ? .beforeBoarding : now < at ? .boarding : .called
        return Estimate(group: group, calledAt: at, boardingStarts: start, fromPass: passStart != nil, groups: n,
                        phase: phase)
    }

    /// A pass that prints only a time of day ("10:30", "1030") as the moment it names in the three hours
    /// before `departure`, at the origin. nil for anything else.
    static func passClock(_ text: String?, before departure: Date, timeZone: TimeZone?) -> Date? {
        guard let text, let tz = timeZone else { return nil }
        let digits = text.filter(\.isNumber)
        guard digits.count == 3 || digits.count == 4, text.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." || $0 == "h" || $0 == " " }),
              let value = Int(digits) else { return nil }
        let hour = value / 100, minute = value % 100
        guard hour < 24, minute < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: departure),
                  let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            let gap = departure.timeIntervalSince(t)
            if gap >= 0, gap <= 3 * 3600 { return t }
        }
        return nil
    }
}

private extension BoardingPass {
    /// The ICAO code of the pass's IATA carrier, for the group table; nil when the table does not need it.
    var carrierICAO: String? {
        ["UA": "UAL", "AA": "AAL", "DL": "DAL", "WN": "SWA", "AS": "ASA"][carrier.uppercased()]
    }
}
