import CoreGraphics
import CoreText
import Foundation

/// Plan 27: past flights grouped into trips for an expense claim. A trip is a run of flights close in time:
/// each leg leaves at most `maxGap` after the previous one landed, or it is the flight back to where the trip
/// began, within `maxLength` of the first departure. Landing back where it began ends the trip. Canceled
/// flights are left out (nothing was flown). Built on the device from the history alone.
public enum ExpenseTrips {
    /// Longest wait between two legs of one trip.
    public static let maxGap: TimeInterval = 5 * 86_400
    /// Longest trip: the flight home may come up to this long after the first departure.
    public static let maxLength: TimeInterval = 21 * 86_400

    public enum Filter: String, Sendable, Hashable, CaseIterable {
        /// Every flight.
        case all
        /// Only the flights the traveller marked as business.
        case business
    }

    /// The trips in `flights`, newest first; the legs of each in date order.
    public static func group(_ flights: [PastFlight], filter: Filter = .all) -> [ExpenseTrip] {
        let kept = flights
            .filter { $0.status != .canceled && (filter == .all || $0.reason == .business) }
            .sorted { $0.date < $1.date }
        var trips: [[PastFlight]] = []
        var current: [PastFlight] = []
        for f in kept {
            if let first = current.first, let last = current.last {
                let gap = f.date.timeIntervalSince(landing(last))
                let length = f.date.timeIntervalSince(first.date)
                let home = f.destinationIcao == first.originIcao
                let closed = last.destinationIcao == first.originIcao
                if !closed, length <= maxLength, gap <= maxGap || home {
                    current.append(f)
                    continue
                }
                trips.append(current)
            }
            current = [f]
        }
        if !current.isEmpty { trips.append(current) }
        return trips.reversed().map(ExpenseTrip.init)
    }

    /// When a leg landed: the departure plus the block time when it is known.
    static func landing(_ f: PastFlight) -> Date {
        f.date.addingTimeInterval(Double(f.blockMinutes ?? 0) * 60)
    }
}

/// One trip: its legs in date order (never empty).
public struct ExpenseTrip: Sendable, Hashable, Identifiable {
    public var legs: [PastFlight]

    public init(legs: [PastFlight]) { self.legs = legs }

    public var id: UUID { legs[0].id }
    public var start: Date { legs[0].date }
    public var end: Date { ExpenseTrips.landing(legs[legs.count - 1]) }
    public var distanceKm: Int { legs.reduce(0) { $0 + $1.distanceKm } }
    /// The airports in flying order: "KSFO", "KJFK", "EGLL", "KSFO". A leg that leaves from somewhere other
    /// than where the last one landed (a train in between) adds both.
    public var route: [String] {
        var out = [legs[0].originIcao]
        for l in legs {
            if out.last != l.originIcao { out.append(l.originIcao) }
            out.append(l.destinationIcao)
        }
        return out
    }
    /// True when the last leg lands where the first one left.
    public var isRoundTrip: Bool { legs.count > 1 && legs[legs.count - 1].destinationIcao == legs[0].originIcao }
}

/// One trip's expense report as a PDF: the traveller, each leg (date, flight, airline, route, local times,
/// delays, seat, class, booking code), the total distance and a footer. The traveller's free-text notes go in
/// only when `includesNotes` is on: they can hold things meant for no one else. No prices: the app never has
/// them. Drawn with Core Text so the text stays selectable and searchable.
public struct ExpenseReport: Sendable {
    public var trip: ExpenseTrip
    public var traveller: String?
    public var unit: DistanceUnit
    public var clock: TimeStyle
    /// The trip's airports by ICAO, for cities, codes and time zones.
    public var airports: [String: Airport]
    public var locale: Locale
    /// Prints each leg's notes. Off unless the traveller turns it on.
    public var includesNotes: Bool
    var reference: ReferenceData

    public init(trip: ExpenseTrip, traveller: String?, unit: DistanceUnit, clock: TimeStyle = .h24,
                airports: [String: Airport], locale: Locale = .current, includesNotes: Bool = false,
                reference: ReferenceData = .bundled()) {
        self.trip = trip; self.unit = unit; self.clock = clock; self.airports = airports; self.locale = locale
        self.includesNotes = includesNotes; self.reference = reference
        let name = traveller?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.traveller = name.isEmpty ? nil : name
    }

    /// Builds the report for `trip`, finding its airports with `lookup`.
    public init(trip: ExpenseTrip, traveller: String?, unit: DistanceUnit, clock: TimeStyle = .h24,
                lookup: (String) -> Airport?, locale: Locale = .current, includesNotes: Bool = false) {
        var found: [String: Airport] = [:]
        for code in trip.route { if let a = lookup(code) { found[code] = a } }
        self.init(trip: trip, traveller: traveller, unit: unit, clock: clock, airports: found, locale: locale,
                  includesNotes: includesNotes)
    }

    // MARK: Words

    /// "Trip to Paris": the first leg's destination.
    public var title: String { ExpenseFacts.title(city(trip.legs[0].destinationIcao)) }

    /// "soma-flight-trip-2025-03-10.pdf", after the first departure's local day.
    public var fileName: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(trip.legs[0].originIcao, fallback: trip.legs[0].originTz)
        let c = cal.dateComponents([.year, .month, .day], from: trip.start)
        return String(format: "soma-flight-trip-%04d-%02d-%02d.pdf", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func city(_ icao: String) -> String { airports[icao]?.city ?? icao }
    func code(_ icao: String) -> String { airports[icao]?.iata ?? icao }
    func zone(_ icao: String, fallback: String? = nil) -> TimeZone {
        airports[icao]?.timeZone ?? fallback.flatMap(TimeZone.init(identifier:)) ?? .gmt
    }

    func day(_ date: Date, in tz: TimeZone) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = tz
        return date.formatted(style)
    }

    func airlineName(_ f: PastFlight) -> String? {
        if let a = f.airline, !a.isEmpty { return reference.airline(a)?.name ?? a }
        return reference.airline(ident: f.ident)?.name
    }

    // MARK: Layout

    /// One block of text, kept whole on a page.
    struct Block {
        var text: NSAttributedString
        var spaceBefore: CGFloat
    }

    /// The page: A4, US Letter where the locale's region uses it.
    var pageSize: CGSize {
        ["US", "CA", "MX", "PH", "CL", "CO"].contains(locale.region?.identifier ?? "")
            ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }
    static let margin: CGFloat = 48
    static let footerHeight: CGFloat = 28
    var textWidth: CGFloat { pageSize.width - 2 * Self.margin }

    func blocks() -> [Block] {
        var out: [Block] = []
        var head = [Line(ExpenseFacts.heading, size: 11, bold: true, grey: true),
                    Line(title, size: 22, bold: true)]
        let first = trip.legs[0], last = trip.legs[trip.legs.count - 1]
        let from = day(trip.start, in: zone(first.originIcao, fallback: first.originTz))
        let to = day(trip.end, in: zone(last.destinationIcao))
        head.append(Line(from == to ? from : ExpenseFacts.range(from, to), size: 13))
        head.append(Line(trip.route.map(code).joined(separator: " \u{2192} "), size: 13, grey: true))
        if let traveller { head.append(Line(ExpenseFacts.traveller(traveller), size: 13)) }
        head.append(Line(ExpenseFacts.summary(legs: trip.legs.count, distance: TravelFacts.distance(trip.distanceKm, unit)),
                         size: 13))
        out.append(Block(text: Line.join(head), spaceBefore: 0))
        for (i, leg) in trip.legs.enumerated() {
            out.append(Block(text: Line.join(lines(for: leg, number: i + 1)), spaceBefore: 18))
        }
        return out
    }

    func lines(for f: PastFlight, number: Int) -> [Line] {
        let fromZone = zone(f.originIcao, fallback: f.originTz), toZone = zone(f.destinationIcao)
        var top = "\(day(f.date, in: fromZone)) \u{00B7} \(Format.ident(f.ident))"
        if let name = airlineName(f) { top += " \u{00B7} \(name)" }
        var out = [Line(ExpenseFacts.leg(number), size: 10, bold: true, grey: true), Line(top, size: 14, bold: true)]
        out.append(Line(ExpenseFacts.route(from: "\(city(f.originIcao)) (\(code(f.originIcao)))",
                                           to: "\(city(f.destinationIcao)) (\(code(f.destinationIcao)))"), size: 12))
        var dep = ExpenseFacts.departure(localTime(f.date, in: fromZone, style: clock))
        if let d = f.departureDelayMinutes, let late = ExpenseFacts.delay(d) { dep += ", \(late)" }
        out.append(Line(dep, size: 12))
        if let block = f.blockMinutes, block > 0 {
            let landed = f.date.addingTimeInterval(Double(block) * 60)
            var arr = ExpenseFacts.arrival(localTime(landed, in: toZone, style: clock))
            if day(landed, in: toZone) != day(f.date, in: fromZone) { arr += " (\(day(landed, in: toZone)))" }
            if let d = f.arrivalDelayMinutes, let late = ExpenseFacts.delay(d) { arr += ", \(late)" }
            out.append(Line(arr, size: 12))
        }
        var seat: [String] = []
        if let s = f.seat?.trimmingCharacters(in: .whitespaces), !s.isEmpty { seat.append(ExpenseFacts.seat(s)) }
        if let c = f.seatClass { seat.append(String(localized: String.LocalizationValue(c.title), bundle: .main)) }
        if !seat.isEmpty { out.append(Line(seat.joined(separator: " \u{00B7} "), size: 12)) }
        if let b = f.bookingCode?.trimmingCharacters(in: .whitespaces), !b.isEmpty {
            out.append(Line(ExpenseFacts.booking(b), size: 12))
        }
        out.append(Line(TravelFacts.distance(f.distanceKm, unit), size: 12, grey: true))
        if f.status == .diverted { out.append(Line(ExpenseFacts.diverted, size: 12, bold: true)) }
        if includesNotes, let n = f.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            out.append(Line(ExpenseFacts.notes(String(n.prefix(800))), size: 12, grey: true))
        }
        return out
    }

    /// The blocks placed on pages: each block's top (from the page's top) on its page.
    func layout() -> [[(block: Block, top: CGFloat, height: CGFloat)]] {
        let bottom = pageSize.height - Self.margin - Self.footerHeight
        let maxHeight = bottom - Self.margin
        var pages: [[(block: Block, top: CGFloat, height: CGFloat)]] = [[]]
        var y = Self.margin
        for b in blocks() {
            let h = min(Self.height(b.text, width: textWidth), maxHeight)
            var top = y + (pages[pages.count - 1].isEmpty ? 0 : b.spaceBefore)
            if top + h > bottom, !pages[pages.count - 1].isEmpty {
                pages.append([])
                top = Self.margin
            }
            pages[pages.count - 1].append((b, top, h))
            y = top + h
        }
        return pages
    }

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height)
    }

    /// The PDF file's bytes.
    public func pdf() -> Data {
        let pages = layout()
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Soma Flight"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        for (i, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            for item in page {
                draw(item.block.text, in: CGRect(x: Self.margin, y: pageSize.height - item.top - item.height,
                                                 width: textWidth, height: item.height), ctx)
            }
            let footer = Line.join([Line(ExpenseFacts.footer(page: i + 1, of: pages.count), size: 9, grey: true)])
            draw(footer, in: CGRect(x: Self.margin, y: Self.margin - 8, width: textWidth, height: Self.footerHeight), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private func draw(_ text: NSAttributedString, in rect: CGRect, _ ctx: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    /// One line of the report and its look.
    struct Line {
        var text: String
        var size: CGFloat
        var bold = false
        var grey = false

        init(_ text: String, size: CGFloat, bold: Bool = false, grey: Bool = false) {
            self.text = text; self.size = size; self.bold = bold; self.grey = grey
        }

        static func join(_ lines: [Line]) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for (i, l) in lines.enumerated() {
                let base = CTFontCreateUIFontForLanguage(.system, l.size, nil)
                    ?? CTFontCreateWithName("Helvetica" as CFString, l.size, nil)
                let font = l.bold ? (CTFontCreateCopyWithSymbolicTraits(base, l.size, nil, .traitBold, .traitBold) ?? base) : base
                let color = l.grey ? CGColor(gray: 0.38, alpha: 1) : CGColor(gray: 0, alpha: 1)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]
                out.append(NSAttributedString(string: l.text + (i == lines.count - 1 ? "" : "\n"), attributes: attrs))
            }
            return out
        }
    }
}

/// The report's words, English source with French in Localizable.xcstrings.
enum ExpenseFacts {
    static var heading: String { String(localized: "TRAVEL EXPENSE REPORT", bundle: .main) }
    static func title(_ city: String) -> String { String(localized: "Trip to \(city)", bundle: .main) }
    static func range(_ a: String, _ b: String) -> String { String(localized: "\(a) to \(b)", bundle: .main) }
    static func traveller(_ name: String) -> String { String(localized: "Traveller: \(name)", bundle: .main) }
    static func summary(legs: Int, distance: String) -> String {
        legs == 1 ? String(localized: "1 flight \u{00B7} \(distance)", bundle: .main)
            : String(localized: "\(legs) flights \u{00B7} \(distance)", bundle: .main)
    }
    static func leg(_ n: Int) -> String { String(localized: "FLIGHT \(n)", bundle: .main) }
    static func route(from: String, to: String) -> String { "\(from) \u{2192} \(to)" }
    static func departure(_ time: String) -> String { String(localized: "Departure \(time)", bundle: .main) }
    static func arrival(_ time: String) -> String { String(localized: "Arrival \(time)", bundle: .main) }
    /// "25 min late", "10 min early"; nil on time.
    static func delay(_ minutes: Int) -> String? {
        if minutes > 0 { return String(localized: "\(minutes) min late", bundle: .main) }
        if minutes < 0 { return String(localized: "\(-minutes) min early", bundle: .main) }
        return nil
    }
    static func seat(_ s: String) -> String { String(localized: "Seat \(s)", bundle: .main) }
    static func booking(_ b: String) -> String { String(localized: "Booking code \(b)", bundle: .main) }
    static func notes(_ n: String) -> String { String(localized: "Notes: \(n)", bundle: .main) }
    static var diverted: String { String(localized: "Diverted", bundle: .main) }
    static func footer(page: Int, of count: Int) -> String {
        String(localized: "Made with Soma Flight \u{00B7} Page \(page) of \(count)", bundle: .main)
    }
}
