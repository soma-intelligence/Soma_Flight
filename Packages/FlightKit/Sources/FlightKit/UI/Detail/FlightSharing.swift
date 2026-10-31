import CoreTransferable
import SwiftUI

// MARK: - Environment

private struct FlightSharingKey: EnvironmentKey {
    static var defaultValue: any FlightShareService { UnavailableFlightShareService() }
}

public extension EnvironmentValues {
    /// Live flight links for the flight sheet. `FlightScreen` sets the environment's `sharing`; the default
    /// makes none, so previews and Passport flights share the text only.
    var flightSharing: any FlightShareService {
        get { self[FlightSharingKey.self] }
        set { self[FlightSharingKey.self] = newValue }
    }
}

// MARK: - Model

/// One flight's live link, as the sheet's Share and "Stop Sharing" see it. The link is made only when
/// someone picks where to send it (`FlightShareItem`), and kept for the sheet's life so a second share
/// sends the same one. `isSharing` is what the server last said, so "Stop Sharing" shows for a link made on
/// another device too.
@MainActor @Observable
public final class FlightShareModel {
    /// True while the user has a link to this flight that still opens.
    public private(set) var isSharing = false
    /// Why the last Stop Sharing did not work; cleared by the next attempt.
    public private(set) var error: APIError?
    private var link: FlightShareLink?
    private var pending: Task<FlightShareLink, any Error>?
    private let flight: Flight.ID
    private let service: any FlightShareService
    private let clock: @Sendable () -> Date

    public init(flight: Flight.ID, service: any FlightShareService, now: @escaping @Sendable () -> Date = { .now }) {
        self.flight = flight; self.service = service; self.clock = now
    }

    /// Asks the server whether the user shares the flight; a failure keeps what the sheet showed.
    public func refresh() async {
        guard let until = try? await service.activeShare(flight) else {
            if link == nil { isSharing = false }
            return
        }
        isSharing = until > clock()
    }

    /// The live link: the one made earlier in this sheet while it still opens, else a new one. Several
    /// receivers asking at once share one request.
    public func url() async throws -> URL {
        if let link, link.expiresAt > clock() { return link.url }
        if let pending { return try await pending.value.url }
        let service = service, flight = flight
        let task = Task { () async throws -> FlightShareLink in try await service.share(flight) }
        pending = task
        defer { pending = nil }
        let made = try await task.value
        link = made
        isSharing = true
        return made.url
    }

    public func clearError() { error = nil }

    /// Closes every link of the user's to the flight. The next Share makes a new one.
    public func stop() async {
        error = nil
        do {
            try await service.stopSharing(flight)
            link = nil
            isSharing = false
        } catch {
            self.error = error
        }
    }
}

// MARK: - Sheet glue

enum FlightSharing {
    /// The sheet's share item: titled like its header ("AF 84" and the route), the flight in words, and the
    /// live link through `model` (nil shares the words only).
    @MainActor static func item(_ flight: Flight, origin: Airport?, destination: Airport?, clock: TimeStyle,
                                model: FlightShareModel?) -> FlightShareItem {
        let route = ScreenFormat.route(origin?.city ?? flight.originCode, destination?.city ?? flight.destinationCode)
        return FlightShareItem(
            title: "\(Format.ident(flight.ident)) · \(route)",
            text: DetailFacts.shareText(flight, origin: origin, destination: destination, clock: clock),
            link: model.map { m in { @Sendable in try await m.url() } })
    }
}

extension View {
    /// Says when Stop Sharing failed (the link still works), until dismissed.
    func shareErrorAlert(_ model: FlightShareModel?) -> some View {
        alert("Could Not Stop Sharing", isPresented: Binding(
            get: { model?.error != nil },
            set: { if !$0 { model?.clearError() } })) {
            Button("OK", role: .cancel) { model?.clearError() }
        } message: {
            Text("The link still works. \(model?.error?.message ?? "")")
        }
    }
}

// MARK: - Share item

/// What the sheet's Share hands over: the live link when there is one (Messages and Mail show its preview),
/// and the flight in words for receivers that take text. The link is fetched only when a receiver asks.
public struct FlightShareItem: Transferable, Sendable {
    /// The sheet's title in the share sheet ("AF 84 · Paris to San Francisco").
    public var title: String
    /// "AF 84 Paris to San Francisco, departs Tue 3 Nov 10:35 CDG" (`DetailFacts.shareText`).
    public var text: String
    /// Makes or returns the live link; nil shares the text only (Passport flights, no service).
    public var link: (@Sendable () async throws -> URL)?

    public init(title: String, text: String, link: (@Sendable () async throws -> URL)?) {
        self.title = title; self.text = text; self.link = link
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (item: FlightShareItem) async throws -> URL in
            guard let link = item.link else { throw CocoaError(.featureUnsupported) }
            return try await link()
        })
        .exportingCondition { $0.link != nil }
        ProxyRepresentation(exporting: { (item: FlightShareItem) in item.text })
    }
}
