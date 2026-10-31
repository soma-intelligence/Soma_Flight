import Foundation

/// The account's number for texts, as `sms-verify` returns it. `available` is false while the backend has
/// texts switched off (`SMS_ALERTS_ENABLED`), which is how the app ships: the section then says so.
public struct TextAlertsStatus: Sendable, Equatable, Decodable {
    public var available: Bool
    /// The account's own number (E.164), pending or verified; nil when none is on file.
    public var phone: String?
    /// A code was sent and can still be typed.
    public var pending: Bool
    public var verified: Bool
    /// "Text Me Too": the alerts that change the next step, next to the push.
    public var enabled: Bool
    /// "In-Flight Texts": between boarding and the gate, the alerts that matter on board.
    public var inFlight: Bool
    /// The number replied STOP: nothing goes to it until it is verified again.
    public var optedOut: Bool
    /// The flight's own switch, when the status was asked for a flight: true, false, or nil (the account's).
    public var flightInFlight: Bool?

    public init(available: Bool = false, phone: String? = nil, pending: Bool = false, verified: Bool = false,
                enabled: Bool = false, inFlight: Bool = false, optedOut: Bool = false, flightInFlight: Bool? = nil) {
        self.available = available; self.phone = phone; self.pending = pending; self.verified = verified
        self.enabled = enabled; self.inFlight = inFlight; self.optedOut = optedOut; self.flightInFlight = flightInFlight
    }

    /// Texts can reach the number: verified and not stopped.
    public var reachable: Bool { verified && !optedOut && phone != nil }

    /// Whether texts on board are on for a flight: its own switch, else the account mode.
    public var textsInFlight: Bool { reachable && (flightInFlight ?? inFlight) }
}

/// What `check` said about a typed code.
public enum TextCodeResult: String, Sendable, Equatable, Decodable {
    case ok, wrong, expired, locked, none
}

/// Why a text alerts call did not work, with the server's words when it refused (a number already used,
/// too many codes, a code to verify first). Shown as they come: the backend writes them for people.
public enum TextAlertsError: Error, Sendable, Equatable {
    case offline
    case unavailable
    case refused(String)

    public var message: String {
        switch self {
        case .offline: "No connection. Try again when you are back online."
        case .unavailable: "Texts are not available yet."
        case .refused(let words): words
        }
    }
}

/// Texts from the Soma line (iMessage, else SMS) on top of the push: Settings > Notifications > Text Me Too
/// and the flight sheet's "Text Me Updates In Flight". Live builds use `SupabaseTextAlertsService`
/// (`sms-verify`); `-useFakes` runs use `FakeTextAlertsService`, which sends nothing.
public protocol TextAlertsService: Sendable {
    /// The account's row; with `flight`, that flight's own switch too.
    func status(flight: Flight.ID?) async throws(TextAlertsError) -> TextAlertsStatus
    /// Sends a six digit code to `phone` (any common format; the server reads it as E.164).
    func start(phone: String) async throws(TextAlertsError) -> TextAlertsStatus
    /// Checks a typed code: on `.ok` the number is verified and Text Me Too is on.
    func check(code: String) async throws(TextAlertsError) -> (TextCodeResult, TextAlertsStatus, triesLeft: Int)
    /// The account's switches; nil leaves one as it is.
    func set(enabled: Bool?, inFlight: Bool?) async throws(TextAlertsError) -> TextAlertsStatus
    /// One flight's in-flight switch: true or false overrides the account, nil goes back to it.
    func setFlight(_ flight: Flight.ID, inFlight: Bool?) async throws(TextAlertsError)
    /// Deletes the number from the account.
    func forget() async throws(TextAlertsError) -> TextAlertsStatus
}

/// No texts at all: the default for views and stores built without a service.
public struct UnavailableTextAlertsService: TextAlertsService {
    public init() {}
    public func status(flight: Flight.ID?) async throws(TextAlertsError) -> TextAlertsStatus { TextAlertsStatus() }
    public func start(phone: String) async throws(TextAlertsError) -> TextAlertsStatus { throw .unavailable }
    public func check(code: String) async throws(TextAlertsError) -> (TextCodeResult, TextAlertsStatus, triesLeft: Int) {
        throw .unavailable
    }
    public func set(enabled: Bool?, inFlight: Bool?) async throws(TextAlertsError) -> TextAlertsStatus { throw .unavailable }
    public func setFlight(_ flight: Flight.ID, inFlight: Bool?) async throws(TextAlertsError) { throw .unavailable }
    public func forget() async throws(TextAlertsError) -> TextAlertsStatus { TextAlertsStatus() }
}
