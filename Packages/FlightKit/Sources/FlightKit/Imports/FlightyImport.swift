import Foundation
import FlightImportKit

/// Reads the CSV file another flight tracker (Flighty) exports from its settings ("Export Flights"),
/// one flight per row. Pure. The columns, as that export writes them (see the imports report for the
/// sources):
///
///     Date, Airline, Flight, From, To, Dep Terminal, Dep Gate, Arr Terminal, Arr Gate, Canceled,
///     Diverted To, Gate Departure (Scheduled), Gate Departure (Actual), Take off (Scheduled),
///     Take off (Actual), Landing (Scheduled), Landing (Actual), Gate Arrival (Scheduled),
///     Gate Arrival (Actual), Aircraft Type Name, Tail Number, PNR, Seat, Seat Type, Cabin Class,
///     Flight Reason, Notes, then six "... Flighty ID" columns
///
/// `Date` is the local departure day (`YYYY-MM-DD`), `Airline` the operator's ICAO code, `Flight` the
/// number alone, `From` and `To` IATA codes; times are local wall clock at their airport with no zone
/// (`YYYY-MM-DDTHH:MM`); `Canceled` is `true` or `false`; `Cabin Class`, `Seat Type` and `Flight Reason`
/// are upper-case words (`ECONOMY`, `WINDOW`, `LEISURE`). Columns are found by name, in any order, and
/// only the first five are required.
public enum FlightyImport {
    public enum Failure: Error, Sendable, Hashable {
        case empty
        /// The header lacks these columns: not a file from that export.
        case missingColumns([String])
        case tooManyRows(limit: Int)

        public var message: String {
            switch self {
            case .empty: "This file has no flights in it."
            case .missingColumns(let names):
                "This doesn't look like a flight export: it has no \(names.joined(separator: ", ")) column. Export your flights again and pick the CSV file."
            case .tooManyRows(let limit): "This file has more than \(limit.formatted()) flights. Split it and import each part."
            }
        }
    }

    /// One row read: its number in the file (the header is row 1) and the flight, or why it is skipped.
    public struct Row: Sendable, Hashable {
        public var row: Int
        public var flight: Result<ImportedFlight, Skip>
    }

    public enum Skip: Error, Sendable, Hashable {
        case noDate, badDate(String), noOrigin, noDestination

        public var message: String {
            switch self {
            case .noDate: "No date"
            case .badDate(let s): "Date \u{201C}\(s)\u{201D} not understood"
            case .noOrigin: "No departure airport"
            case .noDestination: "No arrival airport"
            }
        }
    }

    enum Column: String, CaseIterable {
        case date = "Date", airline = "Airline", flight = "Flight", from = "From", to = "To"
        case canceled = "Canceled", divertedTo = "Diverted To"
        case gateOutScheduled = "Gate Departure (Scheduled)", gateOutActual = "Gate Departure (Actual)"
        case offScheduled = "Take off (Scheduled)", offActual = "Take off (Actual)"
        case gateInScheduled = "Gate Arrival (Scheduled)", gateInActual = "Gate Arrival (Actual)"
        case onScheduled = "Landing (Scheduled)", onActual = "Landing (Actual)"
        case aircraft = "Aircraft Type Name", tail = "Tail Number", pnr = "PNR", seat = "Seat", seatType = "Seat Type"
        case cabin = "Cabin Class", reason = "Flight Reason", notes = "Notes"

        static let required: [Column] = [.date, .airline, .flight, .from, .to]
    }

    public static let maxRows = PastFlightImport.maxRows

    /// True when the header row is this export's: its five first columns as it names and orders them, or
    /// one of its own id columns ("Flight Flighty ID"). Our own export has the same names in another order.
    public static func recognizes(_ data: Data) -> Bool {
        guard let header = PastFlightImport.records(PastFlightImport.text(data)).first else { return false }
        let raw = header.map { $0.trimmingCharacters(in: .whitespaces) }
        return Array(raw.prefix(5)) == Column.required.map(\.rawValue) || raw.contains { $0.hasSuffix("Flighty ID") }
    }

    /// Every row of the file, read.
    public static func read(_ data: Data) throws(Failure) -> [Row] {
        let records = PastFlightImport.records(PastFlightImport.text(data))
        guard let header = records.first, records.count > 1 else { throw .empty }
        let columns = self.columns(header)
        let lacking = missing(columns)
        guard lacking.isEmpty else { throw .missingColumns(lacking.map(\.rawValue)) }
        guard records.count - 1 <= maxRows else { throw .tooManyRows(limit: maxRows) }
        return records.dropFirst().enumerated().map { index, record in
            func cell(_ c: Column) -> String {
                guard let i = columns[c], i < record.count else { return "" }
                return PastFlightImport.clean(record[i])
            }
            return Row(row: index + 2, flight: flight(cell))
        }
    }

    static func columns(_ header: [String]) -> [Column: Int] {
        let names = header.map(PastFlightImport.normalized)
        var out: [Column: Int] = [:]
        for c in Column.allCases {
            if let i = names.firstIndex(of: PastFlightImport.normalized(c.rawValue)) { out[c] = i }
        }
        return out
    }

    private static func missing(_ columns: [Column: Int]) -> [Column] {
        Column.required.filter { columns[$0] == nil }
    }

    private static func flight(_ cell: (Column) -> String) -> Result<ImportedFlight, Skip> {
        let dateText = cell(.date)
        if dateText.isEmpty { return .failure(.noDate) }
        guard let day = Self.day(dateText) else { return .failure(.badDate(dateText)) }
        let from = cell(.from), to = cell(.to)
        if from.isEmpty { return .failure(.noOrigin) }
        if to.isEmpty { return .failure(.noDestination) }

        var f = ImportedFlight(day: day)
        f.airline = nonEmpty(cell(.airline))
        f.number = nonEmpty(cell(.flight))
        f.origin = from.uppercased()
        f.destination = to.uppercased()
        // The best known gate times, actual first; a departure stamp on another day than `Date` (a delay
        // past midnight) gives way to the next one.
        let outs = [Column.gateOutActual, .gateOutScheduled, .offActual, .offScheduled].compactMap { stamp(cell($0)) }
        f.departureTime = outs.first { $0.day == day }?.time
        if let arrival = stamp(cell(.gateInActual)) ?? stamp(cell(.gateInScheduled)) ?? stamp(cell(.onActual))
            ?? stamp(cell(.onScheduled)) {
            f.arrivalDay = arrival.day
            f.arrivalTime = arrival.time
        }
        // Both stamps are the destination's wall clock, so their difference needs no zone.
        if let scheduled = stamp(cell(.gateInScheduled)), let actual = stamp(cell(.gateInActual)),
           let minutes = minutes(from: scheduled, to: actual) {
            f.delayMinutes = minutes
        }
        f.aircraft = nonEmpty(cell(.aircraft))
        f.registration = nonEmpty(cell(.tail))
        f.bookingReference = nonEmpty(cell(.pnr))
        f.seat = nonEmpty(cell(.seat))
        f.seatPosition = nonEmpty(cell(.seatType))
        f.cabin = nonEmpty(cell(.cabin))
        f.reason = nonEmpty(cell(.reason))
        f.notes = nonEmpty(cell(.notes))
        f.canceled = ["true", "yes", "1", "y"].contains(cell(.canceled).lowercased())
        f.divertedTo = nonEmpty(cell(.divertedTo))?.uppercased()
        return .success(f)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `YYYY-MM-DD`, the export's day.
    static func day(_ s: String) -> LocalDay? {
        guard let m = s.wholeMatch(of: /([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})/) else { return nil }
        let d = LocalDay(year: Int(m.1)!, month: Int(m.2)!, day: Int(m.3)!)
        return d.isValid ? d : nil
    }

    /// `YYYY-MM-DDTHH:MM` (seconds allowed), a wall clock with no zone.
    static func stamp(_ s: String) -> (day: LocalDay, time: LocalTime)? {
        guard let m = s.firstMatch(of: /^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2})/) else { return nil }
        let d = LocalDay(year: Int(m.1)!, month: Int(m.2)!, day: Int(m.3)!)
        guard d.isValid, let t = LocalTime(hour: Int(m.4)!, minute: Int(m.5)!) else { return nil }
        return (d, t)
    }

    static func minutes(from a: (day: LocalDay, time: LocalTime), to b: (day: LocalDay, time: LocalTime)) -> Int? {
        let m = a.day.days(to: b.day) * 1440 + (b.time.hour * 60 + b.time.minute) - (a.time.hour * 60 + a.time.minute)
        return abs(m) <= 48 * 60 ? m : nil
    }
}
