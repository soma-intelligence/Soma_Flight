import Foundation

/// Shared JSON configuration for backend payloads: snake_case keys and
/// ISO 8601 dates, with or without fractional seconds.
public enum FlightJSON {
    // ISO8601DateFormatter is thread-safe for date(from:)/string(from:).
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad ISO 8601 date: \(s)")
        }
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractional.string(from: date))
        }
        return e
    }
}
