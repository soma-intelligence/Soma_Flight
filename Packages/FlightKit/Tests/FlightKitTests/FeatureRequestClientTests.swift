import Foundation
import Testing
@testable import FlightKit

/// Settings > Suggest a Feature: the request built for the `feature-request` function and the answers read
/// back, against a fake transport (never the production endpoint).
struct FeatureRequestClientTests {
    static let context = FeatureRequestClient.Context(
        platform: "ios", installID: "0f8fad5b-d9cb-469f-a165-70867728950e", appVersion: "1.0 (42)",
        osVersion: "26.1.0", deviceModel: "iPhone18,1", locale: "fr_FR")

    /// Records the request it is handed and answers with `status` and `body`.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        var seen: [URLRequest] { lock.withLock { requests } }

        func transport(status: Int, body: String) -> FeatureRequestClient.Transport {
            { [self] request in
                lock.withLock { requests.append(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
    }

    static let fakeEndpoint = URL(string: "https://example.invalid/functions/v1/feature-request")!

    @Test func buildsThePostTheServerExpects() async throws {
        let recorder = Recorder()
        let client = FeatureRequestClient(endpoint: Self.fakeEndpoint,
                                          transport: recorder.transport(status: 201, body: #"{"id":7}"#))
        let result = await client.send(message: "  Show the seat map  \n", email: " me@example.com ",
                                       context: Self.context)
        #expect(result == .success(7))

        let request = try #require(recorder.seen.first)
        #expect(recorder.seen.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.fakeEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "app": "soma_flight", "platform": "ios", "message": "Show the seat map", "email": "me@example.com",
            "install_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "app_version": "1.0 (42)",
            "os_version": "26.1.0", "device_model": "iPhone18,1", "locale": "fr_FR",
        ])
    }

    @Test func leavesOutAnEmptyEmailAndClipsTheContext() throws {
        var context = Self.context
        context.appVersion = String(repeating: "9", count: 50)
        context.deviceModel = String(repeating: "M", count: 70)
        context.locale = nil
        let payload = try FeatureRequestClient.payload(message: "Dark map", email: "  ", context: context).get()
        #expect(payload.email == nil)
        #expect(payload.locale == nil)
        #expect(payload.appVersion?.count == 40)
        #expect(payload.deviceModel?.count == 60)
        let client = FeatureRequestClient(endpoint: Self.fakeEndpoint)
        let json = try JSONSerialization.jsonObject(with: try client.request(payload).httpBody!) as? [String: String]
        #expect(json?["email"] == nil)
        #expect(json?.keys.contains("locale") == false)
    }

    @Test func checksTheIdeaAndTheEmailBeforeSending() async {
        let recorder = Recorder()
        let client = FeatureRequestClient(endpoint: Self.fakeEndpoint,
                                          transport: recorder.transport(status: 201, body: #"{"id":1}"#))
        #expect(await client.send(message: " a  ", email: "", context: Self.context) == .failure(.messageTooShort))
        let long = String(repeating: "x", count: 4001)
        #expect(await client.send(message: long, email: "", context: Self.context) == .failure(.messageTooLong))
        #expect(await client.send(message: "Good idea", email: "not an email", context: Self.context)
                == .failure(.invalidEmail))
        #expect(await client.send(message: "Good idea", email: "a@b", context: Self.context) == .failure(.invalidEmail))
        #expect(recorder.seen.isEmpty)
    }

    @Test func sendIsEnabledFromThreeCharactersOtherThanSpaces() {
        #expect(!FeatureRequestClient.canSend(""))
        #expect(!FeatureRequestClient.canSend("  ab \n"))
        #expect(FeatureRequestClient.canSend(" abc "))
        #expect(FeatureRequestClient.canSend(String(repeating: "y", count: 4000)))
        #expect(!FeatureRequestClient.canSend(String(repeating: "y", count: 4001)))
    }

    @Test(arguments: [
        (201, #"{"id":12}"#, Result<Int, FeatureRequestClient.Failure>.success(12)),
        (201, "{}", .failure(.server)),
        (400, #"{"error":"message_too_short"}"#, .failure(.messageTooShort)),
        (400, #"{"error":"message_too_long"}"#, .failure(.messageTooLong)),
        (400, #"{"error":"invalid_email"}"#, .failure(.invalidEmail)),
        (400, #"{"error":"invalid_platform"}"#, .failure(.server)),
        (429, #"{"error":"rate_limited"}"#, .failure(.rateLimited)),
        (500, #"{"error":"server_error"}"#, .failure(.server)),
    ])
    func readsTheAnswer(status: Int, body: String, expected: Result<Int, FeatureRequestClient.Failure>) {
        #expect(FeatureRequestClient.parse(status: status, body: Data(body.utf8)) == expected)
    }

    @Test func aRateLimitSaysToWaitAnHour() async {
        let client = FeatureRequestClient(endpoint: Self.fakeEndpoint,
                                          transport: Recorder().transport(status: 429, body: #"{"error":"rate_limited"}"#))
        let result = await client.send(message: "More widgets", email: "", context: Self.context)
        #expect(result == .failure(.rateLimited))
        #expect(FeatureRequestClient.Failure.rateLimited.message == "Too many ideas in a short time. Try again in an hour.")
    }

    @Test func noConnectionIsANetworkFailure() async {
        let client = FeatureRequestClient(endpoint: Self.fakeEndpoint) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await client.send(message: "Offline idea", email: "", context: Self.context) == .failure(.network))
    }

    @Test func theInstallIDIsMadeOnceAndKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "FeatureRequestClientTests.\(UUID().uuidString)"))
        let first = FeatureRequestClient.Context.installID(defaults)
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.lowercased())
        #expect(FeatureRequestClient.Context.installID(defaults) == first)
    }

    @Test @MainActor func everyMessageIsInTheFrenchCatalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Shared/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let failures: [FeatureRequestClient.Failure] = [.messageTooShort, .messageTooLong, .invalidEmail, .rateLimited,
                                                        .network, .server]
        for key in failures.map(\.message) + [SuggestFeatureSheet.title, SuggestFeatureSheet.thanks] {
            #expect(strings[key] != nil, "\(key) has no French")
        }
    }
}
