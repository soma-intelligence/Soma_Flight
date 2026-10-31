import Foundation

public enum FlightEventKind: String, Codable, Sendable, Hashable {
    case gateChange = "gate_change"
    case delay, departure, arrival, cancel, diversion, position
    /// A change that is none of the others (take-off, a schedule or estimate move, a reinstated
    /// flight). It drives push alerts; the timeline shows no row for it.
    case update

    /// A kind this build does not know decodes as `update`, so a newer backend never breaks the list.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FlightEventKind(rawValue: raw) ?? .update
    }
}

/// A row of `flight_events`: one change the backend observed on a flight.
public struct FlightEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var flightId: UUID
    public var kind: FlightEventKind
    /// The jsonb payload flattened to strings (numbers and booleans are stringified).
    public var payload: [String: String]
    public var receivedAt: Date

    public init(id: UUID = UUID(), flightId: UUID, kind: FlightEventKind, payload: [String: String] = [:], receivedAt: Date) {
        self.id = id; self.flightId = flightId; self.kind = kind; self.payload = payload; self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey { case id, flightId, kind, payload, receivedAt }

    private enum Scalar: Decodable {
        case text(String), number(Double), flag(Bool), null
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .flag(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .text((try? c.decode(String.self)) ?? "") }
        }
        var string: String? {
            switch self {
            case .text(let s): s
            case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
            case .flag(let b): String(b)
            case .null: nil
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        flightId = try c.decode(UUID.self, forKey: .flightId)
        kind = try c.decode(FlightEventKind.self, forKey: .kind)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        let raw = (try? c.decodeIfPresent([String: Scalar].self, forKey: .payload)) ?? nil
        payload = (raw ?? [:]).compactMapValues(\.string)
    }
}
