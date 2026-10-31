import Foundation

/// Finds the flights in a confirmation email, on the device. Reads the schema.org `FlightReservation`
/// markup most airlines and agencies embed (JSON-LD, then microdata) and, failing that, the text of the
/// email and of its PDF itinerary, laid out the usual ways ("AF 84", "Paris (CDG) 10:15 → San Francisco
/// (SFO) 12:40", "Sun 14 Mar 2027"). Passenger names, prices and addresses are never read. Pure.
public enum EmailFlightReader {
    /// How the flights were found.
    public enum Method: String, Sendable, Hashable {
        /// From the email's `FlightReservation` markup.
        case structured
        /// From its text (or its PDF's).
        case text
    }

    public struct Result: Sendable, Hashable {
        public var flights: [ImportedFlight]
        /// nil when nothing was found.
        public var method: Method?
        /// The booking reference found, shown with the flights.
        public var bookingReference: String?
    }

    /// Three upper-case letters that are not a word of a booking ("THE", "PNR"): the default airport
    /// test where no airport list is at hand (the share extension).
    public static func plausibleAirport(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase } && !notAirports.contains(code)
    }

    static let notAirports: Set<String> = [
        "THE", "AND", "FOR", "YOU", "PNR", "REF", "VIA", "NON", "ONE", "TWO", "ALL", "ARE", "NOT", "PER", "OUR", "BAG",
        "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN", "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG",
        "SEP", "OCT", "NOV", "DEC", "USD", "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "TAX", "VAT", "FEE", "UTC",
        "GMT", "PST", "PDT", "EST", "EDT", "CST", "CDT", "CET", "BST", "MST", "MDT", "ETA", "ETD", "MRS", "MISS",
        "ADT", "CHD", "INF", "AIR", "NEW", "YES", "QTY", "TBA", "TBD", "ECO", "BUS", "FLT", "DEP", "ARR", "SEAT",
        "ROW", "APP", "WEB", "FAQ", "PDF", "DIR", "STD", "STA", "EMD", "TKT", "OUT", "RET", "AVE", "AVR", "VOL",
        "DES", "LES", "UNE", "AUX", "PAR", "SUR", "VON", "UND", "DER", "DIE", "DAS", "DEL", "LOS", "LAS", "CON",
    ]

    /// - Parameters:
    ///   - pdfText: the text of the message's PDF attachments (the platform layer reads them).
    ///   - now: when the email arrived if its headers do not say; years a date leaves out are read near it.
    ///   - isAirport: whether a code is a real airport; the app passes its airport list.
    public static func read(_ message: EmailMessage, pdfText: [String] = [], now: Date = .now,
                            isAirport: (String) -> Bool = plausibleAirport) -> Result {
        let sent = message.sent ?? now
        var structured: [ImportedFlight] = []
        for html in message.htmlParts {
            for block in HTMLText.jsonLD(html) {
                guard let data = block.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
                structured += reservations(in: json).compactMap { flight(fromReservation: $0, evidence: "Booking markup (JSON-LD)") }
            }
        }
        if structured.isEmpty {
            for html in message.htmlParts {
                for item in HTMLText.microdata(html) {
                    structured += reservations(in: item.json).compactMap { flight(fromReservation: $0, evidence: "Booking markup (microdata)") }
                }
            }
        }
        if !structured.isEmpty {
            let merged = dedupe(structured)
            return Result(flights: merged, method: .structured, bookingReference: merged.lazy.compactMap(\.bookingReference).first)
        }

        var texts = message.plainParts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if texts.isEmpty { texts = message.htmlParts.map(HTMLText.visibleText) }
        texts += pdfText
        var found: [ImportedFlight] = []
        withoutActuallyEscaping(isAirport) { isAirport in
            let reader = TextReader(reference: sent, isAirport: isAirport)
            for text in texts { found += reader.flights(in: text) }
        }
        let merged = dedupe(found)
        return Result(flights: merged, method: merged.isEmpty ? nil : .text,
                      bookingReference: merged.lazy.compactMap(\.bookingReference).first)
    }

    /// Reads raw email bytes or pasted text.
    public static func read(_ data: Data, now: Date = .now, isAirport: (String) -> Bool = plausibleAirport) -> Result {
        let message = EmailMessage.parse(data)
        return read(message, pdfText: message.pdfs.compactMap(PDFText.text), now: now, isAirport: isAirport)
    }

    // MARK: Markup

    /// Every `FlightReservation` (or bare `Flight`) object in a JSON-LD value: arrays, `@graph` and
    /// nesting walked.
    static func reservations(in json: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ v: Any, depth: Int) {
            guard depth < 12 else { return }
            if let array = v as? [Any] { array.forEach { walk($0, depth: depth + 1) }; return }
            guard let object = v as? [String: Any] else { return }
            let types = typeNames(object["@type"])
            if types.contains("FlightReservation") {
                // One reservation may list several flights.
                if let legs = object["reservationFor"] as? [Any] {
                    for leg in legs { var copy = object; copy["reservationFor"] = leg; out.append(copy) }
                } else {
                    out.append(object)
                }
                return
            }
            if types.contains("Flight") { out.append(["@type": "FlightReservation", "reservationFor": object]); return }
            for (key, value) in object where key != "@context" { walk(value, depth: depth + 1) }
        }
        walk(json, depth: 0)
        return out
    }

    private static func typeNames(_ v: Any?) -> [String] {
        let raw: [String] = (v as? String).map { [$0] } ?? (v as? [String]) ?? []
        return raw.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func object(_ v: Any?) -> [String: Any]? {
        (v as? [String: Any]) ?? (v as? [Any])?.first as? [String: Any]
    }

    /// A reservation's flight; nil without a departure day.
    static func flight(fromReservation r: [String: Any], evidence: String) -> ImportedFlight? {
        guard let leg = object(r["reservationFor"]) else { return nil }
        let airlineObject = object(leg["airline"]) ?? object(leg["provider"])
        var airline = string(airlineObject?["iataCode"]) ?? string(leg["airline"]) ?? string(airlineObject?["name"])
        var number = string(leg["flightNumber"])
        if let n = number?.filter({ !$0.isWhitespace }).uppercased(),
           let m = n.wholeMatch(of: /([A-Z]{2,3}|[A-Z][0-9]|[0-9][A-Z])([0-9]{1,4}[A-Z]?)/) {
            // "AF84" in flightNumber: the prefix is the airline unless a code came with it.
            if airline == nil || airline!.count > 3 { airline = String(m.1) }
            number = String(m.2)
        }
        let dep = object(leg["departureAirport"]), arr = object(leg["arrivalAirport"])
        let origin = string(dep?["iataCode"]) ?? string(dep?["icaoCode"]) ?? string(leg["departureAirport"])
        let destination = string(arr?["iataCode"]) ?? string(arr?["icaoCode"]) ?? string(leg["arrivalAirport"])
        guard let depText = string(leg["departureTime"]) ?? string(r["departureTime"]),
              let (day, time) = localStamp(depText) else { return nil }
        var f = ImportedFlight(airline: airline, number: number, origin: origin?.uppercased(), destination: destination?.uppercased(),
                               day: day, departureTime: time, evidence: [evidence])
        if let arrText = string(leg["arrivalTime"]), let (aDay, aTime) = localStamp(arrText) {
            f.arrivalDay = aDay; f.arrivalTime = aTime
        }
        f.aircraft = string(leg["aircraft"]) ?? string(object(leg["aircraft"])?["name"])
        f.bookingReference = string(r["reservationNumber"]) ?? string(r["reservationId"])
        let ticket = object(r["reservedTicket"])
        f.seat = string(r["airplaneSeat"]) ?? string(object(ticket?["ticketedSeat"])?["seatNumber"])
        f.cabin = string(r["airplaneSeatClass"]) ?? string(object(r["airplaneSeatClass"])?["name"])
            ?? string(object(ticket?["ticketedSeat"])?["seatingType"])
        if let status = string(r["reservationStatus"])?.lowercased(), status.contains("cancel") { f.canceled = true }
        return f
    }

    /// The local day and time an ISO 8601 stamp reads ("2027-03-14T10:15:00+01:00" gives 14 March, 10:15):
    /// the wall clock as written, which is the airport's (schema.org asks for local times).
    static func localStamp(_ s: String) -> (LocalDay, LocalTime?)? {
        guard let m = s.firstMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]([0-9]{2}):([0-9]{2}))?/) else { return nil }
        let day = LocalDay(year: Int(m.1)!, month: Int(m.2)!, day: Int(m.3)!)
        guard day.isValid else { return nil }
        let time = m.4.flatMap { h in m.5.flatMap { LocalTime(hour: Int(h)!, minute: Int($0)!) } }
        return (day, time)
    }

    // MARK: Merging

    /// One flight per number and day (an email shows a flight in its summary and its details), the
    /// fullest kept, gaps filled from the others; flights without a number kept by route and day.
    static func dedupe(_ flights: [ImportedFlight]) -> [ImportedFlight] {
        var order: [String] = []
        var byKey: [String: ImportedFlight] = [:]
        for f in flights {
            let key = "\(f.ident ?? "\(f.origin ?? "")-\(f.destination ?? "")") \(f.day)"
            if var kept = byKey[key] {
                kept.origin = kept.origin ?? f.origin
                kept.destination = kept.destination ?? f.destination
                kept.departureTime = kept.departureTime ?? f.departureTime
                kept.arrivalTime = kept.arrivalTime ?? f.arrivalTime
                kept.arrivalDay = kept.arrivalDay ?? f.arrivalDay
                kept.seat = kept.seat ?? f.seat
                kept.cabin = kept.cabin ?? f.cabin
                kept.aircraft = kept.aircraft ?? f.aircraft
                kept.bookingReference = kept.bookingReference ?? f.bookingReference
                kept.canceled = kept.canceled || f.canceled
                byKey[key] = kept
            } else {
                order.append(key)
                byKey[key] = f
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
