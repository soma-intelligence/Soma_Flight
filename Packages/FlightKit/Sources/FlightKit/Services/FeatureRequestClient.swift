import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Sends an idea from Settings > Suggest a Feature to the Soma Labs `feature-request` function. A public
/// function (no auth header, no account needed): the idea, an optional email for a reply, and the app's
/// version, OS, device model and locale so the idea can be read in context. Nothing else.
public struct FeatureRequestClient: Sendable {
    /// One POST and its answer; `URLSession.shared` in the app, a fake in tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://uchdtnhkkclhvnnqclht.supabase.co/functions/v1/feature-request")!
    /// The backend's name for this app.
    public static let appID = "soma_flight"
    /// The message's bounds once trimmed, the server's own.
    public static let minLength = 3
    public static let maxLength = 4000
    static let maxEmail = 320

    /// The body of the POST, with the server's field names; nil fields are left out.
    public struct Payload: Encodable, Equatable, Sendable {
        var app: String
        var platform: String
        var message: String
        var email: String?
        var installID: String?
        var appVersion: String?
        var osVersion: String?
        var deviceModel: String?
        var locale: String?

        enum CodingKeys: String, CodingKey {
            case app, platform, message, email, locale
            case installID = "install_id"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
        }
    }

    /// Where the idea comes from, read once on the main actor.
    public struct Context: Equatable, Sendable {
        var platform: String
        var installID: String?
        var appVersion: String?
        var osVersion: String?
        var deviceModel: String?
        var locale: String?
    }

    /// Why an idea was not sent.
    public enum Failure: Error, Equatable, Sendable {
        case messageTooShort, messageTooLong, invalidEmail, rateLimited
        /// Offline or the request never got an answer.
        case network
        /// A 500, or an answer the app does not know.
        case server

        /// What the sheet says under the fields (a catalog key).
        public var message: String {
            switch self {
            case .messageTooShort: "Write at least 3 characters."
            case .messageTooLong: "Your idea is over 4,000 characters. Shorten it a little."
            case .invalidEmail: "That email address doesn't look right."
            case .rateLimited: "Too many ideas in a short time. Try again in an hour."
            case .network: "No connection. Try again when you are back online."
            case .server: "Your idea didn't go through. Try again in a moment."
            }
        }
    }

    let endpoint: URL
    let transport: Transport

    public init(endpoint: URL = FeatureRequestClient.endpoint,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// The trimmed idea, the count the Send button and the server check.
    public static func trimmed(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the idea has at least 3 characters other than spaces and stays within 4000.
    public static func canSend(_ message: String) -> Bool {
        (minLength...maxLength).contains(trimmed(message).count)
    }

    /// A light check of the shape the server accepts: one @, a dot in the domain, no spaces.
    static func looksLikeEmail(_ email: String) -> Bool {
        guard email.count <= maxEmail, !email.contains(where: \.isWhitespace) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex
    }

    /// Checks the idea and the email as the server would, then builds the body.
    static func payload(message: String, email: String, context: Context) -> Result<Payload, Failure> {
        let text = trimmed(message)
        if text.count < minLength { return .failure(.messageTooShort) }
        if text.count > maxLength { return .failure(.messageTooLong) }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mail.isEmpty, !looksLikeEmail(mail) { return .failure(.invalidEmail) }
        return .success(Payload(app: appID, platform: context.platform, message: text, email: mail.isEmpty ? nil : mail,
                                installID: context.installID, appVersion: clip(context.appVersion, 40),
                                osVersion: clip(context.osVersion, 40), deviceModel: clip(context.deviceModel, 60),
                                locale: clip(context.locale, 20)))
    }

    /// The POST for `payload`.
    func request(_ payload: Payload) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(payload)
        return request
    }

    /// The server's answer: the new row's id on a 201, else why it refused.
    static func parse(status: Int, body: Data) -> Result<Int, Failure> {
        struct Created: Decodable { var id: Int }
        struct Refused: Decodable { var error: String }
        switch status {
        case 201:
            guard let created = try? JSONDecoder().decode(Created.self, from: body) else { return .failure(.server) }
            return .success(created.id)
        case 429:
            return .failure(.rateLimited)
        case 400:
            switch (try? JSONDecoder().decode(Refused.self, from: body))?.error {
            case "message_too_short": return .failure(.messageTooShort)
            case "message_too_long": return .failure(.messageTooLong)
            case "invalid_email": return .failure(.invalidEmail)
            case "rate_limited": return .failure(.rateLimited)
            default: return .failure(.server)
            }
        default:
            return .failure(.server)
        }
    }

    /// Sends the idea; the new row's id once stored.
    public func send(message: String, email: String, context: Context) async -> Result<Int, Failure> {
        let payload: Payload
        switch Self.payload(message: message, email: email, context: context) {
        case .success(let p): payload = p
        case .failure(let f): return .failure(f)
        }
        do {
            let (data, response) = try await transport(try request(payload))
            guard let http = response as? HTTPURLResponse else { return .failure(.server) }
            return Self.parse(status: http.statusCode, body: data)
        } catch {
            return .failure(.network)
        }
    }

    private static func clip(_ s: String?, _ max: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return String(s.prefix(max))
    }
}

// MARK: - Context

public extension FeatureRequestClient.Context {
    /// Where the random install id is kept; made once, never tied to the account.
    static let installIDKey = "featureRequest.installID"

    /// This device, this build and this app's install id.
    @MainActor static func current(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Self {
        let info = bundle.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let version = short.map { v in build.map { "\(v) (\($0))" } ?? v }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(platform: platform, installID: installID(defaults), appVersion: version,
                    osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                    deviceModel: deviceModel, locale: Locale.current.identifier)
    }

    /// The random install id, made the first time an idea is sent.
    static func installID(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: installIDKey), UUID(uuidString: id) != nil { return id.lowercased() }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// The server's platform name for this device.
    @MainActor static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(watchOS)
        "watchos"
        #elseif os(visionOS)
        "visionos"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "macos" }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "ipados"
        case .vision: return "visionos"
        default: return "ios"
        }
        #endif
    }

    /// The hardware id ("iPhone17,1", "Mac16,10"); the simulated model in the Simulator.
    static var deviceModel: String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}
