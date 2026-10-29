import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The passport export, the same for every `HistoryService`. Built on the device from `PastFlight`
/// values: nothing is sent anywhere until the user picks a destination in the share sheet.
enum PastFlightExport {
    static func data(_ past: [PastFlight], format: ExportFormat) throws(APIError) -> Data {
        switch format {
        case .json:
            do {
                var data = try encoder.encode(past)
                data.append(0x0A)
                return data
            } catch { throw .decoding(String(describing: error)) }
        case .csv:
            return PastFlight.csv(past)
        }
    }

    /// Whole-second ISO 8601 in UTC ("2025-03-14T06:05:00Z"). ISO8601DateFormatter is thread-safe for
    /// string(from:) and defaults to GMT.
    nonisolated(unsafe) static let utc: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// snake_case keys like the backend, readable and stable (pretty printed, sorted keys).
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(utc.string(from: date))
        }
        return e
    }
}

extension PastFlight {
    /// The CSV header, one column per field.
    static let csvHeader = "date,flight,from,to,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status"

    /// RFC 4180 CSV: CRLF between records, a field holding a comma, a double quote, CR or LF is wrapped in
    /// double quotes with its quotes doubled. Dates are ISO 8601 in UTC; a missing value is an empty field.
    public static func csv(_ past: [PastFlight]) -> Data {
        var records = [csvHeader]
        for p in past {
            let fields: [String] = [
                PastFlightExport.utc.string(from: p.date), p.ident, p.originIcao, p.destinationIcao, p.airline ?? "",
                p.aircraftType ?? "", p.registration ?? "", p.seat ?? "", String(p.distanceKm),
                p.blockMinutes.map(String.init) ?? "", String(p.delayMinutes), p.status.rawValue,
            ]
            records.append(fields.map(csvField).joined(separator: ","))
        }
        return Data(records.joined(separator: "\r\n").utf8)
    }

    static func csvField(_ s: String) -> String {
        // unicodeScalars: "\r\n" is one Character, so a Character test would miss it.
        let needsQuotes = s.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// One history export for `ShareLink`: the file is built when the share sheet asks for it, from the
/// history as it is then, and named `soma-flight-history-YYYY-MM-DD.csv` (or `.json`) after the local day.
public struct HistoryExport: Transferable, Sendable {
    public var format: ExportFormat
    var history: any HistoryService

    public init(format: ExportFormat, history: any HistoryService) {
        self.format = format; self.history = history
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { try SentTransferredFile(await $0.writeFile()) }
            .exportingCondition { $0.format == .csv }
        FileRepresentation(exportedContentType: .json) { try SentTransferredFile(await $0.writeFile()) }
            .exportingCondition { $0.format == .json }
    }

    /// The name of the file for `format` exported on `date`'s local day.
    public static func fileName(for format: ExportFormat, on date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "soma-flight-history-\(day).\(format == .csv ? "csv" : "json")"
    }

    /// Writes the export into its own temporary folder and returns the file. Throws the service's error.
    func writeFile() async throws(APIError) -> URL {
        let data = try await history.export(format)
        let dir = FileManager.default.temporaryDirectory.appending(path: "HistoryExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = dir.appending(path: Self.fileName(for: format, on: .now))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw .localData }
        return url
    }
}
