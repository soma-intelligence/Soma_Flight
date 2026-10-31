import Foundation
import Testing
@testable import FlightKit

/// Live flight sharing: `share-flight` answers decoded (the backend's contract files), the sheet's share model
/// (one link per sheet, Stop Sharing, what the server says), the share item and the fakes. The contract
/// files are read from `supabase/functions/share-flight/contract/` in the repository (written by the
/// backend's tests), so a change on the backend side that the app cannot read fails here.
@MainActor @Suite struct FlightShareTests {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FlightKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FlightKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "supabase/functions/share-flight/contract")

    private func contract(_ name: String) throws -> Data {
        try Data(contentsOf: Self.contract.appending(path: "\(name).json"))
    }

    nonisolated static let now = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!
    nonisolated static let flight = UUID(uuidString: "00000000-0000-0000-0000-000000000084")!

    // MARK: Decoding

    @Test func decodesTheCreatedLink() throws {
        let link = try SupabaseFlightShareService.decodeCreated(try contract("created"))
        #expect(link.url.absoluteString == "https://somalabs.me/f/C0ntractExampleT0kenC0ntractExampleT0kenABC")
        #expect(link.expiresAt == ISO8601DateFormatter().date(from: "2026-11-04T20:55:00Z"))
    }

    @Test func decodesTheStatus() throws {
        #expect(try SupabaseFlightShareService.decodeStatus(try contract("active"))
                == ISO8601DateFormatter().date(from: "2026-11-04T20:55:00Z"))
        #expect(try SupabaseFlightShareService.decodeStatus(try contract("inactive")) == nil)
    }

    @Test func refusesALinkThatIsNotHTTPS() {
        let data = Data(#"{"url":"http://somalabs.me/f/x","expires_at":"2026-11-04T20:55:00.000Z"}"#.utf8)
        #expect(throws: DecodingError.self) { try SupabaseFlightShareService.decodeCreated(data) }
    }

    @Test func sendsTheFlightIdInLowerCase() throws {
        let body = SupabaseFlightShareService.body(UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["flight_id": "abcdef00-0000-0000-0000-000000000001"])
    }

    // MARK: Model

    @Test func makesOneLinkPerSheetAndSaysItIsSharing() async throws {
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        #expect(model.isSharing == false)
        let first = try await model.url()
        let again = try await model.url()
        #expect(first == again)
        #expect(first.absoluteString.hasPrefix("https://somalabs.me/f/"))
        #expect(model.isSharing)
        #expect(await service.links[Self.flight]?.count == 1)
    }

    @Test func concurrentReceiversShareOneRequest() async throws {
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        async let a = model.url()
        async let b = model.url()
        let (x, y) = try await (a, b)
        #expect(x == y)
        #expect(await service.links[Self.flight]?.count == 1)
    }

    @Test func anExpiredLinkIsReplaced() async throws {
        final class Clock: @unchecked Sendable { var now = FlightShareTests.now }
        let clock = Clock()
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { clock.now })
        let first = try await model.url()
        // Past the link's expiry (a day after the fake's clock), the same sheet asks for a new one.
        clock.now = Self.now.addingTimeInterval(25 * 3600)
        let second = try await model.url()
        #expect(second != first)
        #expect(await service.links[Self.flight]?.count == 2)
    }

    @Test func stopSharingForgetsTheLink() async throws {
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        let first = try await model.url()
        await model.stop()
        #expect(model.isSharing == false)
        #expect(await service.links[Self.flight] == nil)
        let next = try await model.url()
        #expect(next != first)
    }

    @Test func aFailedStopKeepsSharingAndSaysWhy() async throws {
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        _ = try await model.url()
        await service.setNextError(.offline)
        await model.stop()
        #expect(model.isSharing)
        #expect(model.error == .offline)
        model.clearError()
        #expect(model.error == nil)
    }

    @Test func refreshReadsTheServer() async throws {
        let service = FakeFlightShareService(now: Self.now)
        _ = try await service.share(Self.flight)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        await model.refresh()
        #expect(model.isSharing)
        let past = FlightShareModel(flight: Self.flight, service: service,
                                    now: { Self.now.addingTimeInterval(48 * 3600) })
        await past.refresh()
        #expect(past.isSharing == false)
    }

    @Test func aFailedShareThrowsAndSharesNothing() async {
        let service = FakeFlightShareService(now: Self.now)
        await service.setNextError(.outOfWindow)
        let model = FlightShareModel(flight: Self.flight, service: service, now: { Self.now })
        await #expect(throws: APIError.outOfWindow) { try await model.url() }
        #expect(model.isSharing == false)
    }

    @Test func theUnavailableServiceMakesNoLink() async {
        let model = FlightShareModel(flight: Self.flight, service: UnavailableFlightShareService())
        await model.refresh()
        #expect(model.isSharing == false)
        await #expect(throws: APIError.providerUnavailable) { try await model.url() }
    }

    // MARK: Share item

    @Test func theItemCarriesTheTitleTextAndLink() async throws {
        let f = PreviewData.followed[0]
        let service = FakeFlightShareService(now: Self.now)
        let model = FlightShareModel(flight: f.id, service: service, now: { Self.now })
        let item = FlightSharing.item(f, origin: nil, destination: nil, clock: .h24, model: model)
        #expect(item.title.hasPrefix(Format.ident(f.ident) + " · "))
        #expect(item.text == DetailFacts.shareText(f, origin: nil, destination: nil, clock: .h24))
        let url = try #require(try await item.link?())
        #expect(url.host() == "somalabs.me")
        let textOnly = FlightSharing.item(f, origin: nil, destination: nil, clock: .h24, model: nil)
        #expect(textOnly.link == nil)
    }

    @Test func theFakeEnvironmentSharesLiveLinks() async throws {
        let env = try await AppEnvironment.fake(now: Self.now)
        #expect(env.sharing is FakeFlightShareService)
    }
}
