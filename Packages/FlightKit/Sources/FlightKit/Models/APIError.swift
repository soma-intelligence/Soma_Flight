public enum APIError: Error, Equatable, Sendable {
    case providerUnavailable, notFound, rateLimited, planLimit, unauthorized, offline
    /// A search date outside what the provider serves: 10 days back to 2 days ahead.
    case outOfWindow
    case decoding(String)
    /// The flights saved on this device could not be wiped (sign-out, account change).
    case localData

    /// Maps the backend's error `code` strings. Unknown codes become `.providerUnavailable`.
    public init(code: String) {
        switch code {
        case "not_found": self = .notFound
        case "rate_limited": self = .rateLimited
        case "plan_limit": self = .planLimit
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        case "out_of_window": self = .outOfWindow
        case "provider_unavailable": self = .providerUnavailable
        default: self = .providerUnavailable
        }
    }
}
