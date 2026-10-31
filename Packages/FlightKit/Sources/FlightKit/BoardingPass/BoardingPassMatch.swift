import Foundation

/// Which flight a boarding pass is for, and what it adds to the flight's details. Pure, for tests.
public enum BoardingPassMatch {
    /// True when `pass` is for `flight`: the same airline and flight number, the same airports, and (when
    /// the pass gives one) the same day, local time at the origin.
    /// - Parameters:
    ///   - reference: resolves an airline code to the airline, so "AF" on the pass matches "AFR84".
    ///   - lookup: an airport by code, for the IATA code of a flight that carries only ICAO and for the
    ///     origin's zone. Without the zone the day may be one off either way.
    public static func matches(_ pass: BoardingPass, _ flight: Flight, reference: ReferenceData = .bundled(),
                               lookup: (String) -> Airport? = { _ in nil }) -> Bool {
        guard sameAirline(pass.carrier, flight: flight, reference: reference),
              sameNumber(pass.flightNumber, ident: flight.ident) else { return false }
        let origin = lookup(flight.originIcao), destination = lookup(flight.destinationIcao)
        guard sameAirport(pass.origin, icao: flight.originIcao, iata: flight.originIata ?? origin?.iata),
              sameAirport(pass.destination, icao: flight.destinationIcao, iata: flight.destinationIata ?? destination?.iata)
        else { return false }
        guard var day = pass.departureDay, let out = flight.scheduledOut ?? flight.estimatedOut ?? flight.actualOut else {
            return true
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = origin?.timeZone ?? .gmt
        let local = cal.dateComponents([.year, .month, .day], from: out)
        if local.month == day.month, local.day == day.day, day.year == nil || local.year == day.year { return true }
        guard origin == nil else { return false }
        if day.year == nil { day.year = local.year }
        guard let want = cal.date(from: day) else { return false }
        return abs(want.timeIntervalSince(cal.startOfDay(for: out))) <= 86_400
    }

    /// The first of `flights` the pass is for.
    public static func flight(for pass: BoardingPass, in flights: [Flight], reference: ReferenceData = .bundled(),
                              lookup: (String) -> Airport? = { _ in nil }) -> Flight? {
        flights.first { matches(pass, $0, reference: reference, lookup: lookup) }
    }

    /// The day to look the flight up on: the pass's own day at noon GMT, else `fallback`.
    public static func searchDate(_ pass: BoardingPass, fallback: Date = .now) -> Date {
        guard var day = pass.departureDay, day.year != nil else { return fallback }
        day.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        return cal.date(from: day) ?? fallback
    }

    /// "AF 84 · CDG to SFO · 23 Oct": how the import sheet names the pass's flight.
    public static func summary(_ pass: BoardingPass) -> String {
        var parts = ["\(pass.carrier) \(pass.flightNumber)", "\(pass.origin) to \(pass.destination)"]
        if let m = pass.departureDay?.month, let d = pass.departureDay?.day, (1...12).contains(m) {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            parts.append("\(d) \(months[m - 1])")
        }
        return parts.joined(separator: " · ")
    }

    /// The details with the booking code, seat and class taken from the pass where they are empty; nil
    /// when the pass adds nothing. A value the details would refuse (a seat like "INF") is left out.
    public static func filled(_ details: FollowDetails, from pass: BoardingPass) -> FollowDetails? {
        var next = details
        if next.bookingCode == nil, let code = pass.bookingReference,
           case let valid?? = FollowDetails.normalizedBookingCode(code) {
            next.bookingCode = valid
        }
        if next.seat == nil, let seat = pass.seat, case let valid?? = FollowDetails.normalizedSeat(seat) {
            next.seat = valid
        }
        if next.seatClass == nil {
            next.seatClass = pass.cabin.flatMap(seatClass(cabin:)) ?? pass.compartment.flatMap(BoardingPass.seatClass)
        }
        return next == details ? nil : next
    }

    /// The class an airline's cabin name stands for ("Business", "Premium Economy", "La Première").
    static func seatClass(cabin: String) -> SeatClass? {
        let c = cabin.lowercased()
        if c.contains("premium") { return .premiumEconomy }
        if c.contains("first") || c.contains("première") || c.contains("premiere") { return .first }
        if c.contains("business") || c.contains("affaires") || c.contains("club") || c.contains("polaris") { return .business }
        if c.contains("economy") || c.contains("coach") || c.contains("main") { return .economy }
        return nil
    }

    // MARK: Pieces

    /// "AF" against the flight's designator ("AF84" or "AFR84") and its operator, through the airline list
    /// when the codes differ (IATA on the pass, ICAO on the flight).
    static func sameAirline(_ carrier: String, flight: Flight, reference: ReferenceData) -> Bool {
        let c = carrier.uppercased()
        let designator = TravelFacts.airlineCode(ident: flight.ident).uppercased()
        if c == designator || c == flight.operator?.uppercased() { return true }
        guard let airline = reference.airline(c) else { return false }
        let codes = Set([airline.id.uppercased(), airline.iata?.uppercased()].compactMap { $0 })
        return codes.contains(designator) || flight.operator.map { codes.contains($0.uppercased()) } == true
    }

    /// "84" against "AF84", "0084" against "AFR84": the digits as numbers, the suffix letter as is.
    static func sameNumber(_ number: String, ident: String) -> Bool {
        let designator = TravelFacts.airlineCode(ident: ident)
        let rest = String(ident.dropFirst(designator.count))
        guard let a = BCBP.flightNumber(number), let b = BCBP.flightNumber(rest) else { return false }
        return a == b
    }

    private static func sameAirport(_ code: String, icao: String, iata: String?) -> Bool {
        let c = code.uppercased()
        return c == icao.uppercased() || c == iata?.uppercased()
    }
}
