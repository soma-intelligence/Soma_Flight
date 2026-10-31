import Foundation
import os

/// What the Apple Watch app and its complications know: the widgets' snapshot of My Flights, plus what
/// only the watch shows (the baggage belt, the seat and the boarding pass barcode) and the clock setting.
///
/// The iPhone sends it over WatchConnectivity (`updateApplicationContext`) whenever it writes the widget
/// snapshot, and again when the watch asks. The watch keeps the last one it received and works from it
/// offline; it never calls the network in v1. Lives here because both the app (FlightKit) and the watch
/// targets link this module.
public struct WatchSnapshot: Codable, Hashable, Sendable {
    /// Bumped when the shape changes in a way an older watch cannot take. A snapshot of another version
    /// reads as nothing, and the watch keeps the one it had.
    public static let currentVersion = 1

    public var version: Int
    /// The flights, as the widgets draw them.
    public var flights: WidgetSnapshot
    /// What the watch adds per flight; a flight with nothing to add has no entry.
    public var extras: [WatchFlightExtras]
    /// The app's clock setting: the watch shows times as the phone does.
    public var twelveHour: Bool

    public init(version: Int = WatchSnapshot.currentVersion, flights: WidgetSnapshot, extras: [WatchFlightExtras] = [],
                twelveHour: Bool = false) {
        self.version = version; self.flights = flights; self.twelveHour = twelveHour
        // Only the flights the snapshot carries: the widget snapshot keeps the first `maxFlights`.
        let ids = Set(flights.flights.map(\.id))
        self.extras = extras.filter { ids.contains($0.id) && !$0.isEmpty }
    }

    /// Nothing followed, or nobody signed in.
    public static func empty(at date: Date = .now, twelveHour: Bool = false) -> Self {
        Self(flights: .empty(at: date), twelveHour: twelveHour)
    }

    /// What the watch shows beside the flight `id`, if anything.
    public func extras(for id: UUID) -> WatchFlightExtras? { extras.first { $0.id == id } }

    /// The same thing on the watch, ignoring when it was written and how far each flight had flown then:
    /// the phone skips a send that would change nothing.
    public func sameContent(as other: Self) -> Bool {
        version == other.version && twelveHour == other.twelveHour && extras == other.extras
            && flights.sameContent(as: other.flights)
    }

    // MARK: Encoding

    /// JSON with ISO 8601 dates (`ISODate`), sorted keys so equal snapshots encode alike. The barcode's
    /// modules travel as base64.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.string(date))
        }
        return try e.encode(self)
    }

    /// Nil for data that is not a snapshot of the current version.
    public static func decode(_ data: Data) -> Self? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
            }
            return date
        }
        guard let snapshot = try? d.decode(Self.self, from: data), snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    // MARK: WatchConnectivity

    /// The key of the encoded snapshot in the application context and in the watch's messages.
    public static let contextKey = "watch.snapshot"
    /// The message the watch sends to ask the phone for a fresh snapshot.
    public static let requestKey = "watch.request"

    /// The application context that carries it: one key, the encoded snapshot. Property list types
    /// only, as WatchConnectivity requires.
    public func applicationContext() throws -> [String: Any] {
        [Self.contextKey: try encoded()]
    }

    /// The snapshot in a received application context or message; nil when there is none or it cannot
    /// be read (another version among them).
    public static func from(applicationContext context: [String: Any]) -> Self? {
        (context[contextKey] as? Data).flatMap(decode)
    }
}

/// What the watch shows for one flight beyond the widgets' fields.
public struct WatchFlightExtras: Codable, Hashable, Sendable, Identifiable {
    /// The flight's id (`WidgetFlight.id`).
    public var id: UUID
    /// The arrival's baggage claim belt ("5").
    public var baggageBelt: String?
    /// "32A", from the boarding pass or the booking details.
    public var seat: String?
    /// The boarding pass the phone keeps for the flight, when there is one.
    public var pass: WatchPass?

    public init(id: UUID, baggageBelt: String? = nil, seat: String? = nil, pass: WatchPass? = nil) {
        self.id = id; self.baggageBelt = baggageBelt?.nilIfBlank; self.seat = seat?.nilIfBlank; self.pass = pass
    }

    /// Nothing to add: the snapshot leaves it out.
    public var isEmpty: Bool { baggageBelt == nil && seat == nil && pass == nil }
}

/// A boarding pass as the watch shows it at the gate: the barcode and the few lines printed around it.
///
/// The phone sends the message and format, and also the barcode already drawn as modules
/// (`BarcodeMatrix`): watchOS has no Core Image, so the watch cannot run the barcode generators itself and
/// only paints the modules.
public struct WatchPass: Codable, Hashable, Sendable {
    /// "pdf417", "aztec", "qr", "code128": FlightKit `PassBarcode.Format`'s raw values.
    public var format: String
    /// The barcode's message, as the pass holds it.
    public var message: String
    /// Text printed under the code, when the pass has some.
    public var altText: String?
    public var passenger: String?
    public var boardingGroup: String?
    /// The barcode's modules; nil when the phone could not draw it (the watch then says so).
    public var modules: BarcodeMatrix?

    public init(format: String, message: String, altText: String? = nil, passenger: String? = nil,
                boardingGroup: String? = nil, modules: BarcodeMatrix? = nil) {
        self.format = format; self.message = message; self.altText = altText; self.passenger = passenger
        self.boardingGroup = boardingGroup; self.modules = modules
    }

    /// A square code (Aztec, QR) rather than a wide one (PDF417, Code 128).
    public var isSquare: Bool { format == "aztec" || format == "qr" }
}

/// A barcode as a grid of dark and light modules, row by row from the top, packed eight to a byte (the
/// first module in the high bit). Small enough to travel in the application context: a boarding pass
/// PDF417 is a few hundred bytes.
public struct BarcodeMatrix: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// `width * height` bits, padded with zeros to a whole byte at the end.
    public var bits: Data

    /// Nil when `modules` does not hold `width * height` values, or the grid is empty.
    public init?(width: Int, height: Int, modules: [Bool]) {
        guard width > 0, height > 0, modules.count == width * height else { return nil }
        var bytes = [UInt8](repeating: 0, count: (modules.count + 7) / 8)
        for (i, dark) in modules.enumerated() where dark { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
        self.width = width; self.height = height; self.bits = Data(bytes)
    }

    /// Whether the module at column `x`, row `y` is dark; false outside the grid.
    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        let i = y * width + x
        guard i / 8 < bits.count else { return false }
        return bits[bits.startIndex + i / 8] & (0x80 >> UInt8(i % 8)) != 0
    }

    /// Checks the bits cover the grid: a decoded matrix with too few bytes would draw half a code.
    public var isValid: Bool { width > 0 && height > 0 && bits.count >= (width * height + 7) / 8 }
}

/// Where the watch keeps the last snapshot the phone sent: a key in the watch's App Group defaults
/// (`SharedSettings.defaults`), which the watch app writes and its complications read.
public enum WatchSnapshotStore {
    public static let key = "watch.snapshot"

    /// The saved snapshot; nil when the phone has never sent one (or it cannot be read).
    public static func load(from defaults: UserDefaults = SharedSettings.defaults) -> WatchSnapshot? {
        defaults.data(forKey: key).flatMap(WatchSnapshot.decode)
    }

    /// False when it could not be encoded (nothing is written then).
    @discardableResult
    public static func save(_ snapshot: WatchSnapshot, to defaults: UserDefaults = SharedSettings.defaults) -> Bool {
        do {
            defaults.set(try snapshot.encoded(), forKey: key)
            return true
        } catch {
            Logger(subsystem: "me.somalabs.flight", category: "watch")
                .error("Watch snapshot not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
