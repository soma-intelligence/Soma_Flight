import Foundation
import Testing
@testable import FlightImportKit
import FlightKit
#if canImport(AppKit)
import AppKit
#endif

/// Confirmation emails read on the device: schema.org markup (JSON-LD, microdata) first, the text of
/// common layouts otherwise. Fixtures are written for these tests (Fixtures/Emails), one per style.
@Suite struct EmailImportTests {
    static let directory = AirportDirectory.bundled()
    /// What the app passes: an airport it knows, or three capitals that are not a booking word (the
    /// bundled list is short; the server knows every airport).
    static func isAirport(_ code: String) -> Bool {
        directory.lookup(code) != nil || EmailFlightReader.plausibleAirport(code)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Emails"))
        return try Data(contentsOf: url)
    }

    static func read(_ name: String) throws -> EmailFlightReader.Result {
        EmailFlightReader.read(try fixture(name), now: Date(timeIntervalSince1970: 1_800_000_000), isAirport: isAirport)
    }

    // MARK: Markup

    @Test func jsonLDReturnTrip() throws {
        let r = try Self.read("jsonld_return_trip.eml")
        #expect(r.method == .structured)
        #expect(r.flights.count == 2)
        let out = r.flights[0], back = r.flights[1]
        #expect(out.ident == "AF84")
        #expect(out.origin == "CDG" && out.destination == "SFO")
        #expect(out.day == LocalDay(year: 2027, month: 3, day: 14))
        #expect(out.departureTime?.description == "10:15")
        #expect(out.arrivalTime?.description == "12:40")
        #expect(out.seat == "32A")
        #expect(out.cabin == "Premium Economy")
        #expect(out.bookingReference == "QX4T7B")
        #expect(back.ident == "AF83")
        #expect(back.origin == "SFO" && back.destination == "CDG")
        #expect(back.day == LocalDay(year: 2027, month: 3, day: 22))
        #expect(back.arrivalDay == LocalDay(year: 2027, month: 3, day: 23))
        #expect(r.bookingReference == "QX4T7B")
    }

    @Test func passengerNameNeverRead() throws {
        let r = try Self.read("jsonld_return_trip.eml")
        let dump = String(describing: r)
        #expect(!dump.contains("Jane"))
        let united = String(describing: try Self.read("microdata_multi_leg.eml"))
        #expect(!united.contains("John"))
    }

    @Test func microdataMultiLegInNestedMultipartBase64() throws {
        let r = try Self.read("microdata_multi_leg.eml")
        #expect(r.method == .structured)
        #expect(r.flights.map(\.ident) == ["UA1527", "UA958"])
        #expect(r.flights.map(\.origin) == ["SFO", "ORD"])
        #expect(r.flights.map(\.destination) == ["ORD", "LHR"])
        #expect(r.flights[1].day == LocalDay(year: 2027, month: 5, day: 3))
        #expect(r.flights[1].departureTime?.description == "17:45")
        #expect(r.flights.map(\.seat) == ["21C", "40J"])
        #expect(r.bookingReference == "K9PLMQ")
    }

    // MARK: Text

    @Test func plainTextReturnTripDayBeforeNumber() throws {
        let r = try Self.read("plain_return_trip.eml")
        #expect(r.method == .text)
        #expect(r.flights.count == 2)
        #expect(r.flights[0].ident == "BA286")
        #expect(r.flights[0].origin == "SFO" && r.flights[0].destination == "LHR")
        #expect(r.flights[0].day == LocalDay(year: 2027, month: 3, day: 14))
        #expect(r.flights[0].departureTime?.description == "19:40")
        #expect(r.flights[0].seat == "32K")
        #expect(r.flights[1].ident == "BA287")
        #expect(r.flights[1].origin == "LHR" && r.flights[1].destination == "SFO")
        #expect(r.flights[1].day == LocalDay(year: 2027, month: 3, day: 22))
        #expect(r.flights[1].seat == "30A")
        #expect(r.bookingReference == "XJ7K2P")
        #expect(r.flights[0].evidence.first?.contains("BA 286") == true)
    }

    @Test func pastedGermanDayAfterNumber() throws {
        let r = try Self.read("pasted_german.txt")
        #expect(r.flights.map(\.ident) == ["LH454", "LH455"])
        #expect(r.flights[0].origin == "FRA" && r.flights[0].destination == "SFO")
        #expect(r.flights[0].day == LocalDay(year: 2027, month: 4, day: 12))
        #expect(r.flights[0].departureTime?.description == "10:05")
        #expect(r.flights[0].seat == "44C")
        #expect(r.flights[1].day == LocalDay(year: 2027, month: 4, day: 20))
        #expect(r.bookingReference == "R5TQ8M")
    }

    @Test func htmlTableWithoutYearReadsNearTheSentDate() throws {
        let r = try Self.read("html_table_no_year.eml")
        #expect(r.flights.map(\.ident) == ["U28017", "U28018"])
        #expect(r.flights[0].origin == "LGW" && r.flights[0].destination == "GVA")
        #expect(r.flights[0].day == LocalDay(year: 2027, month: 5, day: 7))
        #expect(r.flights[1].day == LocalDay(year: 2027, month: 5, day: 10))
        #expect(r.flights[1].departureTime?.description == "10:20")
        #expect(r.bookingReference == "EJX4R2")
    }

    @Test func agencyItineraryWithLeadingZeros() throws {
        let r = try Self.read("agency_itinerary.txt")
        #expect(r.flights.map(\.ident) == ["AF84", "AF83"])
        #expect(r.flights[0].day == LocalDay(year: 2027, month: 3, day: 14))
        #expect(r.flights[1].day == LocalDay(year: 2027, month: 3, day: 22))
        #expect(r.flights[1].origin == "SFO")
        #expect(r.flights[0].seat == "12A")
        #expect(r.bookingReference == "7HJK2L")
    }

    @Test func canceledFlight() throws {
        let r = try Self.read("canceled_flight.eml")
        #expect(r.flights.count == 1)
        let f = try #require(r.flights.first)
        #expect(f.ident == "DL405")
        #expect(f.canceled)
        #expect(f.departureTime?.description == "08:00")
        #expect(f.day == LocalDay(year: 2027, month: 3, day: 3))
        #expect(f.bookingReference == "GHT6YU")
    }

    @Test func newsletterHasNoFlights() throws {
        let r = try Self.read("newsletter_no_flight.eml")
        #expect(r.flights.isEmpty)
        #expect(r.method == nil)
    }

    // MARK: Pieces

    @Test func flightNumbersInText() {
        let found = FlightNumberText.all(in: "AF 84, U2 8017, 9W7 and AFR084; not A320, B737, GBP 812, CDG 14, SFO-CDG")
            .map { $0.airline + $0.number }
        #expect(found == ["AF84", "U28017", "9W7", "AFR084"])
    }

    @Test func mimeHeadersAndEncodings() {
        #expect(EmailMessage.decodeEncodedWords("=?UTF-8?Q?Votre_vol_=C3=A0_Paris?=") == "Votre vol à Paris")
        #expect(EmailMessage.decodeEncodedWords("=?utf-8?B?Qm9uam91cg==?=") == "Bonjour")
        #expect(String(decoding: EmailMessage.quotedPrintable("caf=C3=A9 =\nnoir"), as: UTF8.self) == "café noir")
        let m = EmailMessage.parse("Subject: Hi\nDate: Tue, 2 Feb 2027 09:12:00 +0100\n\nAF 84")
        #expect(m.subject == "Hi")
        #expect(m.sent == Date(timeIntervalSince1970: 1_801_555_920))
        #expect(m.plainParts == ["AF 84"])
    }

    @Test func pastedTextIsNotTakenForHeaders() {
        let m = EmailMessage.parse("Flight AF 84\nCDG to SFO\n14 Mar 2027")
        #expect(m.plainParts.count == 1)
        #expect(EmailMessage.parse("<div>AF 84</div>").htmlParts.count == 1)
    }

    @Test func datesInManyShapes() {
        let reader = TextReader(reference: Date(timeIntervalSince1970: 1_801_555_920), isAirport: { _ in true })
        let days = reader.dates(in: "2027-03-14 · 15 Mar 2027 · March 16, 2027 · 17MAR27 · 18/03/2027 · 03/19/2027 · 20. März 2027 · 21 mars")
        #expect(days.map(\.description) == ["2027-03-14", "2027-03-15", "2027-03-16", "2027-03-17", "2027-03-18",
                                            "2027-03-19", "2027-03-20", "2027-03-21"])
    }

    @Test func timesWithMeridiem() {
        #expect(TextReader.times(in: "7:05 PM then 12:10 a.m. and 19h05").map(\.description) == ["19:05", "00:10", "19:05"])
    }

    @Test func inboxKeepsUntilTaken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = ImportInbox(directory: dir)
        #expect(!inbox.hasItems)
        #expect(inbox.put(.init(received: Date(timeIntervalSince1970: 2), name: "b.eml", text: "two")))
        #expect(inbox.put(.init(received: Date(timeIntervalSince1970: 1), text: "one")))
        #expect(inbox.hasItems)
        #expect(inbox.takeAll().map(\.text) == ["one", "two"])
        #expect(inbox.takeAll().isEmpty)
        #expect(!inbox.put(.init(text: String(repeating: "x", count: ImportInbox.maxBytes + 1))))
    }

    #if canImport(AppKit)
    /// A PDF itinerary's text goes through the same reader.
    @Test func pdfAttachmentText() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "14 Mar 2027 KL 605 Amsterdam (AMS) 09:40 San Francisco (SFO) 11:50",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        ctx.textPosition = CGPoint(x: 40, y: 800)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        let text = try #require(SharedEmailFile.text(data: data as Data, name: "eticket.pdf"))
        let r = EmailFlightReader.read(EmailMessage(), pdfText: [text], isAirport: Self.isAirport)
        #expect(r.flights.map(\.ident) == ["KL605"])
        #expect(r.flights.first?.origin == "AMS")
    }
    #endif
}
