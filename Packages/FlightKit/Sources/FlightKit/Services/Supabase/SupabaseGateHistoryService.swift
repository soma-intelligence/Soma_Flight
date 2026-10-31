import Foundation
import Supabase

/// The gate history from the `gate_history` database function (migration 20261030000020): the gates the
/// backend stored for the flight number on its recent days, and the airline's gates at the airport. Free:
/// the backend fills it from gates it already receives. `decode` is the exact path the answer takes.
public final class SupabaseGateHistoryService: GateHistoryService {
    private let backend: SupabaseBackend

    public init(backend: SupabaseBackend) { self.backend = backend }

    /// The function's arguments, keys as the function names them.
    struct Params: Encodable, Sendable {
        var p_ident: String
        var p_origin: String
        var p_operator: String?
        var p_day: String

        // Encodes p_operator as null when there is none, as the function expects all four.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_ident, forKey: .p_ident)
            try c.encode(p_origin, forKey: .p_origin)
            try c.encode(p_operator, forKey: .p_operator)
            try c.encode(p_day, forKey: .p_day)
        }

        enum CodingKeys: String, CodingKey { case p_ident, p_origin, p_operator, p_day }
    }

    /// `{ "days": [...], "airline": [...] }`; a missing list reads as empty.
    public static func decode(_ data: Data) throws -> GateHistory {
        struct Answer: Decodable {
            var days: [GateHistory.Day]?
            var airline: [GateHistory.Count]?
        }
        let a = try FlightJSON.decoder.decode(Answer.self, from: data)
        return GateHistory(days: a.days ?? [], airline: a.airline ?? [])
    }

    public func gateHistory(ident: String, origin: String, operator: String?, day: String) async throws(APIError) -> GateHistory {
        let params = Params(p_ident: ident, p_origin: origin, p_operator: `operator`, p_day: day)
        let data = try await backend.write { try $0.rpc("gate_history", params: params) }
        do { return try Self.decode(data) } catch { throw SupabaseBackend.map(error) }
    }
}
