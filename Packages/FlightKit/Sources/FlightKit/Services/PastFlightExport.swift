import Foundation

/// The passport export, the same for every `HistoryService`.
enum PastFlightExport {
    static func data(_ past: [PastFlight], format: ExportFormat) throws(APIError) -> Data {
        switch format {
        case .json:
            do { return try FlightJSON.encoder.encode(past) }
            catch { throw .decoding(String(describing: error)) }
        case .csv:
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            var lines = ["date,ident,origin,destination,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status"]
            for p in past {
                let cols: [String] = [
                    day.string(from: p.date), p.ident, p.originIcao, p.destinationIcao, p.airline ?? "",
                    p.aircraftType ?? "", p.registration ?? "", p.seat ?? "", String(p.distanceKm),
                    p.blockMinutes.map(String.init) ?? "", String(p.delayMinutes), p.status.rawValue,
                ]
                lines.append(cols.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ","))
            }
            return Data(lines.joined(separator: "\n").utf8)
        }
    }
}
