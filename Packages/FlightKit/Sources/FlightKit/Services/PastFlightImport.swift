import Foundation

/// Reads a CSV file of past flights into what an import would add, before anything is sent. Pure: the
/// file, the history already stored, the airport and airline lists and the clock go in, a preview comes
/// out. Takes the app's own export (`PastFlight.csv`, so an export imports back) and any CSV with at least
/// a date, a from and a to column, headers matched loosely ("Departure Airport", "Flight #", "Cabin").
public enum PastFlightImport {
    /// The file reads as the app's own export, or as some other CSV.
    public enum Format: Sendable, Hashable { case somaFlight, generic }

    /// A file that cannot be imported at all.
    public enum Failure: Error, Sendable, Hashable {
        case empty
        /// The header row lacks these columns (titles as shown to the user).
        case missingColumns([String])
        case tooManyRows(limit: Int)

        public var message: String {
            switch self {
            case .empty: "This file has no flights in it."
            case .missingColumns(let names):
                "This file needs a column for \(names.joined(separator: ", ")). Name them date, from and to."
            case .tooManyRows(let limit): "This file has more than \(limit.formatted()) flights. Split it and import each part."
            }
        }
    }

    /// Why a row is not added.
    public enum SkipReason: Error, Sendable, Hashable {
        case noDate
        case badDate(String)
        case futureDate
        case noOrigin
        case badOrigin(String)
        case noDestination
        case badDestination(String)
        case sameAirports
        /// The history already has a flight that day on that route.
        case alreadyInHistory
        /// An earlier row of the file is the same flight.
        case repeatedRow(Int)

        public var message: String {
            switch self {
            case .noDate: "No date"
            case .badDate(let s): "Date \u{201C}\(s)\u{201D} not understood"
            case .futureDate: "Date is in the future"
            case .noOrigin: "No departure airport"
            case .badOrigin(let s): "Departure \u{201C}\(s)\u{201D} is not an airport code"
            case .noDestination: "No arrival airport"
            case .badDestination(let s): "Arrival \u{201C}\(s)\u{201D} is not an airport code"
            case .sameAirports: "Departs and arrives at the same airport"
            case .alreadyInHistory: "Already in your history"
            case .repeatedRow(let row): "Same flight as row \(row)"
            }
        }
    }

    /// A row that will be added, with what was left out of it.
    public struct Row: Sendable, Hashable, Identifiable {
        /// The row's number in the file, the header being row 1.
        public var row: Int
        public var flight: PastFlight
        /// Values that were not understood and are left out ("Seat “aisle” left out").
        public var warnings: [String]
        public var id: Int { row }
    }

    /// A row that will not be added.
    public struct Skip: Sendable, Hashable, Identifiable {
        public var row: Int
        public var reason: SkipReason
        public var id: Int { row }
    }

    public struct Preview: Sendable, Hashable {
        public var format: Format
        public var rows: [Row]
        /// Rows that cannot be read as a flight.
        public var skipped: [Skip]
        /// Rows that are flights already in the history, or repeated in the file.
        public var duplicates: [Skip]

        public var flights: [PastFlight] { rows.map(\.flight) }
    }

    public static let maxRows = 5000

    // MARK: Preview

    /// - Parameters:
    ///   - existing: the history as stored; a row on the same day and route is a duplicate.
    ///   - airport: airport by ICAO or IATA (codes become ICAO, days are read in the origin's zone).
    ///   - now: what "in the future" is measured from.
    ///   - makeID: the id of each new flight.
    public static func preview(_ data: Data, existing: [PastFlight], airport: (String) -> Airport?,
                               reference: ReferenceData, now: Date,
                               makeID: () -> UUID = UUID.init) throws(Failure) -> Preview {
        let records = self.records(text(data))
        guard let header = records.first, records.count > 1 else { throw .empty }
        let columns = self.columns(header)
        let missing = [(Field.date, "date"), (.origin, "from"), (.destination, "to")].filter { columns[$0.0] == nil }
        guard missing.isEmpty else { throw .missingColumns(missing.map(\.1)) }
        guard records.count - 1 <= maxRows else { throw .tooManyRows(limit: maxRows) }

        let format: Format = header.map(normalized) == PastFlight.csvHeader.split(separator: ",").map { normalized(String($0)) }
            ? .somaFlight : .generic
        let body = Array(records.dropFirst())
        let dateColumn = columns[.date]!
        let dayFirst = slashDayFirst(body.compactMap { dateColumn < $0.count ? $0[dateColumn] : nil })
        var seen: [String: Int] = [:]
        for f in existing { seen[PastFlightRules.tripKey(f, airport: airport)] = 0 }

        var preview = Preview(format: format, rows: [], skipped: [], duplicates: [])
        for (index, record) in body.enumerated() {
            let row = index + 2
            func cell(_ field: Field) -> String {
                guard let i = columns[field], i < record.count else { return "" }
                return clean(record[i])
            }
            switch flight(cell: cell, dayFirst: dayFirst, airport: airport, reference: reference, now: now, id: makeID()) {
            case .failure(let reason):
                preview.skipped.append(Skip(row: row, reason: reason))
            case .success(let (flight, warnings)):
                let key = PastFlightRules.tripKey(flight, airport: airport)
                if let first = seen[key] {
                    preview.duplicates.append(Skip(row: row, reason: first == 0 ? .alreadyInHistory : .repeatedRow(first)))
                } else {
                    seen[key] = row
                    preview.rows.append(Row(row: row, flight: flight, warnings: warnings))
                }
            }
        }
        return preview
    }

    /// One record as a flight: the required fields or why the row is skipped, then the optional ones,
    /// each left out (with a warning) when it does not read.
    private static func flight(cell: (Field) -> String, dayFirst: Bool, airport: (String) -> Airport?,
                               reference: ReferenceData, now: Date,
                               id: UUID) -> Result<(PastFlight, [String]), SkipReason> {
        let fromText = cell(.origin), toText = cell(.destination), dateText = cell(.date)
        if dateText.isEmpty { return .failure(.noDate) }
        if fromText.isEmpty { return .failure(.noOrigin) }
        if toText.isEmpty { return .failure(.noDestination) }
        guard let from = airportCode(in: fromText, airport: airport) else { return .failure(.badOrigin(fromText)) }
        guard let to = airportCode(in: toText, airport: airport) else { return .failure(.badDestination(toText)) }
        if from == to { return .failure(.sameAirports) }
        let zone = airport(from)?.timeZone ?? .gmt
        guard let date = date(dateText, time: cell(.time), dayFirst: dayFirst, in: zone) else {
            return .failure(.badDate(dateText))
        }
        if !PastFlightRules.allows(date: date, now: now) {
            return .failure(date > now ? .futureDate : .badDate(dateText))
        }

        var warnings: [String] = []
        func optional(_ text: String, _ label: String, _ rule: (String) -> String??) -> String? {
            guard let v = rule(text) else {
                warnings.append("\(label) \u{201C}\(text)\u{201D} left out")
                return nil
            }
            return v
        }
        var f = PastFlight(id: id, date: date, ident: "", originIcao: from, destinationIcao: to, distanceKm: 0,
                           source: .import)
        f.ident = optional(cell(.ident), "Flight number", PastFlightRules.ident) ?? ""
        let airlineText = cell(.airline)
        if let known = reference.airline(airlineText) {
            f.airline = known.id
        } else {
            f.airline = optional(airlineText, "Airline", PastFlightRules.airline)
        }
        if f.airline == nil, !f.ident.isEmpty { f.airline = reference.airline(ident: f.ident)?.id }
        let typeText = cell(.aircraft)
        f.aircraftType = aircraftType(typeText, reference: reference)
            ?? optional(typeText, "Aircraft", PastFlightRules.aircraftType)
        f.registration = optional(cell(.registration), "Registration", PastFlightRules.registration)
        f.seat = optional(cell(.seat), "Seat", FollowDetails.normalizedSeat)
        f.seatClass = optional(cell(.seatClass), "Class") { word($0, in: classWords) }.flatMap(SeatClass.init(rawValue:))
        f.reason = optional(cell(.reason), "Reason") { word($0, in: reasonWords) }.flatMap(TripReason.init(rawValue:))
        f.seatPosition = optional(cell(.seatPosition), "Seat position") { word($0, in: positionWords) }
            .flatMap(SeatPosition.init(rawValue:))
        let notes = cell(.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            f.notes = String(String.UnicodeScalarView(notes.unicodeScalars.prefix(FollowDetails.maxNotes)))
            if notes.unicodeScalars.count > FollowDetails.maxNotes { warnings.append("Notes cut to 2,000 characters") }
        }
        if let km = Int(cell(.distanceKm)), km >= 0 { f.distanceKm = km }
        if let m = Int(cell(.blockMinutes)), m >= 0 { f.blockMinutes = m }
        if let m = Int(cell(.delayMinutes)) { f.delayMinutes = m }
        if let s = PastFlightStatus(rawValue: cell(.status).lowercased()) { f.status = s }
        return .success((f, warnings))
    }

    // MARK: Columns

    enum Field: CaseIterable {
        case date, time, ident, origin, destination, airline, aircraft, registration, seat, seatClass, reason,
             seatPosition, notes, distanceKm, blockMinutes, delayMinutes, status

        /// Header names this field answers to, after `normalized` (lower case letters and digits only).
        var names: [String] {
            switch self {
            case .date: ["date", "flightdate", "departuredate", "depdate", "dateofflight", "day", "localdate",
                         "departuredatelocal", "datelocal"]
            case .time: ["time", "departuretime", "deptime", "departuretimelocal", "localtime"]
            case .ident: ["flight", "flightnumber", "flightno", "flightnum", "flightcode", "ident", "number"]
            case .origin: ["from", "origin", "departureairport", "depairport", "departure", "fromairport",
                           "origincode", "originairport", "dep", "originicao", "originiata", "departureiata",
                           "departureicao", "fromcode"]
            case .destination: ["to", "destination", "arrivalairport", "arrairport", "arrival", "toairport",
                                "destinationcode", "destinationairport", "arr", "dest", "destinationicao",
                                "destinationiata", "arrivaliata", "arrivalicao", "tocode"]
            case .airline: ["airline", "carrier", "operator", "airlinename", "operatingairline", "airlinecode"]
            case .aircraft: ["aircraft", "aircrafttype", "type", "plane", "equipment", "aircraftmodel", "model",
                             "planetype", "aircrafttypecode"]
            case .registration: ["registration", "reg", "tail", "tailnumber", "aircraftregistration"]
            case .seat: ["seat", "seatnumber", "seatno"]
            case .seatClass: ["class", "seatclass", "cabin", "cabinclass", "flightclass", "travelclass"]
            case .reason: ["reason", "flightreason", "purpose", "tripreason", "triptype"]
            case .seatPosition: ["seatposition", "seattype", "seatlocation", "position"]
            case .notes: ["notes", "note", "comment", "comments", "remarks", "memo"]
            case .distanceKm: ["distancekm"]
            case .blockMinutes: ["blockminutes"]
            case .delayMinutes: ["delayminutes"]
            case .status: ["status"]
            }
        }
    }

    /// Which column holds each field: the first header that is one of its names, and for the date, failing
    /// that, the first header with "date" in it.
    static func columns(_ header: [String]) -> [Field: Int] {
        let names = header.map(normalized)
        var out: [Field: Int] = [:]
        for field in Field.allCases {
            if let i = names.indices.first(where: { field.names.contains(names[$0]) && !out.values.contains($0) }) {
                out[field] = i
            }
        }
        if out[.date] == nil, let i = names.firstIndex(where: { $0.contains("date") }) { out[.date] = i }
        return out
    }

    /// Lower case, accents folded, letters and digits only: "Departure Airport" gives "departureairport".
    static func normalized(_ s: String) -> String {
        String(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// A cell trimmed, with the quote our export puts before a text that starts like a formula taken off.
    static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count > 1, t.hasPrefix("'"), let next = t.unicodeScalars.dropFirst().first,
           "=+-@\t\r".unicodeScalars.contains(next) {
            return String(t.dropFirst())
        }
        return t
    }

    // MARK: Values

    /// The airport code a cell names: the code itself ("SFO", "lfpg"), or the codes in its last brackets
    /// ("Paris / Charles de Gaulle (CDG/LFPG)"), or its first word ("SFO San Francisco"). A code the airport
    /// list knows comes back as its ICAO code; an unknown one as written, upper cased. Nil when nothing in
    /// the cell reads as a code.
    static func airportCode(in cell: String, airport: (String) -> Airport?) -> String? {
        var candidates: [String] = []
        if let open = cell.lastIndex(of: "("), let close = cell[open...].firstIndex(of: ")") {
            candidates = cell[cell.index(after: open)..<close]
                .split(whereSeparator: { $0 == "/" || $0 == "," || $0 == " " }).map(String.init)
        } else if let whole = PastFlightRules.airportCode(cell) {
            candidates = [whole]
        } else if let first = cell.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first {
            candidates = [String(first)]
        }
        let codes = candidates.compactMap(PastFlightRules.airportCode)
        if let known = codes.lazy.compactMap(airport).first { return known.id }
        return codes.first(where: { $0.count == 4 }) ?? codes.first
    }

    /// An aircraft type the reference list knows, by designator or by name ("Boeing 737-800",
    /// "737-800"), as its designator.
    static func aircraftType(_ text: String, reference: ReferenceData) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let known = reference.type(t) { return known.id }
        let key = normalized(t)
        // The list's names carry the maker ("Boeing 777-300ER"); a file may leave it out.
        return reference.types.first {
            let name = normalized($0.name)
            return name == key || name == normalized($0.manufacturer) + key
        }?.id
    }

    static let classWords: [String: String] = [
        "economy": "economy", "eco": "economy", "coach": "economy", "y": "economy", "standard": "economy",
        "premiumeconomy": "premium_economy", "premium": "premium_economy", "economyplus": "premium_economy",
        "w": "premium_economy", "business": "business", "businessclass": "business", "j": "business",
        "c": "business", "first": "first", "firstclass": "first", "f": "first", "private": "private",
    ]
    static let reasonWords: [String: String] = [
        "personal": "personal", "leisure": "personal", "holiday": "personal", "vacation": "personal",
        "business": "business", "work": "business", "crew": "crew",
    ]
    static let positionWords: [String: String] = [
        "aisle": "aisle", "middle": "middle", "window": "window", "pilot": "pilot", "captain": "captain",
        "jumpseat": "jumpseat",
    ]

    /// The raw value a word stands for. `.some(nil)` for an empty cell, nil for a word not in `words`.
    private static func word(_ s: String, in words: [String: String]) -> String?? {
        let key = normalized(s)
        if key.isEmpty { return .some(nil) }
        return words[key].map { .some($0) } ?? nil
    }

    /// A date cell (and an optional time cell) as an instant. Takes ISO 8601 with a zone
    /// ("2025-03-14T06:05:00Z", our export), a day as year first ("2025-03-14", "2025/03/14") or year last
    /// ("14.03.2025", "14-03-2025" day first; "03/14/2025" as `dayFirst` says), each with an optional
    /// "HH:mm" after it. A day without a zone is read in `zone` (the origin's), at noon without a time.
    static func date(_ text: String, time: String, dayFirst: Bool, in zone: TimeZone) -> Date? {
        if text.contains("T") || text.hasSuffix("Z"), let instant = FlightJSON.parse(text) { return instant }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
        guard let dayText = parts.first else { return nil }
        let clock = parts.count > 1 ? parts[1] : time
        let numbers = dayText.split(whereSeparator: { "-/.".contains($0) }).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        let n = numbers.compactMap { Int($0) }
        let (y, m, d): (Int, Int, Int)
        if numbers[0].count == 4 {
            (y, m, d) = (n[0], n[1], n[2])
        } else if numbers[2].count == 4 {
            let slash = dayText.contains("/")
            (y, m, d) = slash && !dayFirst ? (n[2], n[0], n[1]) : (n[2], n[1], n[0])
        } else {
            return nil
        }
        let hm = clock.split(separator: ":").prefix(2).compactMap { Int($0) }
        if hm.count == 2 { return PastFlightRules.at(year: y, month: m, day: d, hour: hm[0], minute: hm[1], in: zone) }
        guard clock.isEmpty else { return nil }
        return PastFlightRules.noon(year: y, month: m, day: d, in: zone)
    }

    /// Whether the file's "a/b/yyyy" dates are day first: yes once one has a first number above 12, no once
    /// one has a second number above 12, month first (the US order) when every date fits both.
    static func slashDayFirst(_ cells: [String]) -> Bool {
        for cell in cells {
            let n = cell.split(separator: " ").first?.split(separator: "/").compactMap { Int($0) } ?? []
            guard n.count == 3 else { continue }
            if n[0] > 12 { return true }
            if n[1] > 12 { return false }
        }
        return false
    }

    // MARK: CSV

    /// The file as text: UTF-8 (a byte order mark dropped), else Windows Latin 1, which every byte decodes as.
    static func text(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: PastFlight.csvBOM) { bytes = bytes.dropFirst(PastFlight.csvBOM.count) }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 4180 records: fields split on the file's delimiter (comma, semicolon or tab, whichever the first
    /// line has most of), double-quoted fields with doubled quotes, CRLF, LF or CR between records. Blank
    /// records are dropped.
    static func records(_ text: String) -> [[String]] {
        let firstLine = text.unicodeScalars.prefix { $0 != "\n" && $0 != "\r" }
        // A comma unless the first line has strictly more semicolons or tabs.
        var delimiter: Unicode.Scalar = ","
        var most = firstLine.filter { $0 == "," }.count
        for other: Unicode.Scalar in [";", "\t"] {
            let n = firstLine.filter { $0 == other }.count
            if n > most { delimiter = other; most = n }
        }
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var fieldStarted = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }
        func endRecord() {
            endField()
            if record.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { records.append(record) }
            record = []
        }

        while let c = pending ?? scalars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    let next = scalars.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && !fieldStarted {
                quoted = true
                fieldStarted = true
            } else if c == delimiter {
                endField()
            } else if c == "\r" || c == "\n" {
                if c == "\r" {
                    let next = scalars.next()
                    if next != "\n" { pending = next }
                }
                endRecord()
            } else {
                field.append(c)
                fieldStarted = true
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
