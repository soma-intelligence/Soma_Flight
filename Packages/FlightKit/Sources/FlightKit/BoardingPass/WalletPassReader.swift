import Foundation

/// Reads a Wallet boarding pass file (`.pkpass`) into a `BoardingPass`, from its `pass.json`.
///
/// Airlines fill a pass in three ways, read in this order, each one filling only what the earlier left
/// empty: the semantic tags Wallet uses for its own flight features (`semantics`: airline code, flight
/// number, airports, passenger, seats, gate, group, boarding time); the barcode, which is almost always the
/// IATA BCBP string (passenger, booking reference, flight, day, seat); and the visible fields, by their
/// keys and labels ("gate", "seat", "group", "boarding"). Labels and values are looked up in the English
/// `pass.strings` when the pass is localised. Nothing is verified here: the signature is Wallet's job
/// when the pass is added to it.
public enum WalletPassReader {
    public enum ReadError: Error, Equatable, Sendable {
        /// Not a pass file (not a zip, or no `pass.json`).
        case notAPass
        /// A pass, but not a boarding pass (an event ticket, a store card).
        case notBoardingPass
        /// A boarding pass without a flight number or airports we can read.
        case missingFlight
    }

    /// The pass in `data`, a `.pkpass` file. `near` picks the year of a barcode-only day.
    public static func read(_ data: Data, near: Date = .now) throws(ReadError) -> BoardingPass {
        let zip: ZipArchive
        do { zip = try ZipArchive(data) } catch { throw .notAPass }
        guard let json = try? zip.file("pass.json"),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw .notAPass }
        let strings = localizedStrings(zip)
        return try read(passJSON: object, strings: strings, near: near)
    }

    /// The pass from a decoded `pass.json` and its English strings (key to text).
    static func read(passJSON p: [String: Any], strings: [String: String] = [:], near: Date = .now) throws(ReadError) -> BoardingPass {
        guard let style = p["boardingPass"] as? [String: Any] else { throw .notBoardingPass }
        func text(_ any: Any?) -> String? {
            let raw: String? = switch any {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            default: nil
            }
            guard let raw else { return nil }
            let t = (strings[raw] ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        // Every field of the five groups, in display order.
        let groups = ["headerFields", "primaryFields", "secondaryFields", "auxiliaryFields", "backFields"]
        let fields: [[String: Any]] = groups.flatMap { style[$0] as? [[String: Any]] ?? [] }
        var semantics = p["semantics"] as? [String: Any] ?? [:]
        for f in fields { for (k, v) in f["semantics"] as? [String: Any] ?? [:] where semantics[k] == nil { semantics[k] = v } }

        // The barcode: `barcodes` (iOS 9 and later) first, else the older single `barcode`.
        let codes = (p["barcodes"] as? [[String: Any]]) ?? (p["barcode"] as? [String: Any]).map { [$0] } ?? []
        let barcode = codes.lazy.compactMap { c -> PassBarcode? in
            guard let message = c["message"] as? String, let format = c["format"] as? String else { return nil }
            return PassBarcode(walletFormat: format, message: message, altText: c["altText"] as? String,
                               encoding: c["messageEncoding"] as? String)
        }.first

        // The visible fields by what they hold: their key or label names it.
        func field(_ words: [String]) -> String? {
            for f in fields {
                let key = (f["key"] as? String ?? "").lowercased()
                let label = (text(f["label"]) ?? "").lowercased()
                if words.contains(where: { key.contains($0) || label.contains($0) }), let v = text(f["value"]) {
                    return v
                }
            }
            return nil
        }
        func fieldDate(_ words: [String]) -> Date? {
            for f in fields {
                let key = (f["key"] as? String ?? "").lowercased()
                let label = (text(f["label"]) ?? "").lowercased()
                if words.contains(where: { key.contains($0) || label.contains($0) }), let v = f["value"] as? String,
                   let d = isoDate(v) { return d }
            }
            return nil
        }

        let primary = (style["primaryFields"] as? [[String: Any]] ?? []).compactMap { text($0["value"]) }
        let bcbp = barcode.flatMap { try? BCBP.parse($0.message) }
        let origin0 = text(semantics["departureAirportCode"]) ?? primary.first.flatMap(airportCode)
        let destination0 = text(semantics["destinationAirportCode"]) ?? (primary.count > 1 ? airportCode(primary[1]) : nil)
        // A multi-leg barcode on a one-leg pass: the leg of the pass's own airports.
        let legIndex = bcbp?.legs.firstIndex { $0.from == origin0?.uppercased() && $0.to == destination0?.uppercased() } ?? 0
        var pass = bcbp.map { BoardingPass(bcbp: $0, leg: legIndex, barcode: barcode, source: .wallet, near: near) }

        let flightCode = text(semantics["flightCode"]) ?? field(["flight"])
        let split = flightCode.flatMap(Self.splitFlight)
        let carrier = text(semantics["airlineCode"]) ?? split?.carrier
        let number = text(semantics["flightNumber"]).flatMap { BCBP.flightNumber($0) } ?? split?.number

        if pass == nil {
            guard let carrier, let number, let o = origin0, let d = destination0 else { throw .missingFlight }
            pass = BoardingPass(source: .wallet, carrier: carrier.uppercased(), flightNumber: number,
                                origin: o.uppercased(), destination: d.uppercased(), barcode: barcode)
        }
        guard var out = pass else { throw .missingFlight }
        // The semantic tags are the airline's own words for Wallet: they win over the barcode's.
        if let c = text(semantics["airlineCode"]) { out.carrier = c.uppercased() }
        if let n = text(semantics["flightNumber"]).flatMap({ BCBP.flightNumber($0) }) { out.flightNumber = n }
        if let o = text(semantics["departureAirportCode"]) { out.origin = o.uppercased() }
        if let d = text(semantics["destinationAirportCode"]) { out.destination = d.uppercased() }

        if let name = semantics["passengerName"] as? [String: Any] {
            let parts = [text(name["givenName"]), text(name["familyName"])].compactMap { $0 }
            if !parts.isEmpty { out.passenger = parts.joined(separator: " ") }
        }
        if out.passenger == nil { out.passenger = field(["passenger", "name"]) }

        let seats = semantics["seats"] as? [[String: Any]] ?? []
        if let seat = seats.first {
            let number = text(seat["seatNumber"]) ?? [text(seat["seatRow"]), text(seat["seatSection"])].compactMap { $0 }.joined()
            if !number.isEmpty { out.seat = number.uppercased() }
            if let cabin = text(seat["seatType"]) { out.cabin = cabin }
        }
        if out.seat == nil { out.seat = field(["seat"]) }
        if out.cabin == nil { out.cabin = field(["class", "cabin"]) }

        out.group = text(semantics["boardingGroup"]) ?? field(["group"])
        out.zone = text(semantics["boardingZone"]) ?? field(["zone"])
        out.gate = text(semantics["departureGate"]) ?? field(["gate"])
        out.terminal = text(semantics["departureTerminal"]) ?? field(["terminal"])
        if let code = text(semantics["confirmationNumber"]) ?? field(["confirmation", "pnr", "locator", "booking", "reference"]) {
            out.bookingReference = code.uppercased()
        }

        let boardingSemantic = (semantics["currentBoardingDate"] as? String ?? semantics["originalBoardingDate"] as? String)
            .flatMap(isoDate)
        out.boardingTime = boardingSemantic ?? fieldDate(["boarding"])
        if out.boardingTime == nil { out.boardingText = field(["boarding"]) }
        if out.departureDay == nil {
            let raw = semantics["currentDepartureDate"] as? String ?? semantics["originalDepartureDate"] as? String
                ?? p["relevantDate"] as? String
            if let raw, let departs = isoDate(raw) { out.departureDay = localDay(departs, offsetOf: raw) }
        }

        out.airlineName = text(p["organizationName"])
        if let type = p["passTypeIdentifier"] as? String, let serial = p["serialNumber"] as? String {
            out.wallet = WalletPassID(passTypeIdentifier: type, serialNumber: serial)
        }
        out.source = .wallet
        return out
    }

    // MARK: Pieces

    /// "AF 84", "AF0084", "AF84" as carrier and number; nil when it is not a flight number.
    static func splitFlight(_ s: String) -> (carrier: String, number: String)? {
        let t = s.uppercased().replacingOccurrences(of: " ", with: "")
        guard let m = t.wholeMatch(of: /([A-Z]{2,3}|[A-Z][0-9]|[0-9][A-Z])([0-9]{1,4}[A-Z]?)/),
              let n = BCBP.flightNumber(String(m.2)) else { return nil }
        return (String(m.1), n)
    }

    /// A three letter airport code at the start of a primary field's value ("CDG", "CDG Paris").
    private static func airportCode(_ s: String) -> String? {
        let head = String(s.prefix(3)).uppercased()
        guard head.count == 3, head.allSatisfy({ $0.isASCII && $0.isLetter }),
              s.count == 3 || !(s.dropFirst(3).first?.isLetter ?? false) else { return nil }
        return head
    }

    /// A W3C date and time as Wallet writes them ("2026-10-23T10:30:00+02:00", with or without seconds).
    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // "2026-10-23T10:30+02:00": no seconds.
        let withSeconds = s.replacing(/T(\d{2}):(\d{2})([+\-Z])/) { m in "T\(m.1):\(m.2):00\(m.3)" }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: withSeconds)
    }

    /// The calendar day of `date` at the offset its text carries ("+02:00"), else in GMT.
    private static func localDay(_ date: Date, offsetOf text: String?) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = text.flatMap(offset).flatMap { TimeZone(secondsFromGMT: $0) } ?? .gmt
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    private static func offset(_ s: String) -> Int? {
        if s.hasSuffix("Z") { return 0 }
        guard let m = s.firstMatch(of: /([+-])(\d{2}):?(\d{2})$/), let h = Int(m.2), let mm = Int(m.3) else { return nil }
        return (m.1 == "-" ? -1 : 1) * (h * 3600 + mm * 60)
    }

    /// `en.lproj/pass.strings` (else the first language's), as key to text. Wallet strings files are
    /// UTF-16 or UTF-8 old-style property lists.
    private static func localizedStrings(_ zip: ZipArchive) -> [String: String] {
        let path = zip.paths.first { $0 == "en.lproj/pass.strings" } ?? zip.paths.first { $0.hasSuffix(".lproj/pass.strings") }
        guard let path, let data = try? zip.file(path) else { return [:] }
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
        if let dict = parsed as? [String: String] { return dict }
        guard let text = String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf8),
              let utf8 = text.data(using: .utf8) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: utf8, format: nil)) as? [String: String] ?? [:]
    }
}
