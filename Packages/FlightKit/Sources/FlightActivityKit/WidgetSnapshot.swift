import Foundation
import os

/// What the home screen and lock screen widgets know: the next followed flights, as the app last saw
/// them. The app writes it to the App Group whenever My Flights changes; the widget extension only reads
/// it and never calls the network. Lives here, beside the Live Activity, because the extension links this
/// module and not FlightKit.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    /// Bumped when the shape changes in a way an older reader cannot take. A snapshot of another version
    /// reads as empty until the app writes a new one.
    public static let currentVersion = 1
    /// How many flights the app keeps: the large widget shows four, the rest cover the ones that drop
    /// off (landed an hour ago) before the next write.
    public static let maxFlights = 8

    public var version: Int
    /// When the app wrote it.
    public var generatedAt: Date
    /// In the air first, then by departure: the order of My Flights.
    public var flights: [WidgetFlight]

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date, flights: [WidgetFlight]) {
        self.version = version; self.generatedAt = generatedAt
        self.flights = Array(flights.prefix(Self.maxFlights))
    }

    /// Nothing followed (or signed out).
    public static func empty(at date: Date = .now) -> Self { Self(generatedAt: date, flights: []) }

    /// The flights still worth showing at `date`, in the order the widgets list them: one in the air
    /// first, then by best departure. A flight leaves the list an hour after its best arrival (or, with no
    /// arrival time, an hour after its departure), whatever status the snapshot last saw: the app may not
    /// have run since it landed.
    public func flights(at date: Date) -> [WidgetFlight] {
        flights
            .filter { f in f.droppedAt.map { date < $0 } ?? true }
            .sorted { a, b in
                let x = a.isAirborne, y = b.isAirborne
                if x != y { return x }
                let p = a.bestOut ?? a.scheduledOut ?? .distantFuture, q = b.bestOut ?? b.scheduledOut ?? .distantFuture
                return p == q ? a.id.uuidString < b.id.uuidString : p < q
            }
    }

    /// The same flights to show, ignoring when it was written and how far each flight had flown then
    /// (the widgets work progress out from the times). The app skips a write, and the timeline reload
    /// that goes with it, when nothing else changed.
    public func sameContent(as other: Self) -> Bool {
        func strip(_ s: Self) -> [WidgetFlight] { s.flights.map { var f = $0; f.progress = 0; return f } }
        return version == other.version && strip(self) == strip(other)
    }

    // MARK: Encoding

    /// JSON with ISO 8601 dates (`ISODate`, milliseconds kept), sorted keys so equal snapshots encode
    /// alike.
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
}

/// One end of a flight in the snapshot.
public struct WidgetAirport: Codable, Hashable, Sendable {
    /// IATA, else ICAO.
    public var code: String
    /// "Paris"; nil when the airport is not in the app's list (the widgets then show the code).
    public var city: String?
    /// IANA identifier; nil shows the device's zone.
    public var timeZone: String?

    public init(code: String, city: String? = nil, timeZone: String? = nil) {
        self.code = code; self.city = city; self.timeZone = timeZone
    }

    public var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }
    /// The city, else the code.
    public var name: String { city ?? code }
}

/// A followed flight as the widgets draw it.
public struct WidgetFlight: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// As the backend stores it ("AFR84", "UA1527"); the widgets space it ("AFR 84").
    public var ident: String
    /// The operating airline's ICAO code, when known.
    public var airlineIcao: String?
    public var origin: WidgetAirport
    public var destination: WidgetAirport
    /// Gate departure and arrival as scheduled.
    public var scheduledOut: Date?
    public var scheduledIn: Date?
    /// Best known gate times: actual, else estimated, else scheduled.
    public var bestOut: Date?
    public var bestIn: Date?
    public var status: FlightStatus
    public var gateOrigin: String?
    public var gateDestination: String?
    public var terminalOrigin: String?
    public var terminalDestination: String?
    /// Best time against the schedule in whole minutes, negative when early; nil while one is unknown.
    public var departureDelayMinutes: Int?
    public var arrivalDelayMinutes: Int?
    /// How far the flight had flown when the snapshot was written, 0...1. The widgets use
    /// `progress(at:)`, which moves with the clock.
    public var progress: Double

    public init(id: UUID, ident: String, airlineIcao: String? = nil, origin: WidgetAirport, destination: WidgetAirport,
                scheduledOut: Date? = nil, scheduledIn: Date? = nil, bestOut: Date? = nil, bestIn: Date? = nil,
                status: FlightStatus, gateOrigin: String? = nil, gateDestination: String? = nil,
                terminalOrigin: String? = nil, terminalDestination: String? = nil,
                departureDelayMinutes: Int? = nil, arrivalDelayMinutes: Int? = nil, progress: Double = 0) {
        self.id = id; self.ident = ident; self.airlineIcao = airlineIcao
        self.origin = origin; self.destination = destination
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn
        self.bestOut = bestOut; self.bestIn = bestIn; self.status = status
        self.gateOrigin = gateOrigin; self.gateDestination = gateDestination
        self.terminalOrigin = terminalOrigin; self.terminalDestination = terminalDestination
        self.departureDelayMinutes = departureDelayMinutes; self.arrivalDelayMinutes = arrivalDelayMinutes
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
    }

    /// Departed or en route as last seen.
    public var isAirborne: Bool { status == .departed || status == .enRoute }

    /// When the widgets stop showing it: an hour after the best arrival, else after the departure.
    public var droppedAt: Date? {
        (bestIn ?? scheduledIn ?? bestOut ?? scheduledOut)?.addingTimeInterval(3600)
    }

    /// The Live Activity's rule (push-sender's `progressOf`): 1 once down, 0 before take-off, else the
    /// share of the best gate-to-gate time elapsed at `date`.
    public func progress(at date: Date) -> Double {
        switch status {
        case .landed, .arrived: return 1
        case .scheduled, .unknown, .canceled: return 0
        default: break
        }
        guard let out = bestOut, let inn = bestIn, inn > out else { return progress }
        return min(1, max(0, date.timeIntervalSince(out) / inn.timeIntervalSince(out)))
    }
}

/// Where the snapshot lives: a key in the App Group's defaults (`SharedSettings.defaults`), which the
/// app writes and the widget extension reads.
public enum WidgetSnapshotStore {
    public static let key = "widgets.snapshot"

    /// The saved snapshot, or an empty one when there is none or it cannot be read.
    public static func load(from defaults: UserDefaults = SharedSettings.defaults) -> WidgetSnapshot {
        defaults.data(forKey: key).flatMap(WidgetSnapshot.decode) ?? .empty(at: .distantPast)
    }

    /// False when it could not be encoded (nothing is written then).
    @discardableResult
    public static func save(_ snapshot: WidgetSnapshot, to defaults: UserDefaults = SharedSettings.defaults) -> Bool {
        do {
            defaults.set(try snapshot.encoded(), forKey: key)
            return true
        } catch {
            Logger(subsystem: "me.somalabs.flight", category: "widgets")
                .error("Widget snapshot not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// The link a widget opens: `somaflight://flight/<id>`. The app takes it as it takes a tapped flight
/// notification and opens that flight.
public enum FlightLink {
    public static let scheme = "somaflight"

    public static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://flight/\(id.uuidString.lowercased())")!
    }

    /// The flight a link names; nil for any other URL (the sign-in callback among them).
    public static func flightID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "flight" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: parts[0])
    }
}
