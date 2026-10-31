import Foundation

/// A boarding pass the traveller brought into the app, attached to one followed flight.
///
/// It comes either from a Wallet pass file (`.pkpass`, read from its `pass.json` and barcode) or from a
/// boarding pass barcode scanned with the camera or read from a picture (`BCBP`). A boarding pass is
/// personal data (the passenger's name, booking reference and a barcode that boards them), so it stays
/// on this device in `BoardingPassVault` and never goes to the server.
public struct BoardingPass: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// A signed Wallet pass file: the app also keeps the file, to offer Add to Apple Wallet.
        case wallet
        /// A barcode read by the camera or from a picture: there is no signed pass, only our own.
        case scan
    }

    public var id: UUID
    /// The followed flight it belongs to; nil while it is being matched.
    public var flightId: Flight.ID?
    public var source: Source
    /// "Luc Desmarais".
    public var passenger: String?
    /// Operating carrier as on the pass, IATA designator ("AF").
    public var carrier: String
    /// Flight number without leading zeros ("84", "1234A").
    public var flightNumber: String
    /// IATA airport codes ("CDG", "SFO").
    public var origin: String
    public var destination: String
    /// The day the flight leaves, local time at the origin (year, month, day).
    public var departureDay: DateComponents?
    public var seat: String?
    /// Booking class letter from the barcode ("J").
    public var compartment: String?
    /// The cabin as the airline names it ("Business", "Economy Plus"), when the pass says.
    public var cabin: String?
    public var group: String?
    public var zone: String?
    /// When boarding starts, when the pass gives a full date and time.
    public var boardingTime: Date?
    /// The boarding time as printed when it is only a time of day ("10:30").
    public var boardingText: String?
    public var gate: String?
    public var terminal: String?
    /// Booking reference ("ABC123").
    public var bookingReference: String?
    /// Check-in sequence number ("12").
    public var sequence: String?
    /// The airline as the pass names itself ("Air France").
    public var airlineName: String?
    public var barcode: PassBarcode?
    /// Who signed the Wallet pass and its serial, which together name it in the Wallet library.
    public var wallet: WalletPassID?
    public var addedAt: Date

    public init(id: UUID = UUID(), flightId: Flight.ID? = nil, source: Source, passenger: String? = nil,
                carrier: String, flightNumber: String, origin: String, destination: String,
                departureDay: DateComponents? = nil, seat: String? = nil, compartment: String? = nil,
                cabin: String? = nil, group: String? = nil, zone: String? = nil, boardingTime: Date? = nil,
                boardingText: String? = nil, gate: String? = nil, terminal: String? = nil,
                bookingReference: String? = nil, sequence: String? = nil, airlineName: String? = nil,
                barcode: PassBarcode? = nil, wallet: WalletPassID? = nil, addedAt: Date = .now) {
        self.id = id; self.flightId = flightId; self.source = source; self.passenger = passenger
        self.carrier = carrier; self.flightNumber = flightNumber; self.origin = origin; self.destination = destination
        self.departureDay = departureDay; self.seat = seat; self.compartment = compartment; self.cabin = cabin
        self.group = group; self.zone = zone; self.boardingTime = boardingTime; self.boardingText = boardingText
        self.gate = gate; self.terminal = terminal; self.bookingReference = bookingReference
        self.sequence = sequence; self.airlineName = airlineName; self.barcode = barcode; self.wallet = wallet
        self.addedAt = addedAt
    }

    /// "AF84": the carrier and number as one flight number, the way `Flight.ident` writes it.
    public var ident: String { carrier + flightNumber }

    /// The cabin to show: the airline's word, else the class the booking letter usually stands for.
    public var cabinTitle: String? { cabin ?? compartment.flatMap(Self.seatClass)?.title }

    /// The usual cabin of a booking class letter. Airlines choose their own letters, so this is a guess
    /// for the common ones: F A P first, J C D I Z R business, W premium economy, the rest economy.
    public static func seatClass(_ compartment: String) -> SeatClass? {
        switch compartment.uppercased() {
        case "F", "A", "P": .first
        case "J", "C", "D", "I", "Z", "R": .business
        case "W": .premiumEconomy
        case "": nil
        default: .economy
        }
    }

    /// The pass made from one leg of a scanned barcode (the first by default). `near` picks the year of the
    /// flight's day; `timeZone` is the origin's, when known.
    public init(bcbp: BCBP, leg index: Int = 0, barcode: PassBarcode?, source: Source = .scan, near: Date = .now,
                timeZone: TimeZone = .gmt) {
        let leg = bcbp.legs[min(max(index, 0), bcbp.legs.count - 1)]
        self.init(source: source, passenger: Self.displayName(bcbp.passengerName), carrier: leg.carrier,
                  flightNumber: leg.flightNumber, origin: leg.from, destination: leg.to,
                  departureDay: bcbp.day(of: leg, near: near, timeZone: timeZone), seat: leg.seat,
                  compartment: leg.compartment.map(String.init), bookingReference: leg.pnr.isEmpty ? nil : leg.pnr,
                  sequence: leg.sequence, barcode: barcode)
    }

    /// "DESMARAIS/LUC MR" as "Luc Desmarais": given names first, titles dropped, words capitalised.
    public static func displayName(_ bcbpName: String) -> String {
        let parts = bcbpName.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let family = parts.first ?? ""
        var given = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        let titles: Set<String> = ["MR", "MRS", "MS", "MISS", "MSTR", "DR", "PROF", "MX", "CHD", "INF"]
        // Only a separate word is a title: "LUCMR" keeps its letters.
        while let last = given.last, titles.contains(last.uppercased()) { given.removeLast() }
        let words = given + [family]
        return words.filter { !$0.isEmpty }.map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}

/// The barcode of a boarding pass, kept to draw it again full size at the gate.
public struct PassBarcode: Codable, Sendable, Hashable {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case pdf417, aztec, qr, code128
    }

    public var message: String
    public var format: Format
    /// Text Wallet prints under the code, when the pass has some.
    public var altText: String?
    /// The text encoding the code's bytes use ("iso-8859-1", the Wallet default).
    public var encoding: String?

    public init(message: String, format: Format, altText: String? = nil, encoding: String? = nil) {
        self.message = message; self.format = format; self.altText = altText; self.encoding = encoding
    }

    /// The Wallet name ("PKBarcodeFormatPDF417") as a format.
    public init?(walletFormat: String, message: String, altText: String? = nil, encoding: String? = nil) {
        let format: Format
        switch walletFormat {
        case "PKBarcodeFormatPDF417": format = .pdf417
        case "PKBarcodeFormatAztec": format = .aztec
        case "PKBarcodeFormatQR": format = .qr
        case "PKBarcodeFormatCode128": format = .code128
        default: return nil
        }
        self.init(message: message, format: format, altText: altText, encoding: encoding)
    }
}

/// The two values that name a Wallet pass: its pass type identifier and serial number.
public struct WalletPassID: Codable, Sendable, Hashable {
    public var passTypeIdentifier: String
    public var serialNumber: String

    public init(passTypeIdentifier: String, serialNumber: String) {
        self.passTypeIdentifier = passTypeIdentifier; self.serialNumber = serialNumber
    }
}
