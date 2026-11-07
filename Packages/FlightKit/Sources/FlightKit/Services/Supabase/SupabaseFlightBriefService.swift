import Foundation
import Supabase

/// The language-model texts from `flight-brief`. The backend answers 503 `llm_unavailable` while the model
/// is switched off, over the spend cap, or when its answer fails the facts check; the app then shows
/// nothing. The `decode…` and `body` functions are the exact path the texts take, so the tests read them.
public final class SupabaseFlightBriefService: FlightBriefService {
    private let backend: SupabaseBackend
    private let enabled: Bool

    /// - Parameter enabled: `isEnabled()` in live builds; false answers nil with no call.
    public init(backend: SupabaseBackend, enabled: Bool = true) { self.backend = backend; self.enabled = enabled }

    public var isAvailable: Bool { enabled }

    /// Reads `LLMEnabled` from Info.plist (`LLM_ENABLED` in the xcconfigs: NO everywhere until the owner
    /// approves the cost). Anything but a yes, a missing key included, is off.
    public static func isEnabled(in bundle: Bundle = .main) -> Bool {
        isEnabled(raw: bundle.object(forInfoDictionaryKey: "LLMEnabled"))
    }

    /// YES, true or 1 (any case, as a string, a boolean or a number) is on; everything else, an
    /// unexpanded `$(LLM_ENABLED)` included, is off.
    static func isEnabled(raw: Any?) -> Bool {
        switch raw {
        case let b as Bool: b
        case let s as String: ["yes", "true", "1"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        case let n as NSNumber: n.boolValue
        default: false
        }
    }

    // MARK: Wire

    struct Request: Encodable {
        var kind: String
        var subject: String
        var facts: [BriefFact]
    }

    public struct Answer: Decodable, Sendable {
        public var kind: String
        public var subject: String
        public var text: String
        public var factsUsed: [String]
        public var generatedAt: Date
        public var cached: Bool
    }

    static func body(_ kind: BriefKind, subject: String, facts: [BriefFact]) throws -> Data {
        try JSONEncoder().encode(Request(kind: kind.rawValue, subject: subject, facts: facts))
    }

    public static func decodeAnswer(_ data: Data) throws -> Answer {
        try FlightJSON.decoder.decode(Answer.self, from: data)
    }

    public static func decode(_ data: Data) throws -> FlightBrief? {
        let a = try decodeAnswer(data)
        guard let kind = BriefKind(rawValue: a.kind), !a.text.isEmpty else { return nil }
        return FlightBrief(kind: kind, text: a.text, factsUsed: a.factsUsed, generatedAt: a.generatedAt)
    }

    // MARK: FlightBriefService

    public func brief(_ kind: BriefKind, subject: String, facts: [BriefFact]) async throws(APIError) -> FlightBrief? {
        guard enabled else { return nil }
        let data: Data
        do { data = try Self.body(kind, subject: subject, facts: facts) } catch { throw .decoding(String(describing: error)) }
        return try await backend.call("flight-brief", method: .post, body: data, decode: Self.decode)
    }
}
