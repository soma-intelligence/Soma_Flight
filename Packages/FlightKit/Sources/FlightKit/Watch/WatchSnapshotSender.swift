import CoreGraphics
import Foundation

public extension WatchSnapshot {
    /// The watch's snapshot of My Flights at `now`: the widget snapshot of `flights`, with the baggage
    /// belt, the seat and the boarding pass of each flight that has them.
    static func from(_ flights: [Flight], passes: [Flight.ID: BoardingPass], lookup: (String) -> Airport?,
                     twelveHour: Bool, now: Date = .now) -> Self {
        let widgets = WidgetSnapshot.from(flights, lookup: lookup, now: now)
        let byID = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let extras = widgets.flights.compactMap { f -> WatchFlightExtras? in
            guard let flight = byID[f.id] else { return nil }
            let pass = passes[f.id]
            return WatchFlightExtras(id: f.id, baggageBelt: flight.baggageBelt, seat: pass?.seat,
                                     pass: pass.flatMap(WatchPass.init(pass:)))
        }
        return Self(flights: widgets, extras: extras, twelveHour: twelveHour)
    }
}

public extension WatchPass {
    /// The pass's barcode as the watch shows it, its modules drawn here with Core Image (the watch has
    /// none). Nil when the pass has no barcode.
    init?(pass: BoardingPass) {
        guard let barcode = pass.barcode else { return nil }
        self.init(format: barcode.format.rawValue, message: barcode.message, altText: barcode.altText,
                  passenger: pass.passenger, boardingGroup: pass.group ?? pass.zone,
                  modules: PassBarcodeImage.modules(barcode))
    }
}

public extension PassBarcodeImage {
    /// The barcode as a grid of modules, one pixel of Core Image's output each (`make` at scale 1); nil
    /// when the generator refuses the message.
    static func modules(_ barcode: PassBarcode) -> BarcodeMatrix? {
        guard let image = make(barcode, scale: 1) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 200_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The bitmap's first row is the image's top row: rows read top down, as the matrix stores them.
        return BarcodeMatrix(width: width, height: height, modules: pixels.map { $0 < 128 })
    }
}

/// Carries an encoded snapshot to the watch. The app's is `PhoneWatchSession` (WatchConnectivity);
/// tests record what was sent.
@MainActor
public protocol WatchTransport: AnyObject {
    /// A watch is paired and has the app: sending is worth it.
    var canSend: Bool { get }
    /// Replaces the application context with `data` (the encoded `WatchSnapshot`).
    func send(_ data: Data) throws
    /// Called when the watch asks for a fresh snapshot.
    var onRequest: (@MainActor () -> Void)? { get set }
}

/// Sends the watch a snapshot of My Flights whenever the app writes the widget snapshot (HomeModel feeds
/// both from the same list change), and again when the watch asks. A send that would change nothing on
/// the watch is skipped.
@MainActor
public final class WatchSnapshotSender {
    private let transport: any WatchTransport
    private let lookup: (String) -> Airport?
    private let twelveHour: () -> Bool
    private let now: () -> Date
    /// The pass kept on this device for a flight; HomeModel points it at the signed-in account's vault.
    public var passes: @MainActor (Flight.ID) async -> BoardingPass? = { _ in nil }
    /// The list last written, to rebuild the snapshot when the watch asks.
    private var lastFlights: [Flight]?
    /// The snapshot last sent; nil before the first send.
    public private(set) var lastSent: WatchSnapshot?
    /// Bumped on every write: a slower earlier build that finishes last is dropped.
    private var generation = 0

    public init(transport: any WatchTransport, lookup: @escaping (String) -> Airport?,
                twelveHour: @escaping () -> Bool = { SharedSettings.twelveHour() }, now: @escaping () -> Date = { .now }) {
        self.transport = transport; self.lookup = lookup; self.twelveHour = twelveHour; self.now = now
        transport.onRequest = { [weak self] in self?.refresh() }
    }

    /// Sends the snapshot of `flights`, passes included, in the background.
    public func write(_ flights: [Flight]) {
        Task { await update(flights) }
    }

    /// Nothing to show: nobody signed in.
    public func clear() {
        generation += 1
        lastFlights = []
        send(.empty(at: now(), twelveHour: twelveHour()))
    }

    /// Builds the snapshot of the last list again: the watch asked, or a boarding pass changed.
    public func refresh() {
        guard let lastFlights else { return }
        lastSent = nil
        write(lastFlights)
    }

    /// Builds and sends the snapshot of `flights`; returns once it is sent (or skipped).
    public func update(_ flights: [Flight]) async {
        generation += 1
        let mine = generation
        lastFlights = flights
        var passes: [Flight.ID: BoardingPass] = [:]
        for f in flights {
            if let pass = await self.passes(f.id) { passes[f.id] = pass }
        }
        guard mine == generation else { return }
        send(.from(flights, passes: passes, lookup: lookup, twelveHour: twelveHour(), now: now()))
    }

    private func send(_ snapshot: WatchSnapshot) {
        if let lastSent, lastSent.sameContent(as: snapshot) { return }
        guard transport.canSend else { return }
        do {
            try transport.send(try snapshot.encoded())
            lastSent = snapshot
        } catch {
            // Not sent: the next change, or the watch's next request, tries again.
            lastSent = nil
        }
    }
}
