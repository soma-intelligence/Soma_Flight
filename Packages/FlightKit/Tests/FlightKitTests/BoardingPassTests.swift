import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FlightKit

/// Builds `.pkpass` fixtures: a folder with `pass.json` (and any other files) zipped by the system's
/// `zip`, stored or deflated.
enum PassFixture {
    static func pkpass(_ files: [String: Data], deflate: Bool = true) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pkpass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, data) in files {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let out = dir.appending(path: "out.pkpass")
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-X", deflate ? "-9" : "-0", "-r", "out.pkpass"] + files.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        return try Data(contentsOf: out)
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let bcbp = BCBP.encode(passengerName: "DESMARAIS/LUC", pnr: "K7PQ2X", from: "CDG", to: "SFO", carrier: "AF",
                                  flightNumber: "84", dayOfYear: 296, compartment: "J", seat: "23A", sequence: 12,
                                  issueYearDigit: 6, issueDayOfYear: 290)

    /// An Air France style boarding pass: visible fields, a BCBP barcode, semantic tags.
    static func airFrance(semantics: Bool = true, strings: Bool = false) -> [String: Any] {
        var p: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": "pass.com.example.boarding",
            "serialNumber": "AF84-K7PQ2X-23A",
            "teamIdentifier": "ABCDE12345",
            "organizationName": "Air France",
            "description": "Boarding pass",
            "relevantDate": "2026-10-23T13:10+02:00",
            "barcodes": [["message": bcbp, "format": "PKBarcodeFormatAztec", "messageEncoding": "iso-8859-1"]],
            "boardingPass": [
                "transitType": "PKTransitTypeAir",
                "headerFields": [["key": "gate", "label": strings ? "gate_label" : "GATE", "value": "K42"]],
                "primaryFields": [["key": "origin", "label": "Paris", "value": "CDG"],
                                  ["key": "destination", "label": "San Francisco", "value": "SFO"]],
                "secondaryFields": [["key": "passenger", "label": "PASSENGER", "value": "LUC DESMARAIS"],
                                    ["key": "boardingTime", "label": "BOARDING", "value": "2026-10-23T12:20:00+02:00",
                                     "dateStyle": "PKDateStyleNone", "timeStyle": "PKDateStyleShort"]],
                "auxiliaryFields": [["key": "seat", "label": "SEAT", "value": "23A"],
                                    ["key": "zone", "label": "ZONE", "value": "2"],
                                    ["key": "class", "label": "CABIN", "value": strings ? "cabin_value" : "Business"]],
                "backFields": [["key": "pnr", "label": "Booking reference", "value": "K7PQ2X"]],
            ],
        ]
        if semantics {
            p["semantics"] = [
                "airlineCode": "AF", "flightNumber": 84, "departureAirportCode": "CDG", "destinationAirportCode": "SFO",
                "passengerName": ["givenName": "Luc", "familyName": "Desmarais"],
                "seats": [["seatNumber": "23A", "seatType": "Business"]],
                "boardingGroup": "2", "departureGate": "K42", "confirmationNumber": "K7PQ2X",
                "currentBoardingDate": "2026-10-23T12:20:00+02:00",
                "originalDepartureDate": "2026-10-23T13:10:00+02:00",
            ]
        }
        return p
    }
}

@Suite struct WalletPassReaderTests {
    @Test(arguments: [true, false]) func readsAPassFile(deflate: Bool) throws {
        let file = try PassFixture.pkpass(["pass.json": PassFixture.json(PassFixture.airFrance()),
                                           "icon.png": Data(repeating: 7, count: 300)], deflate: deflate)
        let pass = try WalletPassReader.read(file)
        #expect(pass.source == .wallet)
        #expect(pass.passenger == "Luc Desmarais")
        #expect(pass.ident == "AF84")
        #expect(pass.origin == "CDG" && pass.destination == "SFO")
        #expect(pass.seat == "23A")
        #expect(pass.cabin == "Business")
        #expect(pass.group == "2")
        #expect(pass.zone == "2")
        #expect(pass.gate == "K42")
        #expect(pass.bookingReference == "K7PQ2X")
        #expect(pass.boardingTime == WalletPassReader.isoDate("2026-10-23T10:20:00Z"))
        #expect(pass.departureDay?.year == 2026 && pass.departureDay?.month == 10 && pass.departureDay?.day == 23)
        #expect(pass.barcode == PassBarcode(message: PassFixture.bcbp, format: .aztec, encoding: "iso-8859-1"))
        #expect(pass.wallet == WalletPassID(passTypeIdentifier: "pass.com.example.boarding", serialNumber: "AF84-K7PQ2X-23A"))
        #expect(pass.airlineName == "Air France")
        #expect(pass.sequence == "12")
    }

    @Test func fieldsAloneWithoutSemanticsOrBarcode() throws {
        var json = PassFixture.airFrance(semantics: false)
        json["barcodes"] = nil
        var style = json["boardingPass"] as! [String: Any]
        style["headerFields"] = [["key": "flight", "label": "FLIGHT", "value": "AF 0084"],
                                 ["key": "gate", "label": "GATE", "value": "K42"]]
        json["boardingPass"] = style
        let pass = try WalletPassReader.read(PassFixture.pkpass(["pass.json": PassFixture.json(json)]))
        #expect(pass.ident == "AF84")
        #expect(pass.origin == "CDG" && pass.destination == "SFO")
        #expect(pass.passenger == "LUC DESMARAIS")
        #expect(pass.seat == "23A")
        #expect(pass.zone == "2")
        #expect(pass.group == nil)
        #expect(pass.bookingReference == "K7PQ2X")
        #expect(pass.barcode == nil)
        #expect(pass.departureDay?.day == 23)
    }

    @Test func barcodeAloneFillsTheFlight() throws {
        let json: [String: Any] = [
            "passTypeIdentifier": "pass.x", "serialNumber": "1", "organizationName": "Air France",
            "barcode": ["message": PassFixture.bcbp, "format": "PKBarcodeFormatPDF417"],
            "boardingPass": ["transitType": "PKTransitTypeAir"],
        ]
        let pass = try WalletPassReader.read(PassFixture.pkpass(["pass.json": PassFixture.json(json)]),
                                             near: Date(timeIntervalSince1970: 1_792_770_120))
        #expect(pass.ident == "AF84")
        #expect(pass.seat == "23A")
        #expect(pass.compartment == "J")
        #expect(pass.cabinTitle == "Business")
        #expect(pass.departureDay?.month == 10 && pass.departureDay?.day == 23)
        #expect(pass.barcode?.format == .pdf417)
    }

    @Test func englishStringsAreLookedUp() throws {
        let strings = "\"gate_label\" = \"GATE\";\n\"cabin_value\" = \"Premium Economy\";\n"
        let file = try PassFixture.pkpass([
            "pass.json": PassFixture.json(PassFixture.airFrance(semantics: false, strings: true)),
            "en.lproj/pass.strings": strings.data(using: .utf16)!,
        ])
        let pass = try WalletPassReader.read(file)
        #expect(pass.gate == "K42")
        #expect(pass.cabin == "Premium Economy")
    }

    @Test func refusals() throws {
        #expect(throws: WalletPassReader.ReadError.notAPass) { try WalletPassReader.read(Data("hello".utf8)) }
        #expect(throws: WalletPassReader.ReadError.notAPass) {
            try WalletPassReader.read(PassFixture.pkpass(["manifest.json": Data("{}".utf8)]))
        }
        let ticket = try PassFixture.json(["passTypeIdentifier": "pass.x", "serialNumber": "1", "eventTicket": [String: Any]()])
        #expect(throws: WalletPassReader.ReadError.notBoardingPass) {
            try WalletPassReader.read(PassFixture.pkpass(["pass.json": ticket]))
        }
        let blank = try PassFixture.json(["passTypeIdentifier": "pass.x", "serialNumber": "1",
                                          "boardingPass": ["transitType": "PKTransitTypeAir"]])
        #expect(throws: WalletPassReader.ReadError.missingFlight) {
            try WalletPassReader.read(PassFixture.pkpass(["pass.json": blank]))
        }
    }

    @Test func zipReaderListsAndInflates() throws {
        let big = Data(String(repeating: "boarding pass ", count: 2000).utf8)
        let file = try PassFixture.pkpass(["a.txt": big, "dir/b.txt": Data("b".utf8)])
        let zip = try ZipArchive(file)
        #expect(Set(zip.paths).isSuperset(of: ["a.txt", "dir/b.txt"]))
        #expect(try zip.file("a.txt") == big)
        #expect(try zip.file("dir/b.txt") == Data("b".utf8))
        #expect(try zip.file("missing") == nil)
        #expect(throws: ZipArchive.ReadError.notZip) { try ZipArchive(Data(repeating: 0, count: 100)) }
    }

    @Test func splitFlight() {
        #expect(WalletPassReader.splitFlight("AF 84")! == ("AF", "84"))
        #expect(WalletPassReader.splitFlight("af0084")! == ("AF", "84"))
        #expect(WalletPassReader.splitFlight("B61234A")! == ("B6", "1234A"))
        #expect(WalletPassReader.splitFlight("Boarding") == nil)
    }
}

@Suite struct BoardingPassMatchTests {
    static let af84 = PreviewData.enRoute // AF84, CDG to SFO, leaves 2026-10-23 11:10Z (13:10 in Paris)

    static func pass(carrier: String = "AF", number: String = "84", from: String = "CDG", to: String = "SFO",
                     month: Int = 10, day: Int = 23) -> BoardingPass {
        BoardingPass(source: .scan, carrier: carrier, flightNumber: number, origin: from, destination: to,
                     departureDay: DateComponents(month: month, day: day))
    }

    private let lookup: (String) -> Airport? = { PreviewData.airport($0) }

    @Test func matchesTheFlight() {
        #expect(BoardingPassMatch.matches(Self.pass(), Self.af84, lookup: lookup))
        // ICAO airline code on the pass, leading zeros on the number.
        #expect(BoardingPassMatch.matches(Self.pass(carrier: "AFR", number: "0084"), Self.af84, lookup: lookup))
        // No day on the pass: carrier, number and route are enough.
        var undated = Self.pass()
        undated.departureDay = nil
        #expect(BoardingPassMatch.matches(undated, Self.af84, lookup: lookup))
    }

    @Test func refusesAnotherFlight() {
        #expect(!BoardingPassMatch.matches(Self.pass(number: "83"), Self.af84, lookup: lookup))
        #expect(!BoardingPassMatch.matches(Self.pass(carrier: "DL"), Self.af84, lookup: lookup))
        #expect(!BoardingPassMatch.matches(Self.pass(to: "JFK"), Self.af84, lookup: lookup))
        #expect(!BoardingPassMatch.matches(Self.pass(day: 24), Self.af84, lookup: lookup))
        #expect(!BoardingPassMatch.matches(Self.pass(day: 22), Self.af84, lookup: lookup))
    }

    @Test func dayIsLocalAtTheOrigin() {
        // A flight leaving 23:30 in Los Angeles is on the 23rd there and the 24th in GMT.
        var late = Self.af84
        late.ident = "AF65"; late.originIcao = "KLAX"; late.originIata = "LAX"; late.destinationIcao = "LFPG"; late.destinationIata = "CDG"
        late.scheduledOut = Date(timeIntervalSince1970: 1_792_823_400) // 2026-10-24T06:30Z
        let la = Airport(id: "KLAX", iata: "LAX", name: "Los Angeles", city: "Los Angeles", country: "US",
                         lat: 33.94, lon: -118.4, tz: "America/Los_Angeles")
        let pass = Self.pass(number: "65", from: "LAX", to: "CDG", day: 23)
        #expect(BoardingPassMatch.matches(pass, late, lookup: { $0 == "KLAX" ? la : nil }))
        // Without the zone, a day either side is allowed.
        #expect(BoardingPassMatch.matches(pass, late))
        #expect(!BoardingPassMatch.matches(Self.pass(number: "65", from: "LAX", to: "CDG", day: 21), late))
    }

    @Test func picksAmongFollowedFlights() {
        let found = BoardingPassMatch.flight(for: Self.pass(), in: PreviewData.followed, lookup: lookup)
        #expect(found?.id == Self.af84.id)
        #expect(BoardingPassMatch.flight(for: Self.pass(number: "9999"), in: PreviewData.followed) == nil)
    }

    @Test func fillsOnlyEmptyDetails() {
        var pass = Self.pass()
        pass.bookingReference = "k7pq2x"
        pass.seat = "23A"
        pass.compartment = "J"
        let filled = BoardingPassMatch.filled(.empty, from: pass)
        #expect(filled == FollowDetails(seatClass: .business, seat: "23A", bookingCode: "K7PQ2X"))
        let mine = FollowDetails(seatClass: .economy, seat: "41C", bookingCode: "ZZZZZ1")
        #expect(BoardingPassMatch.filled(mine, from: pass) == nil)
        // A seat the details refuse stays out; the cabin name wins over the letter.
        pass.seat = "INF"
        pass.cabin = "Premium Economy"
        #expect(BoardingPassMatch.filled(.empty, from: pass)?.seat == nil)
        #expect(BoardingPassMatch.filled(.empty, from: pass)?.seatClass == .premiumEconomy)
    }

    @Test func summaryAndSearchDate() {
        var pass = Self.pass()
        #expect(BoardingPassMatch.summary(pass) == "AF 84 · CDG to SFO · 23 Oct")
        pass.departureDay = DateComponents(year: 2026, month: 10, day: 23)
        #expect(BoardingPassMatch.searchDate(pass) == Date(timeIntervalSince1970: 1_792_756_800))
    }
}

@Suite struct BoardingPassVaultTests {
    static func sample(_ flight: UUID) -> BoardingPass {
        var p = BoardingPassMatchTests.pass()
        p.id = UUID(uuidString: "0B0A0000-0000-4000-8000-000000000001")!
        p.addedAt = Date(timeIntervalSince1970: 1_792_770_120)
        p.flightId = flight
        p.passenger = "Luc Desmarais"
        p.barcode = PassBarcode(message: PassFixture.bcbp, format: .pdf417)
        return p
    }

    @Test func filesSurviveANewVault() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "passes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = BoardingPassShelf(directory: root)
        let owner = UUID(), flight = UUID()
        try await shelf.vault(for: owner).save(Self.sample(flight), walletFile: Data("pkpass".utf8))
        let again = shelf.vault(for: owner)
        #expect(await again.pass(for: flight) == Self.sample(flight))
        #expect(await again.walletFile(for: flight) == Data("pkpass".utf8))
        // Another account sees nothing.
        #expect(await shelf.vault(for: UUID()).pass(for: flight) == nil)
        // A scanned pass replacing it drops the Wallet file.
        try await again.save(Self.sample(flight), walletFile: nil)
        #expect(await again.walletFile(for: flight) == nil)
        await again.remove(for: flight)
        #expect(await again.pass(for: flight) == nil)
    }

    @Test func keepOnlyForgetsOtherAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "passes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = BoardingPassShelf(directory: root)
        let a = UUID(), b = UUID(), flight = UUID()
        try await shelf.vault(for: a).save(Self.sample(flight), walletFile: nil)
        try await shelf.vault(for: b).save(Self.sample(flight), walletFile: nil)
        shelf.keepOnly(b)
        #expect(await shelf.vault(for: a).pass(for: flight) == nil)
        #expect(await shelf.vault(for: b).pass(for: flight) != nil)
    }

    @Test func unattachedPassIsRefused() async {
        var p = Self.sample(UUID())
        p.flightId = nil
        await #expect(throws: (any Error).self) { try await BoardingPassShelf.inMemory().vault(for: nil).save(p, walletFile: nil) }
    }

    @Test func memorySeedShowsUntilRemoved() async {
        let flight = UUID()
        let shelf = BoardingPassShelf.inMemory(seed: [Self.sample(flight)])
        let vault = shelf.vault(for: UUID())
        #expect(await vault.pass(for: flight) != nil)
        await vault.remove(for: flight)
        #expect(await vault.pass(for: flight) == nil)
    }
}

@Suite struct PassBarcodeTests {
    @Test(arguments: PassBarcode.Format.allCases) func drawsEveryFormat(format: PassBarcode.Format) throws {
        let image = try #require(PassBarcodeImage.make(PassBarcode(message: PassFixture.bcbp, format: format)))
        #expect(image.width > 50)
    }

    @Test func pdf417RoundTripsThroughVision() async throws {
        let image = try #require(PassBarcodeImage.make(PassBarcode(message: PassFixture.bcbp, format: .pdf417), scale: 4))
        let png = try #require(Self.png(image))
        let pass = try await PassBarcodeReader.read(imageData: png, near: Date(timeIntervalSince1970: 1_792_770_120))
        #expect(pass.ident == "AF84")
        #expect(pass.seat == "23A")
        #expect(pass.barcode?.format == .pdf417)
        #expect(pass.source == .scan)
    }

    @Test func pickerRefusals() {
        #expect(throws: PassBarcodeReader.ReadError.noBarcode) { try PassBarcodeReader.pass(from: []) }
        #expect(throws: PassBarcodeReader.ReadError.notBoardingPass) {
            try PassBarcodeReader.pass(from: [("https://example.com", .qr)])
        }
        let pass = try? PassBarcodeReader.pass(from: [("hello", .qr), (PassFixture.bcbp, .aztec)])
        #expect(pass?.barcode?.format == .aztec)
    }

    /// A white margin around the code, as on a screenshot, then PNG bytes.
    static func png(_ image: CGImage) -> Data? {
        let margin = 40
        let w = image.width + 2 * margin, h = image.height + 2 * margin
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
